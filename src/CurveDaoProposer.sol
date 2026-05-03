// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/IDaoVotePlatform.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

interface ICurveVoting {
    function getVote(uint256 _voteId) external view returns (
        bool open,
        bool executed,
        uint64 startDate,
        uint64 snapshotBlock,
        uint64 supportRequired,
        uint64 minAcceptQuorum,
        uint256 yea,
        uint256 nay,
        uint256 votingPower,
        bytes memory script
    );
}

contract CurveDaoProposer is Ownable2Step {
    address public constant CURVE_OWNERSHIP = 0xE478de485ad2fe566d49342Cbd03E49ed7DB3356;
    address public constant CURVE_PARAMETER = 0xBCfF8B0b9419b9A88c44546519b1e909cF330399;

    uint256 public proposalLength = 3 days;

    IDaoVotePlatform public immutable daoVotePlatform;

    mapping(uint256 => bool) public ownershipProposalsUsed;
    mapping(uint256 => bool) public parameterProposalsUsed;

    event VoteProposed(uint256 curveVoteId, bool isOwnership, uint256 daoProposalId);
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

    function proposeVote(uint256 _voteId, bool _isOwnership) external {
        address curveVoting = _isOwnership ? CURVE_OWNERSHIP : CURVE_PARAMETER;

        if (_isOwnership) {
            require(!ownershipProposalsUsed[_voteId], "Ownership vote already proposed");
            ownershipProposalsUsed[_voteId] = true;
        } else {
            require(!parameterProposalsUsed[_voteId], "Parameter vote already proposed");
            parameterProposalsUsed[_voteId] = true;
        }

        (bool open, , uint64 startDate, , , , , , , ) = ICurveVoting(curveVoting).getVote(_voteId);
        require(open, "Curve vote not open");
        require(block.timestamp <= uint256(startDate) + 3 days, "ProposeVote window expired");

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + proposalLength;

        daoVotePlatform.createProposal(
            startTime,
            endTime,
            _isOwnership ? IDaoVotePlatform.VoteType.Ownership : IDaoVotePlatform.VoteType.Parameter,
            _voteId
        );

        emit VoteProposed(_voteId, _isOwnership, daoVotePlatform.proposalCount() - 1);
    }
}
