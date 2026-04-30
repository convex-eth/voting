// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IFxGauge {
    function isActive() external view returns (bool);
}
