// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./GaugeRegistry.sol";
import "./SurrogateRegistry.sol";
import "./Delegation.sol";
import "./interface/IvlCVX.sol";


contract GaugeVotePlatform{

    address public owner;
    address public pendingowner;
    mapping(address => bool) public operators;

    IvlCVX public immutable vlCVX;
    GaugeRegistry public immutable gaugeRegistry;
    SurrogateRegistry public immutable surrogateRegistry;
    Delegation public immutable delegation;

    uint256 public constant epochDuration = 86400 * 7;

    enum VoteStatus{
        None,
        VotedViaSurrogate,
        Voted
    }

    struct UserInfo {
        uint256 baseWeight;
        int256 adjustedWeight;
        address delegate;
        uint8 voteStatus;
    }
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => address[]) public votedUsers;

    struct Proposal {
        uint256 startTime;
        uint256 endTime;
        uint256 epoch;
    }

    struct Vote {
        address[] gauges;
        uint256[] weights;
    }

    mapping(uint256 => mapping(address => uint256)) public gaugeTotals;
    mapping(uint256 => uint256) public voteTotals;

    Proposal[] public proposals;
    mapping(uint256 => mapping(address => Vote)) internal votes;
    uint256 public constant max_weight = 10000;

    mapping(address => bool) public equalizerAccounts;
    uint256 public constant overtime = 10 minutes;

    function currentEpoch() public view returns (uint256) {
        return block.timestamp/epochDuration*epochDuration;
    }

    function proposalCount() external view returns(uint256){
        return proposals.length;
    }

    function getVoterCount(uint256 _proposalId) external view returns(uint256){
        return votedUsers[_proposalId].length;
    }

    function getVoterAtIndex(uint256 _proposalId, uint256 _index) external view returns(address){
        return votedUsers[_proposalId][_index];
    }

    function getVote(uint256 _proposalId, address _user) public view returns (address[] memory gauges, uint256[] memory weights, bool voted, uint256 baseWeight, int256 adjustedWeight) {
        gauges = votes[_proposalId][_user].gauges;
        weights = votes[_proposalId][_user].weights;
        voted = userInfo[_proposalId][_user].voteStatus > 0;
        baseWeight = userInfo[_proposalId][_user].baseWeight;
        adjustedWeight = userInfo[_proposalId][_user].adjustedWeight;
    }

    function _getBaseWeight(address _account, uint256 _epoch) internal view returns (uint256) {
        return vlCVX.balanceAtEpochOf(_epoch, _account);
    }

    function _getDelegate(address _account, uint256 _epoch) internal view returns (address) {
        return delegation.getDelegateAtEpoch(_account, _epoch);
    }

    function _getDelegatedWeight(address _account, uint256 _epoch) internal view returns (uint256) {
        return delegation.userWeightAtEpochOf(_epoch, _account);
    }

    function _getDelegateTotalWeight(address _delegate, uint256 _epoch) internal view returns (uint256) {
        return delegation.balanceAtEpochOf(_epoch, _delegate);
    }

    function _ensureUserInfo(address _account, uint256 _proposalId) internal {
        if (userInfo[_proposalId][_account].voteStatus != 0) return;
        if (userInfo[_proposalId][_account].baseWeight != 0) return;

        uint256 epoch = proposals[_proposalId].epoch;

        uint256 baseWeight = _getBaseWeight(_account, epoch);
        address delegate = _getDelegate(_account, epoch);

        if (delegate == address(0)) {
            delegate = _account;
        }

        userInfo[_proposalId][_account].baseWeight = baseWeight;
        userInfo[_proposalId][_account].delegate = delegate;
        userInfo[_proposalId][_account].adjustedWeight += int256(_getDelegateTotalWeight(_account, epoch));

        emit UserWeightChange(_proposalId, _account, baseWeight, userInfo[_proposalId][_account].adjustedWeight);

        if (delegate != _account) {
            _ensureUserInfo(delegate, _proposalId);

            int256 delegatedWeight = int256(_getDelegatedWeight(_account, epoch));

            if (userInfo[_proposalId][delegate].voteStatus > 0) {
                int256 delegateTotalWeight = int256(userInfo[_proposalId][delegate].baseWeight) + userInfo[_proposalId][delegate].adjustedWeight;

                for (uint256 i = 0; i < votes[_proposalId][delegate].gauges.length; i++) {
                    int256 oldContribution = int256(votes[_proposalId][delegate].weights[i]) * delegateTotalWeight / int256(max_weight);
                    int256 newContribution = int256(votes[_proposalId][delegate].weights[i]) * (delegateTotalWeight - delegatedWeight) / int256(max_weight);
                    _changeGaugeTotal(_proposalId, votes[_proposalId][delegate].gauges[i], newContribution - oldContribution);
                }

                voteTotals[_proposalId] -= uint256(delegatedWeight);
            }

            userInfo[_proposalId][delegate].adjustedWeight -= delegatedWeight;
            emit UserWeightChange(_proposalId, delegate, userInfo[_proposalId][delegate].baseWeight, userInfo[_proposalId][delegate].adjustedWeight);
        }
    }

    function _vote(address _account, address[] calldata _gauges, uint256[] calldata _weights) internal {
        uint256 proposalId = proposals.length - 1;
        require(block.timestamp >= proposals[proposalId].startTime, "!start");
        if(equalizerAccounts[_account]){
            require(block.timestamp <= proposals[proposalId].endTime + overtime, "!end");
        }else{
            require(block.timestamp <= proposals[proposalId].endTime, "!end");
        }
        require(_gauges.length == _weights.length, "mismatch");

        _ensureUserInfo(_account, proposalId);

        require(userInfo[proposalId][_account].baseWeight > 0, "!weight");

        int256 userbase = int256(userInfo[proposalId][_account].baseWeight);
        int256 userWeight = userbase + userInfo[proposalId][_account].adjustedWeight;

        if(userInfo[proposalId][_account].voteStatus > 0){
            for(uint256 i = 0; i < votes[proposalId][_account].gauges.length; i++) {
                _changeGaugeTotal(proposalId, votes[proposalId][_account].gauges[i], -(int256(votes[proposalId][_account].weights[i])*userWeight/int256(max_weight)) );
            }
        }

        delete votes[proposalId][_account].gauges;
        delete votes[proposalId][_account].weights;
        uint256 totalweight;
        for(uint256 i = 0; i < _weights.length; i++) {
            require(_weights[i] > 0, "!weight");
            require(gaugeRegistry.isValidGauge(_gauges[i]),"!gauge");
            votes[proposalId][_account].gauges.push(_gauges[i]);
            votes[proposalId][_account].weights.push(_weights[i]);
            totalweight += _weights[i];
        }
        require(totalweight <= max_weight, "max weight");

        for(uint256 i = 0; i < _weights.length; i++) {
            _changeGaugeTotal(proposalId,_gauges[i], int256(_weights[i])*userWeight/int256(max_weight) );
        }
        emit VoteCast(proposalId, _account, _gauges, _weights);

        if(userInfo[proposalId][_account].voteStatus == 0){
            userInfo[proposalId][_account].voteStatus = msg.sender == _account ? uint8(VoteStatus.Voted) : uint8(VoteStatus.VotedViaSurrogate);
            votedUsers[proposalId].push(_account);
            voteTotals[proposalId] += uint256(userWeight);
        }
    }

    function _changeGaugeTotal(uint256 _proposalId, address _gauge, int256 _changeValue) internal{

        if(_changeValue > 0){
            gaugeTotals[_proposalId][_gauge] += uint256(_changeValue);
        }else{
            gaugeTotals[_proposalId][_gauge] -= uint256(-_changeValue);
        }
        emit GaugeTotalChange(_proposalId, _gauge, gaugeTotals[_proposalId][_gauge]);
    }

    function _canSign(address _account) internal view returns(bool){
        if(msg.sender == _account){
            return true;
        }
        if(surrogateRegistry.isSurrogate(msg.sender, _account)){
            return true;
        }
        return false;
    }

    function vote(address _account, address[] calldata _gauges, uint256[] calldata _weights) external onlyAcceptedSigner(_account){
        uint256 proposalId = proposals.length - 1;
        require(msg.sender == _account || userInfo[proposalId][_account].voteStatus <= uint8(VoteStatus.VotedViaSurrogate), "!voteAuth");

        _vote(_account, _gauges, _weights);

        if(userInfo[proposalId][_account].voteStatus <= uint8(VoteStatus.VotedViaSurrogate) && msg.sender == _account){
            userInfo[proposalId][_account].voteStatus = uint8(VoteStatus.Voted);
        }
    }

    function updateUserWeight(address _account) external onlyAcceptedSigner(_account){
        uint256 proposalId = proposals.length - 1;
        _ensureUserInfo(_account, proposalId);
        require(userInfo[proposalId][_account].voteStatus == 0, "already voted");

        uint256 epoch = proposals[proposalId].epoch;
        uint256 newBaseWeight = _getBaseWeight(_account, epoch);
        uint256 currentWeight = userInfo[proposalId][_account].baseWeight;
        address delegate = userInfo[proposalId][_account].delegate;

        if (newBaseWeight <= currentWeight) return;

        int256 userDifference = int256(newBaseWeight) - int256(currentWeight);

        if(delegate != _account) {
            _ensureUserInfo(delegate, proposalId);

            if(userInfo[proposalId][delegate].voteStatus > 0) {
                int256 delegateTotalWeight = int256(userInfo[proposalId][delegate].baseWeight) + userInfo[proposalId][delegate].adjustedWeight;
                for(uint256 i = 0; i < votes[proposalId][delegate].gauges.length; i++) {
                    int256 oldContribution = int256(votes[proposalId][delegate].weights[i]) * delegateTotalWeight / int256(max_weight);
                    int256 newContribution = int256(votes[proposalId][delegate].weights[i]) * (delegateTotalWeight + userDifference) / int256(max_weight);
                    _changeGaugeTotal(proposalId, votes[proposalId][delegate].gauges[i], newContribution - oldContribution);
                }
            }

            userInfo[proposalId][delegate].adjustedWeight += userDifference;
            emit UserWeightChange(proposalId, delegate, userInfo[proposalId][delegate].baseWeight, userInfo[proposalId][delegate].adjustedWeight);
        }

        userInfo[proposalId][_account].baseWeight = newBaseWeight;
        emit UserWeightChange(proposalId, _account, newBaseWeight, userInfo[proposalId][_account].adjustedWeight);
    }

    function createProposal(uint256 _startTime, uint256 _endTime) public onlyOperator {
        uint256 pCnt = proposals.length;
        if(pCnt > 0){
            require(block.timestamp > proposals[pCnt-1].endTime + overtime, "!prev_end");
        }

        require(_endTime > _startTime, "!time");
        require(_endTime - _startTime >= 3 days, "!time");
        require(_endTime - _startTime <= 6 days, "!time");

        vlCVX.checkpointEpoch();
        uint256 epoch = vlCVX.epochCount() - 2;

        proposals.push(Proposal({
            startTime: _startTime,
            endTime: _endTime,
            epoch: epoch
        }));
        emit NewProposal(proposals.length-1, _startTime, _endTime);
    }

    function forceEndProposal() public onlyOperator {
        uint256 proposalId = proposals.length - 1;
        require(block.timestamp >= proposals[proposalId].startTime, "!start");
        require(block.timestamp <= proposals[proposalId].endTime, "!end");

        proposals[proposalId].startTime = 0;
        proposals[proposalId].endTime = 0;
        proposals[proposalId].epoch = 0;
        emit ForceEndProposal(proposalId);
    }

    function transferOwnership(address _owner) external onlyOwner{
        pendingowner = _owner;
        emit TransferOwnership(_owner);
    }

    function acceptOwnership() external {
        require(pendingowner == msg.sender, "!pendingowner");
        owner = pendingowner;
        pendingowner = address(0);
        emit AcceptedOwnership(owner);
    }

    function setOperator(address _op, bool _active) external onlyOwner{
        operators[_op] = _active;
        emit OperatorSet(_op, _active);
    }

    function setOvertimeAccount(address _eq, bool _active) external onlyOwner{
        equalizerAccounts[_eq] = _active;
        emit EqualizerAccountSet(_eq, _active);
    }

    modifier onlyOwner() {
        require(owner == msg.sender, "!owner");
        _;
    }

    modifier onlyOperator() {
        require(operators[msg.sender] || owner == msg.sender, "!operator");
        _;
    }

    modifier onlyAcceptedSigner(address _account) {
        require(_canSign(_account), "!signer");
        _;
    }

    event VoteCast(uint256 indexed proposalId, address indexed user, address[] gauges, uint256[] weights);
    event NewProposal(uint256 indexed id, uint256 start, uint256 end);
    event ForceEndProposal(uint256 indexed id);
    event UserWeightChange(uint256 indexed pid, address indexed user, uint256 baseWeight, int256 adjustedWeight);
    event GaugeTotalChange(uint256 indexed pid, address indexed gauge, uint256 newWeight);
    event TransferOwnership(address pendingOwner);
    event AcceptedOwnership(address newOwner);
    event OperatorSet(address indexed op, bool active);
    event EqualizerAccountSet(address indexed eq, bool active);

    constructor(address _vlCVX, address _gaugeRegistry, address _surrogateRegistry, address _delegation) {
        owner = msg.sender;
        operators[msg.sender] = true;
        vlCVX = IvlCVX(_vlCVX);
        gaugeRegistry = GaugeRegistry(_gaugeRegistry);
        surrogateRegistry = SurrogateRegistry(_surrogateRegistry);
        delegation = Delegation(_delegation);
    }

}
