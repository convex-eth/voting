// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IGaugeRegistry {
    function gaugeLength() external view returns (uint256);
    function isValidGauge(address _gauge) external view returns (bool);
    function isRegisteredGauge(address _gauge) external view returns (bool);
    function setGauge(address _gauge) external;
}
