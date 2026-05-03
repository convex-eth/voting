// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/IDaoVotePlatform.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

interface IResupplyVoting {
    function getProposalData(uint256 id) external view returns (
        string memory description,
        uint256 epoch,
        uint256 createdAt,
        uint256 quorumWeight,
        uint256 weightYes,
        uint256 weightNo,
        bool processed,
        bool executable,
        bytes memory payload
    );
}

contract ResupplyDaoProposer is Ownable2Step {
    address public constant RESUPPLY_VOTING = 0x11111111063874cE8dC6232cb5C1C849359476E6;

    uint256 public proposalLength = 3 days;

    IDaoVotePlatform public immutable daoVotePlatform;

    mapping(uint256 => bool) public proposalsUsed;

    event VoteProposed(uint256 resupplyVoteId, uint256 daoProposalId);
    event ProposalLengthSet(uint256 newProposalLength);

    constructor(address _owner, address _daoVotePlatform) Ownable(_owner) {
        daoVotePlatform = IDaoVotePlatform(_daoVotePlatform);
    }

    function setProposalLength(uint256 _proposalLength) external onlyOwner {
        require(_proposalLength >= daoVotePlatform.MIN_PROPOSAL_DURATION(), "Below minimum");
        require(_proposalLength <= daoVotePlatform.MAX_PROPOSAL_DURATION(), "Above maximum");
        proposalLength = _proposalLength;
        emit ProposalLengthSet(_proposalLength);
    }

    function proposeVote(uint256 _voteId) external {
        require(!proposalsUsed[_voteId], "Vote already proposed");
        proposalsUsed[_voteId] = true;

        (, , uint256 createdAt, , , , bool processed, , ) = IResupplyVoting(RESUPPLY_VOTING).getProposalData(_voteId);
        require(!processed, "Resupply vote already processed");
        require(block.timestamp <= createdAt + 3 days, "ProposeVote window expired");

        uint256 startTime = createdAt;
        uint256 endTime = startTime + proposalLength;

        daoVotePlatform.createProposal(
            startTime,
            endTime,
            IDaoVotePlatform.VoteType.Ownership,
            _voteId
        );

        emit VoteProposed(_voteId, daoVotePlatform.proposalCount() - 1);
    }
}
