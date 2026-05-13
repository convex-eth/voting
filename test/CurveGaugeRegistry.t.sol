// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/CurveGaugeRegistry.sol";
import "./mocks/MockGauges.sol";

contract CurveGaugeRegistryTest is Test {
    CurveGaugeRegistry internal registry;
    MockGaugeController internal controller;
    MockCurveGauge internal gauge1;
    MockCurveGauge internal gauge2;
    MockCurveGauge internal gauge3;
    MockCurveGauge internal gauge4;
    MockCurveGauge internal gauge5;
    MockLegacyCurveGauge internal legacyGauge;

    address constant GAUGE_CONTROLLER = address(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB);

    function setUp() public {
        controller = new MockGaugeController();
        vm.etch(GAUGE_CONTROLLER, address(controller).code);

        gauge1 = new MockCurveGauge();
        gauge2 = new MockCurveGauge();
        gauge3 = new MockCurveGauge();
        gauge4 = new MockCurveGauge();
        gauge5 = new MockCurveGauge();
        legacyGauge = new MockLegacyCurveGauge();

        address[] memory initial = new address[](0);
        registry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), initial);

        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge1), 1000);
        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge2), 2000);
        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge3), 3000);
        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge4), 0);
        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge5), 500);
        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(legacyGauge), 1000);
    }

    function test_initialGaugesRegisteredWithoutValidation() public {
        address[] memory initial = new address[](3);
        initial[0] = address(gauge1);
        initial[1] = address(gauge2);
        initial[2] = address(gauge5);

        CurveGaugeRegistry reg = new CurveGaugeRegistry("Curve Gauge Registry", address(this), initial);

        assertEq(reg.gaugeLength(), 3);
        assertTrue(reg.isRegisteredGauge(address(gauge1)));
        assertTrue(reg.isRegisteredGauge(address(gauge2)));
        assertTrue(reg.isRegisteredGauge(address(gauge5)));
        assertFalse(reg.isRegisteredGauge(address(gauge3)));
    }

    function test_forceRemove() public {
        registry.setGauge(address(gauge1));
        assertEq(registry.gaugeLength(), 1);

        registry.forceRemove(address(gauge1));

        assertEq(registry.gaugeLength(), 0);
        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertTrue(registry.forceRemoved(address(gauge1)));
    }

    function test_forceRemoveNotActive() public {
        assertFalse(registry.isRegisteredGauge(address(gauge1)));

        registry.forceRemove(address(gauge1));

        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertTrue(registry.forceRemoved(address(gauge1)));
    }

    function test_reinstateForceRemoved() public {
        registry.setGauge(address(gauge1));
        registry.forceRemove(address(gauge1));
        assertTrue(registry.forceRemoved(address(gauge1)));

        registry.reinstate(address(gauge1));

        assertFalse(registry.forceRemoved(address(gauge1)));
        assertFalse(registry.isRegisteredGauge(address(gauge1)));
    }

    function test_setGaugeCannotReAddForceRemoved() public {
        registry.setGauge(address(gauge1));
        registry.forceRemove(address(gauge1));

        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge1), 1000);
        registry.setGauge(address(gauge1));

        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 0);
    }

    function test_addValidGauge() public {
        registry.setGauge(address(gauge1));

        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 1);
        assertEq(registry.activeGauges(0), address(gauge1));
    }

    function test_addMultipleValidGauges() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));
        registry.setGauge(address(gauge3));

        assertEq(registry.gaugeLength(), 3);
        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertTrue(registry.isRegisteredGauge(address(gauge2)));
        assertTrue(registry.isRegisteredGauge(address(gauge3)));
    }

    function test_cannotAddZeroWeightGauge() public {
        registry.setGauge(address(gauge4));

        assertFalse(registry.isRegisteredGauge(address(gauge4)));
        assertEq(registry.gaugeLength(), 0);
    }

    function test_cannotAddKilledGauge() public {
        gauge1.setKilled(true);

        registry.setGauge(address(gauge1));

        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 0);
    }

    function test_removeKilledGauge() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));
        registry.setGauge(address(gauge3));

        assertEq(registry.gaugeLength(), 3);

        gauge2.setKilled(true);

        registry.setGauge(address(gauge2));

        assertFalse(registry.isRegisteredGauge(address(gauge2)));
        assertEq(registry.gaugeLength(), 2);
    }

    function test_removeZeroWeightGauge() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));

        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge1), 0);

        registry.setGauge(address(gauge1));

        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 1);
        assertTrue(registry.isRegisteredGauge(address(gauge2)));
    }

    function test_swapAndPopMaintainsIndices() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));
        registry.setGauge(address(gauge3));

        gauge2.setKilled(true);

        registry.setGauge(address(gauge2));

        assertFalse(registry.isRegisteredGauge(address(gauge2)));
        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertTrue(registry.isRegisteredGauge(address(gauge3)));
        assertEq(registry.gaugeLength(), 2);

        assertEq(registry.activeGauges(0), address(gauge1));
        assertEq(registry.activeGauges(1), address(gauge3));

        assertEq(registry.activeGaugeIndex(address(gauge1)), 1);
        assertEq(registry.activeGaugeIndex(address(gauge3)), 2);
    }

    function test_removeLastGauge() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));

        gauge2.setKilled(true);

        registry.setGauge(address(gauge2));

        assertFalse(registry.isRegisteredGauge(address(gauge2)));
        assertEq(registry.gaugeLength(), 1);
        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.activeGauges(0), address(gauge1));
        assertEq(registry.activeGaugeIndex(address(gauge1)), 1);
    }

    function test_addBackAfterRemoval() public {
        registry.setGauge(address(gauge1));

        gauge1.setKilled(true);
        registry.setGauge(address(gauge1));
        assertFalse(registry.isRegisteredGauge(address(gauge1)));

        gauge1.setKilled(false);
        registry.setGauge(address(gauge1));
        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 1);
    }

    function test_isValidGauge() public view {
        assertTrue(registry.isValidGauge(address(gauge1)));
        assertFalse(registry.isValidGauge(address(gauge4)));
    }

    function test_isValidGaugeKilled() public {
        gauge1.setKilled(true);
        assertFalse(registry.isValidGauge(address(gauge1)));
    }

    function test_legacyCurveGaugeWithoutKillSwitchCanBeSeededInConstructor() public {
        address[] memory initial = new address[](1);
        initial[0] = address(legacyGauge);

        CurveGaugeRegistry reg = new CurveGaugeRegistry("Curve Gauge Registry", address(this), initial);

        assertTrue(reg.isRegisteredGauge(address(legacyGauge)));
        assertEq(reg.gaugeLength(), 1);
        assertEq(reg.activeGauges(0), address(legacyGauge));
    }

    function test_setGaugeEmitsAddEvent() public {
        vm.expectEmit(true, true, false, false);
        emit CurveGaugeRegistry.SetGauge(address(gauge1), true);
        registry.setGauge(address(gauge1));
    }

    function test_setGaugeEmitsRemovalEvent() public {
        registry.setGauge(address(gauge1));

        gauge1.setKilled(true);

        vm.expectEmit(true, true, false, false);
        emit CurveGaugeRegistry.SetGauge(address(gauge1), false);
        registry.setGauge(address(gauge1));
    }

    function test_removeMiddleElementSwapAndPop() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));
        registry.setGauge(address(gauge3));
        registry.setGauge(address(gauge5));

        assertEq(registry.gaugeLength(), 4);

        gauge2.setKilled(true);
        registry.setGauge(address(gauge2));

        assertEq(registry.gaugeLength(), 3);
        assertFalse(registry.isRegisteredGauge(address(gauge2)));

        assertEq(registry.activeGaugeIndex(address(gauge1)), 1);
        assertEq(registry.activeGaugeIndex(address(gauge5)), 2);
        assertEq(registry.activeGaugeIndex(address(gauge3)), 3);
    }

    function test_sequentialRemovals() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));
        registry.setGauge(address(gauge3));

        gauge2.setKilled(true);
        registry.setGauge(address(gauge2));

        assertEq(registry.gaugeLength(), 2);

        gauge1.setKilled(true);
        registry.setGauge(address(gauge1));

        assertEq(registry.gaugeLength(), 1);
        assertTrue(registry.isRegisteredGauge(address(gauge3)));
        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertFalse(registry.isRegisteredGauge(address(gauge2)));
    }

    function test_setGaugeNoopWhenAlreadyActive() public {
        registry.setGauge(address(gauge1));
        assertEq(registry.gaugeLength(), 1);

        registry.setGauge(address(gauge1));
        assertEq(registry.gaugeLength(), 1);
    }

    function test_setGaugeNoopWhenInvalid() public {
        registry.setGauge(address(gauge4));
        assertEq(registry.gaugeLength(), 0);

        registry.setGauge(address(gauge4));
        assertEq(registry.gaugeLength(), 0);
    }

    function test_weightGoesToZero() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));

        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge1), 0);

        registry.setGauge(address(gauge1));

        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 1);
        assertTrue(registry.isRegisteredGauge(address(gauge2)));
    }

    function test_allGaugesRemoved() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));
        registry.setGauge(address(gauge5));

        gauge1.setKilled(true);
        gauge2.setKilled(true);
        gauge5.setKilled(true);

        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));
        registry.setGauge(address(gauge5));

        assertEq(registry.gaugeLength(), 0);
    }

    function test_isRegisteredGaugeUnregistered() public view {
        assertFalse(registry.isRegisteredGauge(address(gauge1)));
    }

    function test_removeSingleElement() public {
        registry.setGauge(address(gauge1));
        assertEq(registry.gaugeLength(), 1);

        gauge1.setKilled(true);
        registry.setGauge(address(gauge1));

        assertEq(registry.gaugeLength(), 0);
        assertFalse(registry.isRegisteredGauge(address(gauge1)));
    }

    function test_inactiveGaugeReAdding() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));

        gauge1.setKilled(true);
        registry.setGauge(address(gauge1));

        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 1);

        gauge1.setKilled(false);
        registry.setGauge(address(gauge1));

        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 2);
    }

    function test_removeFirstOfThree() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));
        registry.setGauge(address(gauge3));

        gauge1.setKilled(true);
        registry.setGauge(address(gauge1));

        assertEq(registry.gaugeLength(), 2);
        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertTrue(registry.isRegisteredGauge(address(gauge2)));
        assertTrue(registry.isRegisteredGauge(address(gauge3)));

        assertEq(registry.activeGaugeIndex(address(gauge3)), 1);
        assertEq(registry.activeGaugeIndex(address(gauge2)), 2);
    }

    function test_gaugeControllerAddress() public view {
        assertEq(registry.gaugeController(), GAUGE_CONTROLLER);
    }
}
