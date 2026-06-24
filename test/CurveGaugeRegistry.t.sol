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

    uint256 internal constant GAUGE1_ID = 0;
    uint256 internal constant GAUGE2_ID = 1;
    uint256 internal constant GAUGE3_ID = 2;
    uint256 internal constant GAUGE4_ID = 3;
    uint256 internal constant GAUGE5_ID = 4;
    uint256 internal constant LEGACY_GAUGE_ID = 5;

    function setUp() public {
        controller = new MockGaugeController();
        vm.etch(GAUGE_CONTROLLER, address(controller).code);

        gauge1 = new MockCurveGauge();
        gauge2 = new MockCurveGauge();
        gauge3 = new MockCurveGauge();
        gauge4 = new MockCurveGauge();
        gauge5 = new MockCurveGauge();
        legacyGauge = new MockLegacyCurveGauge();

        MockGaugeController(GAUGE_CONTROLLER).setGauge(GAUGE1_ID, address(gauge1));
        MockGaugeController(GAUGE_CONTROLLER).setGauge(GAUGE2_ID, address(gauge2));
        MockGaugeController(GAUGE_CONTROLLER).setGauge(GAUGE3_ID, address(gauge3));
        MockGaugeController(GAUGE_CONTROLLER).setGauge(GAUGE4_ID, address(gauge4));
        MockGaugeController(GAUGE_CONTROLLER).setGauge(GAUGE5_ID, address(gauge5));
        MockGaugeController(GAUGE_CONTROLLER).setGauge(LEGACY_GAUGE_ID, address(legacyGauge));

        uint256[] memory initial = new uint256[](0);
        registry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), initial);

        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge1), 1000);
        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge2), 2000);
        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge3), 3000);
        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge4), 0);
        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge5), 500);
        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(legacyGauge), 1000);
    }

    function test_initialGaugesRegisteredWithoutValidation() public {
        uint256[] memory initial = new uint256[](3);
        initial[0] = GAUGE1_ID;
        initial[1] = GAUGE2_ID;
        initial[2] = GAUGE5_ID;

        CurveGaugeRegistry reg = new CurveGaugeRegistry("Curve Gauge Registry", address(this), initial);

        assertEq(reg.gaugeLength(), 3);
        assertTrue(reg.isRegisteredGauge(address(gauge1)));
        assertTrue(reg.isRegisteredGauge(address(gauge2)));
        assertTrue(reg.isRegisteredGauge(address(gauge5)));
        assertFalse(reg.isRegisteredGauge(address(gauge3)));
    }

    function test_forceRemove() public {
        registry.setGauge(GAUGE1_ID);
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
        registry.setGauge(GAUGE1_ID);
        registry.forceRemove(address(gauge1));
        assertTrue(registry.forceRemoved(address(gauge1)));

        registry.reinstate(address(gauge1));

        assertFalse(registry.forceRemoved(address(gauge1)));
        assertFalse(registry.isRegisteredGauge(address(gauge1)));
    }

    function test_setGaugeCannotReAddForceRemoved() public {
        registry.setGauge(GAUGE1_ID);
        registry.forceRemove(address(gauge1));

        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge1), 1000);
        registry.setGauge(GAUGE1_ID);

        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 0);
    }

    function test_addValidGauge() public {
        registry.setGauge(GAUGE1_ID);

        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 1);
        assertEq(registry.activeGauges(0), address(gauge1));
    }

    function test_addValidGaugeByAddress() public {
        registry.setGauge(address(gauge1));

        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 1);
        assertEq(registry.activeGauges(0), address(gauge1));
    }

    function test_addMultipleValidGauges() public {
        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);
        registry.setGauge(GAUGE3_ID);

        assertEq(registry.gaugeLength(), 3);
        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertTrue(registry.isRegisteredGauge(address(gauge2)));
        assertTrue(registry.isRegisteredGauge(address(gauge3)));
    }

    function test_addsZeroWeightGauge() public {
        registry.setGauge(GAUGE4_ID);

        assertTrue(registry.isRegisteredGauge(address(gauge4)));
        assertEq(registry.gaugeLength(), 1);
    }

    function test_cannotAddKilledGauge() public {
        gauge1.setKilled(true);

        registry.setGauge(GAUGE1_ID);

        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 0);
    }

    function test_removeKilledGauge() public {
        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);
        registry.setGauge(GAUGE3_ID);

        assertEq(registry.gaugeLength(), 3);

        gauge2.setKilled(true);

        registry.setGauge(GAUGE2_ID);

        assertFalse(registry.isRegisteredGauge(address(gauge2)));
        assertEq(registry.gaugeLength(), 2);
    }

    function test_removeKilledGaugeByAddress() public {
        registry.setGauge(address(gauge1));
        registry.setGauge(address(gauge2));

        gauge2.setKilled(true);

        registry.setGauge(address(gauge2));

        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertFalse(registry.isRegisteredGauge(address(gauge2)));
        assertEq(registry.gaugeLength(), 1);
    }

    function test_zeroWeightDoesNotRemoveGauge() public {
        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);

        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge1), 0);

        registry.setGauge(GAUGE1_ID);

        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 2);
        assertTrue(registry.isRegisteredGauge(address(gauge2)));
    }

    function test_swapAndPopMaintainsIndices() public {
        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);
        registry.setGauge(GAUGE3_ID);

        gauge2.setKilled(true);

        registry.setGauge(GAUGE2_ID);

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
        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);

        gauge2.setKilled(true);

        registry.setGauge(GAUGE2_ID);

        assertFalse(registry.isRegisteredGauge(address(gauge2)));
        assertEq(registry.gaugeLength(), 1);
        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.activeGauges(0), address(gauge1));
        assertEq(registry.activeGaugeIndex(address(gauge1)), 1);
    }

    function test_addBackAfterRemoval() public {
        registry.setGauge(GAUGE1_ID);

        gauge1.setKilled(true);
        registry.setGauge(GAUGE1_ID);
        assertFalse(registry.isRegisteredGauge(address(gauge1)));

        gauge1.setKilled(false);
        registry.setGauge(GAUGE1_ID);
        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 1);
    }

    function test_isValidGauge() public view {
        assertTrue(registry.isValidGauge(address(gauge1)));
        assertTrue(registry.isValidGauge(address(gauge4)));
    }

    function test_isValidGaugeKilled() public {
        gauge1.setKilled(true);
        assertFalse(registry.isValidGauge(address(gauge1)));
    }

    function test_isValidGaugeUnregisteredReverts() public {
        MockCurveGauge unregisteredGauge = new MockCurveGauge();

        vm.expectRevert("gauge is not added");
        registry.isValidGauge(address(unregisteredGauge));
    }

    function test_setGaugeByAddressUnregisteredReverts() public {
        MockCurveGauge unregisteredGauge = new MockCurveGauge();

        vm.expectRevert("gauge is not added");
        registry.setGauge(address(unregisteredGauge));
    }

    function test_legacyCurveGaugeWithoutKillSwitchCanBeSeededInConstructor() public {
        uint256[] memory initial = new uint256[](1);
        initial[0] = LEGACY_GAUGE_ID;

        CurveGaugeRegistry reg = new CurveGaugeRegistry("Curve Gauge Registry", address(this), initial);

        assertTrue(reg.isRegisteredGauge(address(legacyGauge)));
        assertEq(reg.gaugeLength(), 1);
        assertEq(reg.activeGauges(0), address(legacyGauge));
    }

    function test_setGaugeEmitsAddEvent() public {
        vm.expectEmit(true, true, false, false);
        emit CurveGaugeRegistry.SetGauge(address(gauge1), true);
        registry.setGauge(GAUGE1_ID);
    }

    function test_setGaugeEmitsRemovalEvent() public {
        registry.setGauge(GAUGE1_ID);

        gauge1.setKilled(true);

        vm.expectEmit(true, true, false, false);
        emit CurveGaugeRegistry.SetGauge(address(gauge1), false);
        registry.setGauge(GAUGE1_ID);
    }

    function test_removeMiddleElementSwapAndPop() public {
        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);
        registry.setGauge(GAUGE3_ID);
        registry.setGauge(GAUGE5_ID);

        assertEq(registry.gaugeLength(), 4);

        gauge2.setKilled(true);
        registry.setGauge(GAUGE2_ID);

        assertEq(registry.gaugeLength(), 3);
        assertFalse(registry.isRegisteredGauge(address(gauge2)));

        assertEq(registry.activeGaugeIndex(address(gauge1)), 1);
        assertEq(registry.activeGaugeIndex(address(gauge5)), 2);
        assertEq(registry.activeGaugeIndex(address(gauge3)), 3);
    }

    function test_sequentialRemovals() public {
        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);
        registry.setGauge(GAUGE3_ID);

        gauge2.setKilled(true);
        registry.setGauge(GAUGE2_ID);

        assertEq(registry.gaugeLength(), 2);

        gauge1.setKilled(true);
        registry.setGauge(GAUGE1_ID);

        assertEq(registry.gaugeLength(), 1);
        assertTrue(registry.isRegisteredGauge(address(gauge3)));
        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertFalse(registry.isRegisteredGauge(address(gauge2)));
    }

    function test_setGaugeNoopWhenAlreadyActive() public {
        registry.setGauge(GAUGE1_ID);
        assertEq(registry.gaugeLength(), 1);

        registry.setGauge(GAUGE1_ID);
        assertEq(registry.gaugeLength(), 1);
    }

    function test_setGaugeNoopWhenInvalid() public {
        gauge4.setKilled(true);

        registry.setGauge(GAUGE4_ID);
        assertEq(registry.gaugeLength(), 0);

        registry.setGauge(GAUGE4_ID);
        assertEq(registry.gaugeLength(), 0);
    }

    function test_weightGoesToZeroDoesNotRemoveGauge() public {
        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);

        MockGaugeController(GAUGE_CONTROLLER).setGaugeWeight(address(gauge1), 0);

        registry.setGauge(GAUGE1_ID);

        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 2);
        assertTrue(registry.isRegisteredGauge(address(gauge2)));
    }

    function test_allGaugesRemoved() public {
        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);
        registry.setGauge(GAUGE5_ID);

        gauge1.setKilled(true);
        gauge2.setKilled(true);
        gauge5.setKilled(true);

        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);
        registry.setGauge(GAUGE5_ID);

        assertEq(registry.gaugeLength(), 0);
    }

    function test_isRegisteredGaugeUnregistered() public view {
        assertFalse(registry.isRegisteredGauge(address(gauge1)));
    }

    function test_removeSingleElement() public {
        registry.setGauge(GAUGE1_ID);
        assertEq(registry.gaugeLength(), 1);

        gauge1.setKilled(true);
        registry.setGauge(GAUGE1_ID);

        assertEq(registry.gaugeLength(), 0);
        assertFalse(registry.isRegisteredGauge(address(gauge1)));
    }

    function test_inactiveGaugeReAdding() public {
        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);

        gauge1.setKilled(true);
        registry.setGauge(GAUGE1_ID);

        assertFalse(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 1);

        gauge1.setKilled(false);
        registry.setGauge(GAUGE1_ID);

        assertTrue(registry.isRegisteredGauge(address(gauge1)));
        assertEq(registry.gaugeLength(), 2);
    }

    function test_removeFirstOfThree() public {
        registry.setGauge(GAUGE1_ID);
        registry.setGauge(GAUGE2_ID);
        registry.setGauge(GAUGE3_ID);

        gauge1.setKilled(true);
        registry.setGauge(GAUGE1_ID);

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
