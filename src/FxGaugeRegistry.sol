// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import "./interface/IFxGauge.sol";
import "./interface/IFxGaugeController.sol";

contract FxGaugeRegistry is Ownable2Step {

    uint256 public constant LIQUIDITY_POOL = 0;
    uint256 public constant REBALANCE_POOL = 1;

    address public constant gaugeController = address(0xe60eB8098B34eD775ac44B1ddE864e098C6d7f37);
    event SetGauge(address _gauge, bool _active);

    mapping(address => uint256) public activeGaugeIndex;
    address[] public activeGauges;

    constructor(address _owner) Ownable(_owner) {}

    function gaugeLength() external view returns (uint256) {
        return activeGauges.length;
    }

    function isValidGauge(address _gauge) public view returns (bool) {
        uint256 gaugeType = IFxGaugeController(gaugeController).gauge_types(_gauge);
        return ((gaugeType == LIQUIDITY_POOL || gaugeType == REBALANCE_POOL) && IFxGauge(_gauge).isActive());
    }

    function isRegisteredGauge(address _gauge) external view returns (bool) {
        return activeGaugeIndex[_gauge] > 0;
    }

    function setGauge(address _gauge) external onlyOwner {
        bool isActive = isValidGauge(_gauge);
        uint256 index = activeGaugeIndex[_gauge];

        if (index > 0) {
            if (!isActive) {
                uint256 lastIdx = activeGauges.length - 1;
                address swapped = activeGauges[lastIdx];
                activeGauges[index - 1] = swapped;
                activeGaugeIndex[swapped] = index;
                activeGauges.pop();
                activeGaugeIndex[_gauge] = 0;
            }
        } else if (isActive) {
            activeGauges.push(_gauge);
            activeGaugeIndex[_gauge] = activeGauges.length;
        }

        emit SetGauge(_gauge, isActive);
    }
}
