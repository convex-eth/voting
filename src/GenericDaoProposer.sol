// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/IDaoVotePlatform.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract GenericDaoProposer is Ownable2Step {
    IDaoVotePlatform public immutable daoVotePlatform;

    uint256 public proposalLength = 3 days;

    mapping(address => bool) public operators;

    event OperatorSet(address indexed operator, bool active);
    event ProposalLengthSet(uint256 newLength);
    event ProposalCreated(uint256 proposalId, address indexed proposer, uint256 voteId, uint8 voteType);

    constructor(address _owner, address _daoVotePlatform) Ownable(_owner) {
        daoVotePlatform = IDaoVotePlatform(_daoVotePlatform);
    }

    function setOperator(address _operator, bool _active) external onlyOwner {
        operators[_operator] = _active;
        emit OperatorSet(_operator, _active);
    }

    function setProposalLength(uint256 _proposalLength) external onlyOwner {
        require(_proposalLength >= daoVotePlatform.MIN_PROPOSAL_DURATION(), "Below minimum");
        require(_proposalLength <= daoVotePlatform.MAX_PROPOSAL_DURATION(), "Above maximum");
        proposalLength = _proposalLength;
        emit ProposalLengthSet(_proposalLength);
    }

    function propose(uint256 _voteId, uint8 _voteType) external {
        require(operators[msg.sender], "Not operator");

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + proposalLength;

        uint256 proposalId = daoVotePlatform.proposalCount();

        daoVotePlatform.createProposal(
            startTime,
            endTime,
            IDaoVotePlatform.VoteType(_voteType),
            _voteId
        );

        emit ProposalCreated(proposalId, msg.sender, _voteId, _voteType);
    }
}
