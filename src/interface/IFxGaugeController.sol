// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IFxGaugeController {
    function gauge_types(address _gauge) external view returns (uint256);
}
