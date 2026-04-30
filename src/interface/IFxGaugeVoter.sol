// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IFxGaugeVoter {
    function voteGaugeWeight(address _controller, address[] calldata _gauge, uint256[] calldata _weight) external;
}
