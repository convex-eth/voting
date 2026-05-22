// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./DaoVotePlatform.sol";
import "./interface/IvlCVX.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

interface IResupplyStaker {
    function safeExecute(address target, bytes calldata data) external returns (bytes memory);
    function claimAndStake() external returns (uint256 amount);
}

interface IResupplyVoter {
    function voteForProposal(address account, uint256 id, uint256 pctYes, uint256 pctNo) external;
}

contract ResupplyVoteExecutor is Ownable2Step {
    string public name;

    error NotFinished();
    error AlreadyExecuted();
    error QuorumNotMet();
    error ZeroSupply();
    error InvalidQuorum();

    uint256 public constant WEIGHT_BPS = 10000;
    uint256 public constant MAX_QUORUM_BPS = 10000;
    address public constant RESUPPLY_STAKER = 0xCCCCCccc94bFeCDd365b4Ee6B86108fC91848901;
    address public constant RESUPPLY_VOTER = 0x11111111063874cE8dC6232cb5C1C849359476E6;

    DaoVotePlatform public immutable votePlatform;

    uint256 public quorumBps;
    mapping(address => bool) public guardians;
    mapping(uint256 => bool) public executed;

    event DaoVoteExecuted(uint256 indexed proposalId, uint256 yay, uint256 nay);
    event GuardianSet(address indexed guardian, bool active);
    event QuorumSet(uint256 quorumBps);

    /// @notice Creates a new ResupplyVoteExecutor contract
    /// @param _name Contract name identifier
    /// @param _owner Address of the contract owner
    /// @param _votePlatform Address of the DaoVotePlatform contract
    /// @param _quorumBps Minimum quorum in basis points
    constructor(string memory _name, address _owner, address _votePlatform, uint256 _quorumBps) Ownable(_owner) {
        name = _name;
        if (_quorumBps > MAX_QUORUM_BPS) revert InvalidQuorum();
        votePlatform = DaoVotePlatform(_votePlatform);
        quorumBps = _quorumBps;
    }

    /// @notice Executes a finalized DAO vote on Resupply
    /// @param _proposalId Proposal identifier to execute
    function executeDaoVote(uint256 _proposalId) external {
        if (executed[_proposalId]) revert AlreadyExecuted();
        if (!votePlatform.isFinished(_proposalId)) revert NotFinished();
        if (!votePlatform.isFinalized(_proposalId) && !guardians[msg.sender]) revert NotFinished();

        (,, uint48 epoch, , uint256 proposalId) = votePlatform.proposals(_proposalId);
        uint256 yesVotes = votePlatform.getYes(_proposalId);
        uint256 totalVotes = yesVotes + votePlatform.getNo(_proposalId);

        uint256 totalSupply = IvlCVX(votePlatform.vlCVX()).totalSupplyAtEpoch(epoch);
        if (totalSupply == 0) revert ZeroSupply();

        if (quorumBps > 0 && totalVotes * WEIGHT_BPS / totalSupply < quorumBps) revert QuorumNotMet();

        uint256 yay = totalVotes > 0 ? yesVotes * WEIGHT_BPS / totalVotes : 0;
        uint256 nay = WEIGHT_BPS - yay;

        executed[_proposalId] = true;

        bytes memory voterCall = abi.encodeWithSelector(
            IResupplyVoter.voteForProposal.selector,
            RESUPPLY_STAKER,
            proposalId,
            yay,
            nay
        );

        IResupplyStaker(RESUPPLY_STAKER).safeExecute(RESUPPLY_VOTER, voterCall);
        emit DaoVoteExecuted(_proposalId, yay, nay);
    }

    /// @notice Checks if a proposal has been executed
    /// @param _proposalId Proposal identifier
    /// @return True if proposal was executed
    function isDone(uint256 _proposalId) external view returns (bool) {
        return executed[_proposalId];
    }

    /// @notice Sets a guardian address
    /// @param _guardian Guardian address
    /// @param _active True to add, false to remove
    function setGuardian(address _guardian, bool _active) external onlyOwner {
        guardians[_guardian] = _active;
        emit GuardianSet(_guardian, _active);
    }

    /// @notice Sets the quorum threshold in basis points
    /// @param _quorumBps Quorum in basis points
    function setQuorum(uint256 _quorumBps) external onlyOwner {
        if (_quorumBps > MAX_QUORUM_BPS) revert InvalidQuorum();
        quorumBps = _quorumBps;
        emit QuorumSet(_quorumBps);
    }

    /// @notice Claims and stakes rewards from the Resupply staker
    /// @return amount Amount claimed and staked
    function claimAndStake() external returns (uint256 amount) {
        amount = IResupplyStaker(RESUPPLY_STAKER).claimAndStake();
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
