// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./Delegation.sol";
import "./SurrogateRegistry.sol";
import "./interface/IvlCVX.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract DaoVotePlatform is Ownable2Step {
    string public name;

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
    error DelegateOverSubtracted();

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
        uint48 lastVoteSyncNonce;
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

    event VoteCast(uint256 indexed _proposalId, address indexed user, uint256 yesWeight, uint256 noWeight);
    event NewProposal(uint256 indexed id, uint256 start, uint256 end, VoteType voteType);
    event ForceEndProposal(uint256 indexed id);
    event UserWeightChange(uint256 indexed pid, address indexed user, uint256 baseWeight, int256 adjustedWeight);
    event PendingWeightAdjustment(uint256 indexed pid, address indexed delegate, int256 diff);
    event OperatorSet(address indexed op, bool active);

    /// @notice Creates a new DaoVotePlatform contract
    /// @param _name Contract name identifier
    /// @param _owner Address of the contract owner
    /// @param _vlCVX Address of the vlCVX contract
    /// @param _surrogateRegistry Address of the SurrogateRegistry
    /// @param _delegation Address of the Delegation contract
    constructor(string memory _name, address _owner, address _vlCVX, address _surrogateRegistry, address _delegation)
        Ownable(_owner)
    {
        name = _name;
        operators[_owner] = true;
        vlCVX = IvlCVX(_vlCVX);
        surrogateRegistry = SurrogateRegistry(_surrogateRegistry);
        delegation = Delegation(_delegation);
    }

    /// @notice Returns the current epoch start timestamp
    /// @return Current epoch start time
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / epochDuration * epochDuration;
    }

    /// @notice Returns the total number of proposals
    /// @return Proposal count
    function proposalCount() external view returns (uint256) {
        return proposals.length;
    }

    /// @notice Returns the number of voters for a proposal
    /// @param _proposalId Proposal identifier
    /// @return Voter count
    function getVoterCount(uint256 _proposalId) external view returns (uint256) {
        return votedUsers[_proposalId].length;
    }

    /// @notice Returns the voter at a given index for a proposal
    /// @param _proposalId Proposal identifier
    /// @param _index Voter index
    /// @return Voter address
    function getVoterAtIndex(uint256 _proposalId, uint256 _index) external view returns (address) {
        return votedUsers[_proposalId][_index];
    }

    /// @notice Returns the total yes votes for a proposal
    /// @param _proposalId Proposal identifier
    /// @return Yes vote total
    function getYes(uint256 _proposalId) external view returns (uint256) {
        return _voteTotals[_proposalId].yes;
    }

    /// @notice Returns the total no votes for a proposal
    /// @param _proposalId Proposal identifier
    /// @return No vote total
    function getNo(uint256 _proposalId) external view returns (uint256) {
        return _voteTotals[_proposalId].no;
    }

    /// @notice Returns the total votes cast for a proposal
    /// @param _proposalId Proposal identifier
    /// @return Total vote sum
    function voteTotals(uint256 _proposalId) external view returns (uint256) {
        return uint256(_voteTotals[_proposalId].yes) + uint256(_voteTotals[_proposalId].no);
    }

    /// @notice Returns vote details for a user on a proposal
    /// @param _proposalId Proposal identifier
    /// @param _user User address
    /// @return voted Whether user has voted
    /// @return yesWeight Yes weight allocation
    /// @return noWeight No weight allocation
    /// @return baseWeight User's base voting weight
    /// @return adjustedWeight User's adjusted weight
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

    /// @notice Checks if a proposal is finalized (voting ended + finalization window)
    /// @param _proposalId Proposal identifier
    /// @return True if finalized
    function isFinalized(uint256 _proposalId) public view returns (bool) {
        return proposals[_proposalId].endTime > 0 && block.timestamp > proposals[_proposalId].endTime + finalizationTime;
    }

    /// @notice Checks if a proposal's voting period has ended
    /// @param _proposalId Proposal identifier
    /// @return True if voting has ended
    function isFinished(uint256 _proposalId) public view returns (bool) {
        return proposals[_proposalId].endTime > 0 && block.timestamp > proposals[_proposalId].endTime;
    }

    /// @notice Updates vote totals with a delta and yes/no distribution
    function _changeVoteTotals(uint256 _proposalId, int256 _delta, uint256 _yesWeight) internal {
        VoteTotals storage totals = _voteTotals[_proposalId];
        int256 yesDelta = _delta * int256(_yesWeight) / int256(max_weight);
        int256 noDelta = _delta - yesDelta;
        if (yesDelta >= 0) {
            totals.yes += uint128(uint256(yesDelta));
        } else {
            totals.yes -= uint128(uint256(-yesDelta));
        }
        if (noDelta >= 0) {
            totals.no += uint128(uint256(noDelta));
        } else {
            totals.no -= uint128(uint256(-noDelta));
        }
    }

    /// @notice Initializes base voting info for an account
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
            if (truncatedBase != delWeight) {
                delegation.syncAtEpoch(_account, epoch);
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
                (uint256 snapWeight, uint256 snapNonce) = delegation.getSyncSnapshot(_account, epoch);
                int256 weightToRemove;

                if (snapNonce > 0 && snapNonce <= uint256(del.lastVoteSyncNonce)) {
                    weightToRemove = int256(currentDelWeight);
                } else if (snapNonce > 0) {
                    weightToRemove = int256(snapWeight);
                    int256 diff = int256(currentDelWeight) - int256(snapWeight);
                    if (diff > 0) {
                        pendingWeightAdjustment[_proposalId][delegate] -= int96(diff);
                        emit PendingWeightAdjustment(_proposalId, delegate, -diff);
                    }
                } else {
                    weightToRemove = int256(currentDelWeight);
                }

                _changeVoteTotals(_proposalId, -weightToRemove, del.yesWeight);
                del.adjustedWeight -= int96(weightToRemove);
                if (del.adjustedWeight < 0) revert DelegateOverSubtracted();
            }

            emit UserWeightChange(_proposalId, delegate, del.baseWeight, del.adjustedWeight);
        }
    }

    /// @notice Casts or updates a vote for an account on a specific proposal
    /// @param _proposalId Proposal identifier
    /// @param _account Account to vote for
    /// @param _yesWeight Yes weight allocation (0-10000)
    /// @param _noWeight No weight allocation (0-10000)
    function _vote(uint256 _proposalId, address _account, uint256 _yesWeight, uint256 _noWeight) internal {
        Proposal storage prop = proposals[_proposalId];
        if (block.timestamp < prop.startTime) revert NotStarted();
        if (block.timestamp > prop.endTime) revert Ended();
        if (_yesWeight + _noWeight != max_weight) revert MaxWeight();

        _initBaseInfo(_account, _proposalId);

        UserInfo storage user = userInfo[_proposalId][_account];

        if (user.voteStatus > 0) {
            int256 oldUserWeight = int256(uint256(user.baseWeight)) + int256(user.adjustedWeight);
            _changeVoteTotals(_proposalId, -oldUserWeight, user.yesWeight);

            uint256 currentBalance = vlCVX.balanceAtEpochOf(prop.epoch, _account);
            uint256 userBaseDiff = currentBalance - user.baseWeight;
            user.baseWeight = uint96(currentBalance);

            uint256 currentDelBal = delegation.balanceAtEpochOf(prop.epoch, _account);
            int256 delDelta = int256(currentDelBal) - int256(uint256(user.totalDelegationWeight));
            user.adjustedWeight += int96(delDelta);
            user.totalDelegationWeight = uint96(currentDelBal);

            if (userBaseDiff > 0 && user.delegate != address(0) && user.delegate != _account) {
                delegation.syncAtEpoch(_account, prop.epoch);

                uint256 currentDelWeight = delegation.userWeightAtEpochOf(prop.epoch, _account);
                (uint256 preSyncWeight, uint256 snapNonce) = delegation.getSyncSnapshot(_account, prop.epoch);
                int256 realDiff = int256(currentDelWeight) - int256(preSyncWeight);
                if (realDiff > 0) {
                    UserInfo storage del = userInfo[_proposalId][user.delegate];
                    if (del.voteStatus > 0) {
                        if (snapNonce > 0 && snapNonce <= uint256(del.lastVoteSyncNonce)) {
                            _changeVoteTotals(_proposalId, -realDiff, del.yesWeight);
                            del.adjustedWeight -= int96(realDiff);
                            if (del.adjustedWeight < 0) revert DelegateOverSubtracted();
                        } else {
                            pendingWeightAdjustment[_proposalId][user.delegate] -= int96(realDiff);
                            emit PendingWeightAdjustment(_proposalId, user.delegate, -realDiff);
                        }
                    } else {
                        del.adjustedWeight -= int96(realDiff);
                    }
                }
            }

            int96 pend = pendingWeightAdjustment[_proposalId][_account];
            if (pend != 0) {
                pendingWeightAdjustment[_proposalId][_account] = 0;
                user.adjustedWeight += pend;
            }

            emit UserWeightChange(_proposalId, _account, user.baseWeight, user.adjustedWeight);
        }

        int256 userWeight = int256(uint256(user.baseWeight)) + int256(user.adjustedWeight);
        if (userWeight <= 0) revert NoWeight();

        user.yesWeight = uint16(_yesWeight);
        user.noWeight = uint16(_noWeight);
        _changeVoteTotals(_proposalId, userWeight, _yesWeight);

        emit VoteCast(_proposalId, _account, _yesWeight, _noWeight);

        user.lastVoteSyncNonce = uint48(delegation.syncNonce());

        if (user.voteStatus == 0) {
            user.voteStatus = msg.sender == _account ? uint8(VoteStatus.Voted) : uint8(VoteStatus.VotedViaSurrogate);
            votedUsers[_proposalId].push(_account);
        }
    }

    /// @notice Casts or updates a vote on the latest proposal
    /// @param _account Account to vote for
    /// @param _yesWeight Yes weight allocation (0-10000)
    /// @param _noWeight No weight allocation (0-10000)
    function vote(uint256 _proposalId, address _account, uint256 _yesWeight, uint256 _noWeight) external onlyAcceptedSigner(_account) {

        uint8 vs = userInfo[_proposalId][_account].voteStatus;
        if (msg.sender != _account && vs >= uint8(VoteStatus.Voted)) revert NotVoteAuth();

        _vote(_proposalId, _account, _yesWeight, _noWeight);

        if (msg.sender == _account && vs == uint8(VoteStatus.VotedViaSurrogate)) {
            userInfo[_proposalId][_account].voteStatus = uint8(VoteStatus.Voted);
        }
    }

    /// @notice Creates a new DAO proposal
    /// @param _startTime Unix timestamp when voting begins
    /// @param _endTime Unix timestamp when voting ends
    /// @param _voteType Type of proposal (Ownership or Parameter)
    /// @param _proposalId External proposal identifier
    function createProposal(uint256 _startTime, uint256 _endTime, VoteType _voteType, uint256 _proposalId) public onlyOperator {
        if (_endTime <= _startTime) revert BadTime();
        if (_endTime <= block.timestamp) revert BadTime();
        if (_endTime - _startTime < MIN_PROPOSAL_DURATION) revert BadTime();
        if (_endTime - _startTime > MAX_PROPOSAL_DURATION) revert BadTime();

        vlCVX.checkpointEpoch();
        uint256 epoch = vlCVX.epochCount() - 2;
        (, uint32 epochStart) = vlCVX.epochs(epoch);
        while (epoch > 0 && uint256(epochStart) > _startTime) {
            unchecked { --epoch; }
            (, epochStart) = vlCVX.epochs(epoch);
        }

        proposals.push(Proposal({
            startTime: uint48(_startTime),
            endTime: uint48(_endTime),
            epoch: uint48(epoch),
            voteType: uint8(_voteType),
            proposalId: uint104(_proposalId)
        }));
        emit NewProposal(proposals.length - 1, _startTime, _endTime, _voteType);
    }

    /// @notice Forces a specific proposal to end immediately
    /// @param _proposalId Proposal identifier
    function forceEndProposal(uint256 _proposalId) public onlyOperator {
        if (proposals[_proposalId].startTime == 0) revert NotStarted();
        if (block.timestamp > proposals[_proposalId].endTime + finalizationTime) revert Ended();

        proposals[_proposalId].startTime = 0;
        proposals[_proposalId].endTime = 0;
        proposals[_proposalId].epoch = 0;
        emit ForceEndProposal(_proposalId);
    }

    /// @notice Sets an operator address
    /// @param _op Operator address
    /// @param _active True to add, false to remove
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

    /// @notice Returns the contract version
    /// @return _major Major version
    /// @return _minor Minor version
    /// @return _patch Patch version
    function version() external pure returns (uint256 _major, uint256 _minor, uint256 _patch) {
        _major = 1;
        _minor = 0;
        _patch = 0;
    }
}
