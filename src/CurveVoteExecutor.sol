// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./DaoVotePlatform.sol";
import "./interface/IvlCVX.sol";
import "./interface/IVoteDelegationExtension.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract CurveVoteExecutor is Ownable2Step {

    error NotFinished();
    error AlreadyExecuted();
    error QuorumNotMet();
    error ZeroSupply();

    uint256 public constant WEIGHT_BPS = 10000;

    DaoVotePlatform public immutable votePlatform;
    IVoteDelegationExtension public immutable voteDelegate;

    uint256 public quorumBps;
    mapping(address => bool) public guardians;
    mapping(uint256 => bool) public executed;

    event DaoVoteExecuted(uint256 indexed proposalId, uint256 yay, uint256 nay, bool isOwnership);
    event GuardianSet(address indexed guardian, bool active);
    event QuorumSet(uint256 quorumBps);

    constructor(address _owner, address _votePlatform, address _voteDelegate, uint256 _quorumBps) Ownable(_owner) {
        votePlatform = DaoVotePlatform(_votePlatform);
        voteDelegate = IVoteDelegationExtension(_voteDelegate);
        quorumBps = _quorumBps;
    }

    function executeDaoVote(uint256 _proposalId) external {
        if (executed[_proposalId]) revert AlreadyExecuted();
        if (!votePlatform.isFinished(_proposalId)) revert NotFinished();
        if (!votePlatform.isFinalized(_proposalId) && !guardians[msg.sender]) revert NotFinished();

        (,, uint48 epoch, uint8 voteType, uint256 proposalId) = votePlatform.proposals(_proposalId);
        uint256 yesVotes = votePlatform.getYes(_proposalId);
        uint256 totalVotes = yesVotes + votePlatform.getNo(_proposalId);

        uint256 totalSupply = IvlCVX(votePlatform.vlCVX()).totalSupplyAtEpoch(epoch);
        if (totalSupply == 0) revert ZeroSupply();

        if (quorumBps > 0 && totalVotes * WEIGHT_BPS / totalSupply < quorumBps) revert QuorumNotMet();

        uint256 yay = totalVotes > 0 ? yesVotes * WEIGHT_BPS / totalVotes : 0;
        uint256 nay = WEIGHT_BPS - yay;
        bool isOwnership = voteType == uint8(DaoVotePlatform.VoteType.Ownership);

        executed[_proposalId] = true;

        voteDelegate.DaoVoteWithWeights(proposalId, yay, nay, isOwnership);
        emit DaoVoteExecuted(_proposalId, yay, nay, isOwnership);
    }

    function isDone(uint256 _proposalId) external view returns (bool) {
        return executed[_proposalId];
    }

    function setGuardian(address _guardian, bool _active) external onlyOwner {
        guardians[_guardian] = _active;
        emit GuardianSet(_guardian, _active);
    }

    function setQuorum(uint256 _quorumBps) external onlyOwner {
        quorumBps = _quorumBps;
        emit QuorumSet(_quorumBps);
    }
}
