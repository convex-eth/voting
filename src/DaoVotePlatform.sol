// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./Delegation.sol";
import "./SurrogateRegistry.sol";
import "./interface/IvlCVX.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract DaoVotePlatform is Ownable2Step {

    error NotStarted();
    error Ended();
    error NoWeight();
    error PrevNotEnded();
    error BadTime();
    error AlreadyVoted();
    error AlreadyUpdated();
    error NotVoteAuth();
    error NotSigner();
    error NotOperator();
    error MaxWeight();

    mapping(address => bool) public operators;

    IvlCVX public immutable vlCVX;
    SurrogateRegistry public immutable surrogateRegistry;
    Delegation public immutable delegation;

    uint256 public constant epochDuration = 86400 * 7;
    uint256 public constant finalizationTime = 12 hours;
    uint256 public constant max_weight = 10000;

    enum VoteStatus {
        None,
        VotedViaSurrogate,
        Voted
    }

    struct UserInfo {
        uint96 baseWeight;
        int96 adjustedWeight;
        uint16 yesWeight;
        uint16 noWeight;
        uint8 voteStatus;
        bool hasUpdated;
        address delegate;
    }

    struct Proposal {
        uint48 startTime;
        uint48 endTime;
        uint48 epoch;
        uint8 voteType;
    }

    struct VoteTotals {
        uint128 yes;
        uint128 no;
    }

    enum VoteType {
        Ownership,
        Parameter
    }

    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => address[]) public votedUsers;
    Proposal[] public proposals;
    mapping(uint256 => VoteTotals) internal _voteTotals;
    mapping(uint256 => mapping(address => int96)) public pendingWeightAdjustment;

    event VoteCast(uint256 indexed proposalId, address indexed user, uint256 yesWeight, uint256 noWeight);
    event NewProposal(uint256 indexed id, uint256 start, uint256 end, VoteType voteType);
    event ForceEndProposal(uint256 indexed id);
    event UserWeightChange(uint256 indexed pid, address indexed user, uint256 baseWeight, int256 adjustedWeight);
    event PendingWeightAdjustment(uint256 indexed pid, address indexed delegate, int256 diff);
    event OperatorSet(address indexed op, bool active);

    constructor(address _vlCVX, address _surrogateRegistry, address _delegation)
        Ownable(msg.sender)
    {
        operators[msg.sender] = true;
        vlCVX = IvlCVX(_vlCVX);
        surrogateRegistry = SurrogateRegistry(_surrogateRegistry);
        delegation = Delegation(_delegation);
    }

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / epochDuration * epochDuration;
    }

    function proposalCount() external view returns (uint256) {
        return proposals.length;
    }

    function getVoterCount(uint256 _proposalId) external view returns (uint256) {
        return votedUsers[_proposalId].length;
    }

    function getVoterAtIndex(uint256 _proposalId, uint256 _index) external view returns (address) {
        return votedUsers[_proposalId][_index];
    }

    function getYes(uint256 _proposalId) external view returns (uint256) {
        return _voteTotals[_proposalId].yes;
    }

    function getNo(uint256 _proposalId) external view returns (uint256) {
        return _voteTotals[_proposalId].no;
    }

    function voteTotals(uint256 _proposalId) external view returns (uint256) {
        return uint256(_voteTotals[_proposalId].yes) + uint256(_voteTotals[_proposalId].no);
    }

    function getVote(uint256 _proposalId, address _user) public view returns (
        bool voted, uint256 yesWeight, uint256 noWeight, uint256 baseWeight, int256 adjustedWeight
    ) {
        UserInfo storage u = userInfo[_proposalId][_user];
        voted = u.voteStatus > 0;
        yesWeight = u.yesWeight;
        noWeight = u.noWeight;
        baseWeight = u.baseWeight;
        adjustedWeight = u.adjustedWeight;
    }

    function isFinalized(uint256 _proposalId) public view returns (bool) {
        return proposals[_proposalId].endTime > 0 && block.timestamp > proposals[_proposalId].endTime + finalizationTime;
    }

    function _changeVoteTotals(uint256 _proposalId, int256 _delta, uint256 _yesWeight, uint256 _noWeight) internal {
        VoteTotals storage totals = _voteTotals[_proposalId];
        int256 yesDelta = _delta * int256(_yesWeight) / int256(max_weight);
        int256 noDelta = _delta * int256(_noWeight) / int256(max_weight);
        unchecked {
            if (yesDelta > 0) totals.yes += uint128(uint256(yesDelta));
            else totals.yes -= uint128(uint256(-yesDelta));
            if (noDelta > 0) totals.no += uint128(uint256(noDelta));
            else totals.no -= uint128(uint256(-noDelta));
        }
    }

    function _initBaseInfo(address _account, uint256 _proposalId) internal {
        UserInfo memory user = userInfo[_proposalId][_account];
        if (user.delegate != address(0)) return;

        uint256 epoch = proposals[_proposalId].epoch;

        uint256 baseWeight = vlCVX.balanceAtEpochOf(epoch, _account);
        address delegate = delegation.getDelegateAtEpoch(_account, epoch);

        if (delegate == address(0)) {
            delegate = _account;
        }

        user.baseWeight = uint96(baseWeight);
        user.delegate = delegate;
        user.adjustedWeight += int96(int256(delegation.balanceAtEpochOf(epoch, _account)));

        userInfo[_proposalId][_account] = user;

        emit UserWeightChange(_proposalId, _account, baseWeight, user.adjustedWeight);

        if (delegate != _account) {
            int256 weightToRemove;
            if (user.hasUpdated) {
                weightToRemove = int256(baseWeight);
            } else {
                weightToRemove = int256(delegation.userWeightAtEpochOf(epoch, _account));
            }

            UserInfo storage del = userInfo[_proposalId][delegate];
            int96 pending = pendingWeightAdjustment[_proposalId][delegate];
            if (pending != 0) {
                pendingWeightAdjustment[_proposalId][delegate] = 0;
            }

            if (del.voteStatus > 0) {
                int256 netDelta = int256(pending) - weightToRemove;
                _changeVoteTotals(_proposalId, netDelta, del.yesWeight, del.noWeight);
            }

            del.adjustedWeight = del.adjustedWeight + pending - int96(weightToRemove);
            emit UserWeightChange(_proposalId, delegate, del.baseWeight, del.adjustedWeight);
        }
    }

    function _applyPending(uint256 _proposalId, address _account, uint8 _voteStatus) internal {
        int96 pending = pendingWeightAdjustment[_proposalId][_account];
        if (pending == 0) return;

        pendingWeightAdjustment[_proposalId][_account] = 0;
        userInfo[_proposalId][_account].adjustedWeight += pending;

        if (_voteStatus > 0) {
            UserInfo storage u = userInfo[_proposalId][_account];
            _changeVoteTotals(_proposalId, int256(pending), u.yesWeight, u.noWeight);
        }

        emit UserWeightChange(_proposalId, _account, userInfo[_proposalId][_account].baseWeight, userInfo[_proposalId][_account].adjustedWeight);
    }

    function _vote(address _account, uint256 _yesWeight, uint256 _noWeight) internal {
        uint256 proposalId = proposals.length - 1;
        Proposal storage prop = proposals[proposalId];
        if (block.timestamp < prop.startTime) revert NotStarted();
        if (block.timestamp > prop.endTime) revert Ended();
        if (_yesWeight + _noWeight > max_weight) revert MaxWeight();

        _initBaseInfo(_account, proposalId);

        UserInfo storage user = userInfo[proposalId][_account];
        int256 userWeight = int256(uint256(user.baseWeight)) + int256(user.adjustedWeight);
        if (userWeight <= 0) revert NoWeight();

        if (user.voteStatus > 0) {
            _changeVoteTotals(proposalId, -userWeight, user.yesWeight, user.noWeight);

            uint256 currentBalance = vlCVX.balanceAtEpochOf(prop.epoch, _account);
            if (currentBalance != uint256(user.baseWeight)) {
                user.baseWeight = uint96(currentBalance);
                emit UserWeightChange(proposalId, _account, currentBalance, user.adjustedWeight);
            }
        }

        int96 pend = pendingWeightAdjustment[proposalId][_account];
        if (pend != 0) {
            pendingWeightAdjustment[proposalId][_account] = 0;
            user.adjustedWeight += pend;
        }

        userWeight = int256(uint256(user.baseWeight)) + int256(user.adjustedWeight);
        if (userWeight <= 0) revert NoWeight();

        user.yesWeight = uint16(_yesWeight);
        user.noWeight = uint16(_noWeight);
        _changeVoteTotals(proposalId, userWeight, _yesWeight, _noWeight);

        emit VoteCast(proposalId, _account, _yesWeight, _noWeight);

        if (user.voteStatus == 0) {
            user.voteStatus = msg.sender == _account ? uint8(VoteStatus.Voted) : uint8(VoteStatus.VotedViaSurrogate);
            votedUsers[proposalId].push(_account);
        }
    }

    function vote(address _account, uint256 _yesWeight, uint256 _noWeight) external onlyAcceptedSigner(_account) {
        uint256 proposalId = proposals.length - 1;
        uint8 vs = userInfo[proposalId][_account].voteStatus;
        if (msg.sender != _account && vs >= uint8(VoteStatus.Voted)) revert NotVoteAuth();

        _vote(_account, _yesWeight, _noWeight);

        if (msg.sender == _account && vs == uint8(VoteStatus.VotedViaSurrogate)) {
            userInfo[proposalId][_account].voteStatus = uint8(VoteStatus.Voted);
        }
    }

    function updateUserWeight(address _account) external onlyAcceptedSigner(_account) {
        uint256 proposalId = proposals.length - 1;
        if (block.timestamp > proposals[proposalId].endTime) revert Ended();
        if (userInfo[proposalId][_account].voteStatus != 0) revert AlreadyVoted();
        if (userInfo[proposalId][_account].hasUpdated) revert AlreadyUpdated();

        uint256 epoch = proposals[proposalId].epoch;
        uint256 currentBalance = vlCVX.balanceAtEpochOf(epoch, _account);
        uint256 delegatedWeight = delegation.userWeightAtEpochOf(epoch, _account);

        if (currentBalance == delegatedWeight) return;

        int256 diff = int256(currentBalance) - int256(delegatedWeight);

        userInfo[proposalId][_account].hasUpdated = true;

        address delegate = delegation.getDelegateAtEpoch(_account, epoch);
        if (delegate == address(0)) {
            delegate = _account;
        }

        if (delegate != _account) {
            pendingWeightAdjustment[proposalId][delegate] += int96(diff);
            emit PendingWeightAdjustment(proposalId, delegate, diff);
        }
    }

    function forceUpdateDelegate(address _delegate) external {
        uint256 proposalId = proposals.length - 1;
        _applyPending(proposalId, _delegate, userInfo[proposalId][_delegate].voteStatus);
    }

    function createProposal(uint256 _startTime, uint256 _endTime, VoteType _voteType) public onlyOperator {
        uint256 pCnt = proposals.length;
        if (pCnt > 0) {
            if (block.timestamp <= proposals[pCnt - 1].endTime + finalizationTime) revert PrevNotEnded();
        }

        if (_endTime <= _startTime) revert BadTime();
        if (_endTime - _startTime < 3 days) revert BadTime();
        if (_endTime - _startTime > 6 days) revert BadTime();

        vlCVX.checkpointEpoch();
        uint256 epoch = vlCVX.epochCount() - 2;

        proposals.push(Proposal({
            startTime: uint48(_startTime),
            endTime: uint48(_endTime),
            epoch: uint48(epoch),
            voteType: uint8(_voteType)
        }));
        emit NewProposal(proposals.length - 1, _startTime, _endTime, _voteType);
    }

    function forceEndProposal() public onlyOperator {
        uint256 proposalId = proposals.length - 1;
        if (proposals[proposalId].startTime == 0) revert NotStarted();
        if (block.timestamp > proposals[proposalId].endTime + finalizationTime) revert Ended();

        proposals[proposalId].startTime = 0;
        proposals[proposalId].endTime = 0;
        proposals[proposalId].epoch = 0;
        emit ForceEndProposal(proposalId);
    }

    function setOperator(address _op, bool _active) external onlyOwner {
        operators[_op] = _active;
        emit OperatorSet(_op, _active);
    }

    modifier onlyOperator() {
        if (!operators[msg.sender] && owner() != msg.sender) revert NotOperator();
        _;
    }

    modifier onlyAcceptedSigner(address _account) {
        if (msg.sender != _account && !surrogateRegistry.isSurrogate(msg.sender, _account)) revert NotSigner();
        _;
    }
}
