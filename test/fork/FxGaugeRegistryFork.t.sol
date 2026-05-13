// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";
import {FxGaugeRegistry} from "../../src/FxGaugeRegistry.sol";

contract FxGaugeRegistryForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function testFork_liveLiquidityGaugeRegisters() public {
        address gauge = liveFxGaugeOfType(0);
        FxGaugeRegistry registry = new FxGaugeRegistry("Fx Gauge Registry", address(this), new address[](0));

        assertTrue(registry.isValidGauge(gauge));
        registry.setGauge(gauge);

        assertTrue(registry.isRegisteredGauge(gauge));
        assertEq(registry.gaugeLength(), 1);
        assertEq(registry.activeGauges(0), gauge);
    }

    function testFork_liveRebalanceGaugeRegisters() public {
        address gauge = liveFxGaugeOfType(1);
        FxGaugeRegistry registry = new FxGaugeRegistry("Fx Gauge Registry", address(this), new address[](0));

        assertTrue(registry.isValidGauge(gauge));
        registry.setGauge(gauge);

        assertTrue(registry.isRegisteredGauge(gauge));
        assertEq(registry.gaugeLength(), 1);
    }

    function testFork_invalidFxGaugeIsRejectedWhenLiveCandidateExists() public {
        (address gauge, bool found) = invalidFxGauge();
        if (!found) vm.skip(true);

        FxGaugeRegistry registry = new FxGaugeRegistry("Fx Gauge Registry", address(this), new address[](0));
        registry.setGauge(gauge);

        assertFalse(registry.isRegisteredGauge(gauge));
        assertEq(registry.gaugeLength(), 0);
    }

    function testFork_batchReconcilesMixedFxCandidates() public {
        (address validA, address validB) = twoLiveFxGauges();
        FxGaugeRegistry registry = new FxGaugeRegistry("Fx Gauge Registry", address(this), new address[](0));

        registry.setGauges(arr(validA, validB));

        assertTrue(registry.isRegisteredGauge(validA));
        assertTrue(registry.isRegisteredGauge(validB));
        assertEq(registry.gaugeLength(), 2);
    }

    function testFork_forceRemovedFxGaugeCannotBeReaddedByPermissionlessSync() public {
        address gauge = liveFxGaugeOfType(0);
        FxGaugeRegistry registry = new FxGaugeRegistry("Fx Gauge Registry", address(this), new address[](0));

        registry.setGauge(gauge);
        registry.forceRemove(gauge);
        registry.setGauge(gauge);

        assertFalse(registry.isRegisteredGauge(gauge));
        assertEq(registry.gaugeLength(), 0);
        assertTrue(registry.forceRemoved(gauge));
    }
}
