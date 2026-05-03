// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IDaoVotePlatform {
    enum VoteType {
        Ownership,
        Parameter
    }

    function MIN_PROPOSAL_DURATION() external view returns (uint256);
    function MAX_PROPOSAL_DURATION() external view returns (uint256);
    function proposalCount() external view returns (uint256);
    function createProposal(uint256 _startTime, uint256 _endTime, VoteType _voteType, uint256 _proposalId) external;
    function setOperator(address _op, bool _active) external;
}
