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
    uint256 public constant MIN_PROPOSAL_DURATION = 1 days;
    uint256 public constant MAX_PROPOSAL_DURATION = 6 days;
    uint256 private constant WEIGHT_DIVISOR = 1e17;

    enum VoteStatus {
        None,
        VotedViaSurrogate,
        Voted
    }

    struct UserInfo {
        uint96 baseWeight;
        int96 adjustedWeight;
        uint48 lastVoteTime;
        uint16 yesWeight;
        uint16 noWeight;
        uint8 voteStatus;
        address delegate;
        uint96 totalDelegationWeight;
    }

    struct Proposal {
        uint48 startTime;
        uint48 endTime;
        uint48 epoch;
        uint8 voteType;
        uint104 proposalId;
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

    constructor(address _owner, address _vlCVX, address _surrogateRegistry, address _delegation)
        Ownable(_owner)
    {
        operators[_owner] = true;
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

    function isFinished(uint256 _proposalId) public view returns (bool) {
        return proposals[_proposalId].endTime > 0 && block.timestamp > proposals[_proposalId].endTime;
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

        if (delegate != _account) {
            uint256 delWeight = delegation.userWeightAtEpochOf(epoch, _account);
            uint256 truncatedBase = (baseWeight / WEIGHT_DIVISOR) * WEIGHT_DIVISOR;
            if (truncatedBase > delWeight) {
                delegation.sync(_account);
            }
        }

        uint256 totalDelWeight = delegation.balanceAtEpochOf(epoch, _account);

        user.baseWeight = uint96(baseWeight);
        user.delegate = delegate;
        user.adjustedWeight += int96(int256(totalDelWeight));
        user.totalDelegationWeight = uint96(totalDelWeight);

        userInfo[_proposalId][_account] = user;

        emit UserWeightChange(_proposalId, _account, baseWeight, user.adjustedWeight);

        if (delegate != _account) {
            UserInfo storage del = userInfo[_proposalId][delegate];

            if (del.voteStatus == 0) {
                del.adjustedWeight -= int96(int256(delegation.userWeightAtEpochOf(epoch, _account)));
            } else {
                uint256 currentDelWeight = delegation.userWeightAtEpochOf(epoch, _account);
                (uint256 snapWeight, uint256 snapTs) = delegation.getSyncSnapshot(_account, epoch);
                int256 weightToRemove;

                if (snapTs > 0 && uint256(del.lastVoteTime) > snapTs) {
                    weightToRemove = int256(currentDelWeight);
                } else if (snapTs > 0) {
                    weightToRemove = int256(snapWeight);
                    int256 diff = int256(currentDelWeight) - int256(snapWeight);
                    if (diff > 0) {
                        pendingWeightAdjustment[_proposalId][delegate] -= int96(diff);
                        emit PendingWeightAdjustment(_proposalId, delegate, -diff);
                    }
                } else {
                    weightToRemove = int256(currentDelWeight);
                }

                _changeVoteTotals(_proposalId, -weightToRemove, del.yesWeight, del.noWeight);
                del.adjustedWeight -= int96(weightToRemove);
            }

            emit UserWeightChange(_proposalId, delegate, del.baseWeight, del.adjustedWeight);
        }
    }

    function _vote(address _account, uint256 _yesWeight, uint256 _noWeight) internal {
        uint256 proposalId = proposals.length - 1;
        Proposal storage prop = proposals[proposalId];
        if (block.timestamp < prop.startTime) revert NotStarted();
        if (block.timestamp > prop.endTime) revert Ended();
        if (_yesWeight + _noWeight != max_weight) revert MaxWeight();

        _initBaseInfo(_account, proposalId);

        UserInfo storage user = userInfo[proposalId][_account];

        if (user.voteStatus > 0) {
            int256 oldUserWeight = int256(uint256(user.baseWeight)) + int256(user.adjustedWeight);
            _changeVoteTotals(proposalId, -oldUserWeight, user.yesWeight, user.noWeight);

            uint256 currentBalance = vlCVX.balanceAtEpochOf(prop.epoch, _account);
            uint256 userBaseDiff = currentBalance - user.baseWeight;
            user.baseWeight = uint96(currentBalance);

            uint256 currentDelBal = delegation.balanceAtEpochOf(prop.epoch, _account);
            int256 delDelta = int256(currentDelBal) - int256(uint256(user.totalDelegationWeight));
            user.adjustedWeight += int96(delDelta);
            user.totalDelegationWeight = uint96(currentDelBal);

            if (userBaseDiff > 0 && user.delegate != address(0) && user.delegate != _account) {
                delegation.sync(_account);

                uint256 currentDelWeight = delegation.userWeightAtEpochOf(prop.epoch, _account);
                (uint256 preSyncWeight, uint256 snapTs) = delegation.getSyncSnapshot(_account, prop.epoch);
                int256 realDiff = int256(currentDelWeight) - int256(preSyncWeight);
                if (realDiff > 0) {
                    UserInfo storage del = userInfo[proposalId][user.delegate];
                    if (del.voteStatus > 0) {
                        if (snapTs > 0 && uint256(del.lastVoteTime) > snapTs) {
                            _changeVoteTotals(proposalId, -realDiff, del.yesWeight, del.noWeight);
                            del.adjustedWeight -= int96(realDiff);
                        } else {
                            pendingWeightAdjustment[proposalId][user.delegate] -= int96(realDiff);
                            emit PendingWeightAdjustment(proposalId, user.delegate, -realDiff);
                        }
                    } else {
                        del.adjustedWeight -= int96(realDiff);
                    }
                }
            }

            int96 pend = pendingWeightAdjustment[proposalId][_account];
            if (pend != 0) {
                pendingWeightAdjustment[proposalId][_account] = 0;
                user.adjustedWeight += pend;
            }

            emit UserWeightChange(proposalId, _account, user.baseWeight, user.adjustedWeight);
        }

        int256 userWeight = int256(uint256(user.baseWeight)) + int256(user.adjustedWeight);
        if (userWeight <= 0) revert NoWeight();

        user.yesWeight = uint16(_yesWeight);
        user.noWeight = uint16(_noWeight);
        _changeVoteTotals(proposalId, userWeight, _yesWeight, _noWeight);

        emit VoteCast(proposalId, _account, _yesWeight, _noWeight);

        user.lastVoteTime = uint48(block.timestamp);

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

    function createProposal(uint256 _startTime, uint256 _endTime, VoteType _voteType, uint256 _proposalId) public onlyOperator {
        uint256 pCnt = proposals.length;
        if (pCnt > 0) {
            if (block.timestamp <= proposals[pCnt - 1].endTime + finalizationTime) revert PrevNotEnded();
        }

        if (_endTime <= _startTime) revert BadTime();
        if (_endTime <= block.timestamp) revert BadTime();
        if (_endTime - _startTime < MIN_PROPOSAL_DURATION) revert BadTime();
        if (_endTime - _startTime > MAX_PROPOSAL_DURATION) revert BadTime();

        vlCVX.checkpointEpoch();
        uint256 epoch = vlCVX.epochCount() - 2;

        proposals.push(Proposal({
            startTime: uint48(_startTime),
            endTime: uint48(_endTime),
            epoch: uint48(epoch),
            voteType: uint8(_voteType),
            proposalId: uint104(_proposalId)
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
