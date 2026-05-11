// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";

contract GaugeListForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function testFork_curveGaugeListContainsAtLeastOneCurrentlyValidGauge() public {
        address[] memory gauges = curveGaugeCandidates();

        for (uint256 i; i < gauges.length; i++) {
            if (_isLiveValidCurveGauge(gauges[i])) return;
        }

        fail("no currently valid Curve gauge");
    }

    function testFork_curveGaugeListHasNoDuplicates() public {
        address[] memory gauges = curveGaugeCandidates();

        for (uint256 i; i < gauges.length; i++) {
            for (uint256 j = i + 1; j < gauges.length; j++) {
                assertNotEq(gauges[i], gauges[j], "duplicate gauge");
            }
        }
    }
}
