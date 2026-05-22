// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract VotingRegistry is Ownable2Step {
    uint8 public constant VOTE_DAO = 0;
    uint8 public constant VOTE_GAUGE = 1;
    uint8 public constant GAUGE_REGISTRY = 2;
    uint8 public constant DAO_EXECUTOR = 3;
    uint8 public constant GAUGE_EXECUTOR = 4;
    uint8 public constant DAO_PROPOSER = 5;
    uint8 public constant GAUGE_PROPOSER = 6;
    uint8 public constant OTHER_TYPE = 7;

    event VotingContractSet(string indexed platform, uint8 indexed voteType, address indexed votingContract);

    mapping(string => mapping(uint8 => address)) public getAddress;

    /// @notice Creates a new VotingRegistry contract
    /// @param _owner Address of the contract owner
    constructor(address _owner) Ownable(_owner) {}

    /// @notice Registers or updates a voting contract address
    /// @param _platform Platform name
    /// @param _voteType Vote type identifier
    /// @param _votingContract Address of the voting contract
    function setVotingContract(string calldata _platform, uint8 _voteType, address _votingContract) external onlyOwner {
        getAddress[_platform][_voteType] = _votingContract;
        emit VotingContractSet(_platform, _voteType, _votingContract);
    }
}
