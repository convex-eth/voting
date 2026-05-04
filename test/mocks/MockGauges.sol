// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../src/interface/ICurveGauge.sol";
import "../../src/interface/IGaugeController.sol";

contract MockGaugeController is IGaugeController {
    mapping(address => uint256) public gaugeWeights;

    function setGaugeWeight(address _gauge, uint256 _weight) external {
        gaugeWeights[_gauge] = _weight;
    }

    function get_gauge_weight(address _gauge) external view override returns (uint256) {
        return gaugeWeights[_gauge];
    }

    function vote_user_slopes(address, address) external pure override returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }

    function vote_for_gauge_weights(address, uint256) external pure override {}

    function add_gauge(address, int128, uint256) external pure override {}
}

contract MockCurveGauge is ICurveGauge {
    bool public killed;

    function setKilled(bool _killed) external {
        killed = _killed;
    }

    function is_killed() external view override returns (bool) {
        return killed;
    }
}

contract MockLegacyCurveGauge {}
