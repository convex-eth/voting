// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IVoteDelegateExtension {
    function GaugeVote(address[] calldata _gauge, uint256[] calldata _weight) external;
}
