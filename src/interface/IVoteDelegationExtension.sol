// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IVoteDelegationExtension {
    function DaoVoteWithWeights(uint256 _voteId, uint256 _yay, uint256 _nay, bool _isOwnership) external returns (bool);
    function GaugeVote(address[] calldata _gauge, uint256[] calldata _weight) external;
}
