// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/IDaoVotePlatform.sol";
import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract GenericDaoProposer is Ownable2Step {
    string public name;
    IDaoVotePlatform public immutable daoVotePlatform;

    uint256 public proposalLength = 3 days;

    mapping(address => bool) public operators;

    event OperatorSet(address indexed operator, bool active);
    event ProposalLengthSet(uint256 newLength);
    event ProposalCreated(uint256 proposalId, address indexed proposer, uint256 voteId, uint8 voteType);

    /// @notice Creates a new GenericDaoProposer contract
    /// @param _name Contract name identifier
    /// @param _owner Address of the contract owner
    /// @param _daoVotePlatform Address of the DaoVotePlatform contract
    constructor(string memory _name, address _owner, address _daoVotePlatform) Ownable(_owner) {
        name = _name;
        daoVotePlatform = IDaoVotePlatform(_daoVotePlatform);
    }

    /// @notice Sets an operator address
    /// @param _operator Operator address
    /// @param _active True to add, false to remove
    function setOperator(address _operator, bool _active) external onlyOwner {
        operators[_operator] = _active;
        emit OperatorSet(_operator, _active);
    }

    /// @notice Sets the proposal voting duration
    /// @param _proposalLength New proposal length in seconds
    function setProposalLength(uint256 _proposalLength) external onlyOwner {
        require(_proposalLength >= daoVotePlatform.MIN_PROPOSAL_DURATION(), "Below minimum");
        require(_proposalLength <= daoVotePlatform.MAX_PROPOSAL_DURATION(), "Above maximum");
        proposalLength = _proposalLength;
        emit ProposalLengthSet(_proposalLength);
    }

    /// @notice Creates a new generic DAO proposal
    /// @param _voteId External vote identifier
    /// @param _voteType Vote type (Ownership or Parameter)
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
