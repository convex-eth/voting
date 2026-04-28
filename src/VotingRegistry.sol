// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract VotingRegistry is Ownable2Step {
    uint8 public constant VOTE_DAO = 0;
    uint8 public constant VOTE_GAUGE = 1;
    uint8 public constant GAUGE_REGISTRY = 2;
    uint8 public constant OTHER_TYPE = 3;

    event VotingContractSet(string indexed platform, uint8 indexed voteType, address indexed votingContract);

    mapping(string => mapping(uint8 => address)) public getVotingContract;

    constructor(address _owner) Ownable(_owner) {}

    function setVotingContract(string calldata _platform, uint8 _voteType, address _votingContract) external onlyOwner {
        getVotingContract[_platform][_voteType] = _votingContract;
        emit VotingContractSet(_platform, _voteType, _votingContract);
    }
}
