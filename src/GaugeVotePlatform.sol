// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./GaugeRegistry.sol";
import "./SurrogateRegistry.sol";
import "./Delegation.sol";
import "./interface/IvlCVX.sol";

contract GaugeVotePlatform {

    address public owner;
    address public pendingowner;
    mapping(address => bool) public operators;

    IvlCVX public immutable vlCVX;
    GaugeRegistry public immutable gaugeRegistry;
    SurrogateRegistry public immutable surrogateRegistry;
    Delegation public immutable delegation;

    uint256 public constant epochDuration = 86400 * 7;

    enum VoteStatus {
        None,
        VotedViaSurrogate,
        Voted
    }

    struct UserInfo {
        uint96 baseWeight;
        int96 adjustedWeight;
        uint8 voteStatus;
        bool hasUpdated;
        address delegate;
    }
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => address[]) public votedUsers;

    struct Proposal {
        uint256 startTime;
        uint256 endTime;
        uint256 epoch;
    }

    struct GaugeVote {
        address gauge;
        uint16 weight;
    }

    struct GaugeTotalEntry {
        address gauge;
        uint96 totalWeight;
    }

    mapping(uint256 => GaugeTotalEntry[]) internal _gaugeEntries;
    mapping(uint256 => mapping(address => uint256)) internal _gaugeIndex;
    mapping(uint256 => uint256) public voteTotals;

    Proposal[] public proposals;
    mapping(uint256 => mapping(address => GaugeVote[])) internal votes;
    uint256 public constant max_weight = 10000;

    mapping(address => bool) public equalizerAccounts;
    uint256 public constant overtime = 10 minutes;

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

    function gaugeTotal(uint256 _proposalId, address _gauge) external view returns (uint256) {
        uint256 idx = _gaugeIndex[_proposalId][_gauge];
        if (idx == 0) return 0;
        return _gaugeEntries[_proposalId][idx - 1].totalWeight;
    }

    function getGaugeCount(uint256 _proposalId) external view returns (uint256) {
        return _gaugeEntries[_proposalId].length;
    }

    function getGaugeEntry(uint256 _proposalId, uint256 _index) external view returns (address gauge, uint256 totalWeight) {
        GaugeTotalEntry storage entry = _gaugeEntries[_proposalId][_index];
        gauge = entry.gauge;
        totalWeight = entry.totalWeight;
    }

    function getVote(uint256 _proposalId, address _user) public view returns (address[] memory gauges, uint256[] memory weights, bool voted, uint256 baseWeight, int256 adjustedWeight) {
        GaugeVote[] storage userVotes = votes[_proposalId][_user];
        uint256 len = userVotes.length;
        gauges = new address[](len);
        weights = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            gauges[i] = userVotes[i].gauge;
            weights[i] = userVotes[i].weight;
            unchecked { ++i; }
        }
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

    function _initBaseInfo(address _account, uint256 _proposalId) internal {
        if (userInfo[_proposalId][_account].delegate != address(0)) return;

        uint256 epoch = proposals[_proposalId].epoch;

        uint256 baseWeight = _getBaseWeight(_account, epoch);
        address delegate = _getDelegate(_account, epoch);

        if (delegate == address(0)) {
            delegate = _account;
        }

        userInfo[_proposalId][_account].baseWeight = uint96(baseWeight);
        userInfo[_proposalId][_account].delegate = delegate;
        userInfo[_proposalId][_account].adjustedWeight += int96(int256(_getDelegateTotalWeight(_account, epoch)));

        emit UserWeightChange(_proposalId, _account, baseWeight, userInfo[_proposalId][_account].adjustedWeight);

        if (delegate != _account) {
            int256 weightToRemove;
            if (userInfo[_proposalId][_account].hasUpdated) {
                weightToRemove = int256(baseWeight);
            } else {
                weightToRemove = int256(_getDelegatedWeight(_account, epoch));
            }

            if (userInfo[_proposalId][delegate].voteStatus > 0) {
                int256 delegateTotalWeight = int256(uint256(userInfo[_proposalId][delegate].baseWeight)) + int256(userInfo[_proposalId][delegate].adjustedWeight);
                GaugeVote[] storage delegateVotes = votes[_proposalId][delegate];
                uint256 len = delegateVotes.length;

                for (uint256 i = 0; i < len;) {
                    int256 oldContribution = int256(uint256(delegateVotes[i].weight)) * delegateTotalWeight / int256(max_weight);
                    int256 newContribution = int256(uint256(delegateVotes[i].weight)) * (delegateTotalWeight - weightToRemove) / int256(max_weight);
                    _changeGaugeTotal(_proposalId, delegateVotes[i].gauge, newContribution - oldContribution);
                    unchecked { ++i; }
                }

                emit GaugeWeightsUpdated(_proposalId, delegate);
                voteTotals[_proposalId] -= uint256(weightToRemove);
            }

            userInfo[_proposalId][delegate].adjustedWeight -= int96(weightToRemove);
            emit UserWeightChange(_proposalId, delegate, userInfo[_proposalId][delegate].baseWeight, userInfo[_proposalId][delegate].adjustedWeight);
        }
    }

    function _vote(address _account, address[] calldata _gauges, uint256[] calldata _weights) internal {
        uint256 proposalId = proposals.length - 1;
        require(block.timestamp >= proposals[proposalId].startTime, "!start");
        if (equalizerAccounts[_account]) {
            require(block.timestamp <= proposals[proposalId].endTime + overtime, "!end");
        } else {
            require(block.timestamp <= proposals[proposalId].endTime, "!end");
        }
        require(_gauges.length == _weights.length, "mismatch");

        _initBaseInfo(_account, proposalId);

        int256 userbase = int256(uint256(userInfo[proposalId][_account].baseWeight));
        int256 userWeight = userbase + int256(userInfo[proposalId][_account].adjustedWeight);
        require(userWeight > 0, "!weight");

        if (userInfo[proposalId][_account].voteStatus > 0) {
            GaugeVote[] storage oldVotes = votes[proposalId][_account];
            uint256 oldLen = oldVotes.length;
            for (uint256 i = 0; i < oldLen;) {
                _changeGaugeTotal(proposalId, oldVotes[i].gauge, -(int256(uint256(oldVotes[i].weight)) * userWeight / int256(max_weight)));
                unchecked { ++i; }
            }

            uint256 currentBalance = _getBaseWeight(_account, proposals[proposalId].epoch);
            if (currentBalance != uint256(userInfo[proposalId][_account].baseWeight)) {
                uint256 oldBaseWeight = userInfo[proposalId][_account].baseWeight;
                userInfo[proposalId][_account].baseWeight = uint96(currentBalance);
                userWeight = int256(currentBalance) + int256(userInfo[proposalId][_account].adjustedWeight);
                voteTotals[proposalId] += currentBalance - oldBaseWeight;
                emit UserWeightChange(proposalId, _account, currentBalance, userInfo[proposalId][_account].adjustedWeight);
            }
        }

        require(userWeight > 0, "!weight");

        delete votes[proposalId][_account];
        uint256 totalweight;
        for (uint256 i = 0; i < _weights.length; i++) {
            require(_weights[i] > 0, "!weight");
            require(gaugeRegistry.isRegisteredGauge(_gauges[i]), "!gauge");
            votes[proposalId][_account].push(GaugeVote({gauge: _gauges[i], weight: uint16(_weights[i])}));
            totalweight += _weights[i];
        }
        require(totalweight <= max_weight, "max weight");

        for (uint256 i = 0; i < _weights.length; i++) {
            _changeGaugeTotal(proposalId, _gauges[i], int256(_weights[i]) * userWeight / int256(max_weight));
        }
        emit GaugeWeightsUpdated(proposalId, _account);
        emit VoteCast(proposalId, _account, _gauges, _weights);

        if (userInfo[proposalId][_account].voteStatus == 0) {
            userInfo[proposalId][_account].voteStatus = msg.sender == _account ? uint8(VoteStatus.Voted) : uint8(VoteStatus.VotedViaSurrogate);
            votedUsers[proposalId].push(_account);
            voteTotals[proposalId] += uint256(userWeight);
        }
    }

    function _changeGaugeTotal(uint256 _proposalId, address _gauge, int256 _changeValue) internal {
        uint256 idx = _gaugeIndex[_proposalId][_gauge];
        uint256 absVal;
        unchecked {
            absVal = _changeValue > 0 ? uint256(_changeValue) : uint256(-_changeValue);
        }

        if (idx == 0) {
            if (_changeValue > 0) {
                _gaugeEntries[_proposalId].push(GaugeTotalEntry({gauge: _gauge, totalWeight: uint96(absVal)}));
                _gaugeIndex[_proposalId][_gauge] = _gaugeEntries[_proposalId].length;
            }
            return;
        }

        GaugeTotalEntry storage existing = _gaugeEntries[_proposalId][idx - 1];

        if (_changeValue > 0) {
            existing.totalWeight += uint96(absVal);
        } else {
            existing.totalWeight -= uint96(absVal);
        }

        if (existing.totalWeight == 0) {
            GaugeTotalEntry[] storage entries = _gaugeEntries[_proposalId];
            uint256 lastIdx = entries.length;
            if (idx < lastIdx) {
                GaugeTotalEntry storage last = entries[lastIdx - 1];
                existing.gauge = last.gauge;
                existing.totalWeight = last.totalWeight;
                _gaugeIndex[_proposalId][last.gauge] = idx;
            }
            entries.pop();
            _gaugeIndex[_proposalId][_gauge] = 0;
        }
    }

    function _readGaugeTotal(uint256 _proposalId, address _gauge) internal view returns (uint256) {
        uint256 idx = _gaugeIndex[_proposalId][_gauge];
        if (idx == 0) return 0;
        return _gaugeEntries[_proposalId][idx - 1].totalWeight;
    }

    function _canSign(address _account) internal view returns (bool) {
        if (msg.sender == _account) {
            return true;
        }
        if (surrogateRegistry.isSurrogate(msg.sender, _account)) {
            return true;
        }
        return false;
    }

    function vote(address _account, address[] calldata _gauges, uint256[] calldata _weights) external onlyAcceptedSigner(_account) {
        uint256 proposalId = proposals.length - 1;
        require(msg.sender == _account || userInfo[proposalId][_account].voteStatus <= uint8(VoteStatus.VotedViaSurrogate), "!voteAuth");

        _vote(_account, _gauges, _weights);

        if (userInfo[proposalId][_account].voteStatus <= uint8(VoteStatus.VotedViaSurrogate) && msg.sender == _account) {
            userInfo[proposalId][_account].voteStatus = uint8(VoteStatus.Voted);
        }
    }

    function isFinalized(uint256 _proposalId) public view returns (bool) {
        return proposals[_proposalId].endTime > 0 && block.timestamp > proposals[_proposalId].endTime + overtime;
    }

    function updateUserWeight(address _account) external onlyAcceptedSigner(_account) {
        uint256 proposalId = proposals.length - 1;
        require(block.timestamp <= proposals[proposalId].endTime, "!end");
        require(userInfo[proposalId][_account].voteStatus == 0, "already voted");
        require(!userInfo[proposalId][_account].hasUpdated, "already updated");

        uint256 epoch = proposals[proposalId].epoch;
        uint256 currentBalance = _getBaseWeight(_account, epoch);
        uint256 delegatedWeight = _getDelegatedWeight(_account, epoch);

        if (currentBalance == delegatedWeight) return;

        int256 diff = int256(currentBalance) - int256(delegatedWeight);

        userInfo[proposalId][_account].hasUpdated = true;

        address delegate = _getDelegate(_account, epoch);
        if (delegate == address(0)) {
            delegate = _account;
        }

        if (delegate != _account) {
            if (userInfo[proposalId][delegate].voteStatus > 0) {
                int256 delegateTotalWeight = int256(uint256(userInfo[proposalId][delegate].baseWeight)) + int256(userInfo[proposalId][delegate].adjustedWeight);
                GaugeVote[] storage delegateVotes = votes[proposalId][delegate];
                uint256 len = delegateVotes.length;
                for (uint256 i = 0; i < len;) {
                    int256 oldContribution = int256(uint256(delegateVotes[i].weight)) * delegateTotalWeight / int256(max_weight);
                    int256 newContribution = int256(uint256(delegateVotes[i].weight)) * (delegateTotalWeight + diff) / int256(max_weight);
                    _changeGaugeTotal(proposalId, delegateVotes[i].gauge, newContribution - oldContribution);
                    unchecked { ++i; }
                }
                emit GaugeWeightsUpdated(proposalId, delegate);
                voteTotals[proposalId] += uint256(diff);
            }

            userInfo[proposalId][delegate].adjustedWeight += int96(diff);
            emit UserWeightChange(proposalId, delegate, userInfo[proposalId][delegate].baseWeight, userInfo[proposalId][delegate].adjustedWeight);
        }
    }

    function createProposal(uint256 _startTime, uint256 _endTime) public onlyOperator {
        uint256 pCnt = proposals.length;
        if (pCnt > 0) {
            require(block.timestamp > proposals[pCnt - 1].endTime + overtime, "!prev_end");
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
        emit NewProposal(proposals.length - 1, _startTime, _endTime);
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

    function transferOwnership(address _owner) external onlyOwner {
        pendingowner = _owner;
        emit TransferOwnership(_owner);
    }

    function acceptOwnership() external {
        require(pendingowner == msg.sender, "!pendingowner");
        owner = pendingowner;
        pendingowner = address(0);
        emit AcceptedOwnership(owner);
    }

    function setOperator(address _op, bool _active) external onlyOwner {
        operators[_op] = _active;
        emit OperatorSet(_op, _active);
    }

    function setOvertimeAccount(address _eq, bool _active) external onlyOwner {
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
    event GaugeWeightsUpdated(uint256 indexed pid, address indexed user);
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