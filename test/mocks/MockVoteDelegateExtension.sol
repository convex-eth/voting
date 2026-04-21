// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../src/interface/IVoteDelegateExtension.sol";

contract MockVoteDelegateExtension is IVoteDelegateExtension {
    address[] public lastGauges;
    uint256[] public lastWeights;
    uint256 public callCount;

    function GaugeVote(address[] calldata _gauge, uint256[] calldata _weight) external override {
        delete lastGauges;
        delete lastWeights;
        for (uint256 i = 0; i < _gauge.length; i++) {
            lastGauges.push(_gauge[i]);
            lastWeights.push(_weight[i]);
        }
        callCount++;
    }

    function getLastCall() external view returns (address[] memory, uint256[] memory) {
        return (lastGauges, lastWeights);
    }
}
