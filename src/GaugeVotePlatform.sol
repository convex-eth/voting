// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./GaugeRegistry.sol";
import "./SurrogateRegistry.sol";
import "./Delegation.sol";
import "./interface/IvlCVX.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract GaugeVotePlatform is Ownable2Step {

    error NotStarted();
    error Ended();
    error Mismatch();
    error NoWeight();
    error NotGauge();
    error MaxWeight();
    error PrevNotEnded();
    error BadTime();
    error AlreadyVoted();
    error AlreadyUpdated();
    error NotVoteAuth();
    error NotSigner();
    error NotOperator();

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

    mapping(uint256 => mapping(address => int96)) public pendingWeightAdjustment;

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
        UserInfo storage u = userInfo[_proposalId][_user];
        voted = u.voteStatus > 0;
        baseWeight = u.baseWeight;
        adjustedWeight = u.adjustedWeight;
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

                GaugeVote[] storage delegateVotes = votes[_proposalId][delegate];
                uint256 len = delegateVotes.length;

                for (uint256 i = 0; i < len;) {
                    _changeGaugeTotal(_proposalId, delegateVotes[i].gauge, int256(uint256(delegateVotes[i].weight)) * netDelta / int256(max_weight));
                    unchecked { ++i; }
                }

                emit GaugeWeightsUpdated(_proposalId, delegate);
                voteTotals[_proposalId] = voteTotals[_proposalId] + uint256(int256(pending)) - uint256(weightToRemove);
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
            voteTotals[_proposalId] += uint256(int256(pending));

            GaugeVote[] storage delegateVotes = votes[_proposalId][_account];
            uint256 len = delegateVotes.length;
            for (uint256 i = 0; i < len;) {
                _changeGaugeTotal(_proposalId, delegateVotes[i].gauge, int256(uint256(delegateVotes[i].weight)) * int256(pending) / int256(max_weight));
                unchecked { ++i; }
            }
        }

        emit GaugeWeightsUpdated(_proposalId, _account);
        emit UserWeightChange(_proposalId, _account, userInfo[_proposalId][_account].baseWeight, userInfo[_proposalId][_account].adjustedWeight);
    }

    function _vote(address _account, address[] calldata _gauges, uint256[] calldata _weights) internal {
        uint256 proposalId = proposals.length - 1;
        Proposal storage prop = proposals[proposalId];
        if (block.timestamp < prop.startTime) revert NotStarted();
        if (equalizerAccounts[_account]) {
            if (block.timestamp > prop.endTime + overtime) revert Ended();
        } else {
            if (block.timestamp > prop.endTime) revert Ended();
        }
        if (_gauges.length != _weights.length) revert Mismatch();

        _initBaseInfo(_account, proposalId);

        UserInfo storage user = userInfo[proposalId][_account];
        int256 userWeight = int256(uint256(user.baseWeight)) + int256(user.adjustedWeight);
        if (userWeight <= 0) revert NoWeight();

        if (user.voteStatus > 0) {
            GaugeVote[] storage oldVotes = votes[proposalId][_account];
            uint256 oldLen = oldVotes.length;
            for (uint256 i = 0; i < oldLen;) {
                _changeGaugeTotal(proposalId, oldVotes[i].gauge, -(int256(uint256(oldVotes[i].weight)) * userWeight / int256(max_weight)));
                unchecked { ++i; }
            }

            uint256 currentBalance = vlCVX.balanceAtEpochOf(prop.epoch, _account);
            if (currentBalance != uint256(user.baseWeight)) {
                uint256 oldBaseWeight = user.baseWeight;
                user.baseWeight = uint96(currentBalance);
                voteTotals[proposalId] += currentBalance - oldBaseWeight;
                emit UserWeightChange(proposalId, _account, currentBalance, user.adjustedWeight);
            }
        }

        _applyPending(proposalId, _account, user.voteStatus);

        userWeight = int256(uint256(user.baseWeight)) + int256(user.adjustedWeight);
        if (userWeight <= 0) revert NoWeight();

        delete votes[proposalId][_account];
        uint256 totalweight;
        for (uint256 i = 0; i < _weights.length; i++) {
            if (_weights[i] == 0) revert NoWeight();
            if (!gaugeRegistry.isRegisteredGauge(_gauges[i])) revert NotGauge();
            votes[proposalId][_account].push(GaugeVote({gauge: _gauges[i], weight: uint16(_weights[i])}));
            totalweight += _weights[i];
        }
        if (totalweight > max_weight) revert MaxWeight();

        for (uint256 i = 0; i < _weights.length; i++) {
            _changeGaugeTotal(proposalId, _gauges[i], int256(_weights[i]) * userWeight / int256(max_weight));
        }
        emit GaugeWeightsUpdated(proposalId, _account);
        emit VoteCast(proposalId, _account, _gauges, _weights);

        if (user.voteStatus == 0) {
            user.voteStatus = msg.sender == _account ? uint8(VoteStatus.Voted) : uint8(VoteStatus.VotedViaSurrogate);
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

    function vote(address _account, address[] calldata _gauges, uint256[] calldata _weights) external onlyAcceptedSigner(_account) {
        uint256 proposalId = proposals.length - 1;
        uint8 vs = userInfo[proposalId][_account].voteStatus;
        if (msg.sender != _account && vs >= uint8(VoteStatus.Voted)) revert NotVoteAuth();

        _vote(_account, _gauges, _weights);

        if (msg.sender == _account && vs == uint8(VoteStatus.VotedViaSurrogate)) {
            userInfo[proposalId][_account].voteStatus = uint8(VoteStatus.Voted);
        }
    }

    function isFinalized(uint256 _proposalId) public view returns (bool) {
        return proposals[_proposalId].endTime > 0 && block.timestamp > proposals[_proposalId].endTime + overtime;
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

    function createProposal(uint256 _startTime, uint256 _endTime) public onlyOperator {
        uint256 pCnt = proposals.length;
        if (pCnt > 0) {
            if (block.timestamp <= proposals[pCnt - 1].endTime + overtime) revert PrevNotEnded();
        }

        if (_endTime <= _startTime) revert BadTime();
        if (_endTime - _startTime < 3 days) revert BadTime();
        if (_endTime - _startTime > 6 days) revert BadTime();

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
        if (proposals[proposalId].startTime == 0) revert NotStarted();
        if (block.timestamp > proposals[proposalId].endTime + overtime) revert Ended();

        proposals[proposalId].startTime = 0;
        proposals[proposalId].endTime = 0;
        proposals[proposalId].epoch = 0;
        emit ForceEndProposal(proposalId);
    }

    function setOperator(address _op, bool _active) external onlyOwner {
        operators[_op] = _active;
        emit OperatorSet(_op, _active);
    }

    function setOvertimeAccount(address _eq, bool _active) external onlyOwner {
        equalizerAccounts[_eq] = _active;
        emit EqualizerAccountSet(_eq, _active);
    }

    modifier onlyOperator() {
        if (!operators[msg.sender] && owner() != msg.sender) revert NotOperator();
        _;
    }

    modifier onlyAcceptedSigner(address _account) {
        if (msg.sender != _account && !surrogateRegistry.isSurrogate(msg.sender, _account)) revert NotSigner();
        _;
    }

    event VoteCast(uint256 indexed proposalId, address indexed user, address[] gauges, uint256[] weights);
    event NewProposal(uint256 indexed id, uint256 start, uint256 end);
    event ForceEndProposal(uint256 indexed id);
    event UserWeightChange(uint256 indexed pid, address indexed user, uint256 baseWeight, int256 adjustedWeight);
    event GaugeWeightsUpdated(uint256 indexed pid, address indexed user);
    event PendingWeightAdjustment(uint256 indexed pid, address indexed delegate, int256 diff);
    event OperatorSet(address indexed op, bool active);
    event EqualizerAccountSet(address indexed eq, bool active);

    constructor(address _vlCVX, address _gaugeRegistry, address _surrogateRegistry, address _delegation)
        Ownable(msg.sender)
    {
        operators[msg.sender] = true;
        vlCVX = IvlCVX(_vlCVX);
        gaugeRegistry = GaugeRegistry(_gaugeRegistry);
        surrogateRegistry = SurrogateRegistry(_surrogateRegistry);
        delegation = Delegation(_delegation);
    }

}
