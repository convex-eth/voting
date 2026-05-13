// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";
import {CurveGaugeRegistry} from "../../src/CurveGaugeRegistry.sol";

contract CurveGaugeRegistryForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function testFork_liveValidCurveGaugeRegisters() public {
        address gauge = liveCurveGauge();
        CurveGaugeRegistry registry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), new address[](0));

        assertTrue(registry.isValidGauge(gauge));
        registry.setGauge(gauge);

        assertTrue(registry.isRegisteredGauge(gauge));
        assertEq(registry.gaugeLength(), 1);
        assertEq(registry.activeGauges(0), gauge);
    }

    function testFork_zeroWeightCurveGaugeIsRejected() public {
        address gauge = invalidCurveGauge();
        CurveGaugeRegistry registry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), new address[](0));

        registry.setGauge(gauge);

        assertFalse(registry.isRegisteredGauge(gauge));
        assertEq(registry.gaugeLength(), 0);
    }

    function testFork_killedCurveGaugeIsRejectedWhenLiveCandidateExists() public {
        (address gauge, bool found) = killedCurveGauge();
        if (!found) vm.skip(true);

        CurveGaugeRegistry registry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), new address[](0));
        registry.setGauge(gauge);

        assertFalse(registry.isRegisteredGauge(gauge));
        assertEq(registry.gaugeLength(), 0);
    }

    function testFork_batchReconcilesMixedCurveCandidates() public {
        address validGauge = liveCurveGauge();
        address invalidGauge = invalidCurveGauge();
        CurveGaugeRegistry registry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), new address[](0));

        registry.setGauges(arr(validGauge, invalidGauge));

        assertTrue(registry.isRegisteredGauge(validGauge));
        assertFalse(registry.isRegisteredGauge(invalidGauge));
        assertEq(registry.gaugeLength(), 1);
    }

    function testFork_batchRemovesCurveGaugeThatBecomesInvalid() public {
        address validGauge = liveCurveGauge();
        address invalidGauge = invalidCurveGauge();
        address[] memory initial = arr(validGauge, invalidGauge);
        CurveGaugeRegistry registry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), initial);

        assertEq(registry.gaugeLength(), 2);
        registry.setGauges(initial);

        assertTrue(registry.isRegisteredGauge(validGauge));
        assertFalse(registry.isRegisteredGauge(invalidGauge));
        assertEq(registry.gaugeLength(), 1);
    }
}
