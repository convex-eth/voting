// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract ProposalMetadata is Ownable2Step {
    struct Metadata {
        string description;
        string referenceUrl;
    }

    string public name;

    mapping(address => bool) public operators;
    mapping(uint256 => Metadata) public metadata;

    event OperatorSet(address indexed operator, bool active);
    event MetadataSet(uint256 indexed proposalId, string description, string referenceUrl);

    /// @notice Creates a new ProposalMetadata contract
    /// @param _name Contract name identifier
    /// @param _owner Address of the contract owner
    constructor(string memory _name, address _owner) Ownable(_owner) {
        name = _name;
    }

    /// @notice Sets an operator address
    /// @param _operator Operator address
    /// @param _active True to add, false to remove
    function setOperator(address _operator, bool _active) external onlyOwner {
        operators[_operator] = _active;
        emit OperatorSet(_operator, _active);
    }

    /// @notice Sets display metadata for a proposal
    /// @param _proposalId Internal proposal identifier
    /// @param _description Off-chain proposal description
    /// @param _referenceUrl Off-chain proposal reference URL
    function setMetadata(uint256 _proposalId, string calldata _description, string calldata _referenceUrl) external {
        require(operators[msg.sender], "Not operator");

        metadata[_proposalId] = Metadata({description: _description, referenceUrl: _referenceUrl});

        emit MetadataSet(_proposalId, _description, _referenceUrl);
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
