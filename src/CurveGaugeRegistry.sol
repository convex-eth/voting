// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interface/ICurveGauge.sol";
import "./interface/IGaugeController.sol";

contract CurveGaugeRegistry {
    address public constant gaugeController = address(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB);

    event SetGauge(address _gauge, bool _active);

    mapping(address => uint256) public activeGaugeIndex;
    address[] public activeGauges;

    function gaugeLength() external view returns (uint256) {
        return activeGauges.length;
    }

    function isValidGauge(address _gauge) public view returns (bool) {
        if (IGaugeController(gaugeController).get_gauge_weight(_gauge) == 0) return false;

        // Some legacy Curve gauges with active controller weight do not expose `is_killed()`.
        // Treat a missing kill switch as not killed; newer gauges that expose it must return false.
        (bool success, bytes memory data) = _gauge.staticcall(abi.encodeWithSelector(ICurveGauge.is_killed.selector));
        if (!success || data.length < 32) return true;

        return !abi.decode(data, (bool));
    }

    function isRegisteredGauge(address _gauge) external view returns (bool) {
        return activeGaugeIndex[_gauge] > 0;
    }

    function setGauge(address _gauge) external {
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
