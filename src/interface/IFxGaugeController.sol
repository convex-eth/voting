// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IFxGaugeController {
    function gauges(uint256 _gaugeId) external view returns (address);
    function n_gauges() external view returns (uint256);
    function gauge_types(address _gauge) external view returns (uint256);
}
