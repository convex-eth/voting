// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/FxGaugeRegistry.sol";
import "../src/interface/IFxGauge.sol";
import "../src/interface/IFxGaugeController.sol";

contract MockFxGaugeController is IFxGaugeController {
    mapping(address => uint256) public gauge_types;

    function setGaugeType(address _gauge, uint256 _type) external {
        gauge_types[_gauge] = _type;
    }
}

contract MockFxGauge is IFxGauge {
    bool public isActive;

    function setActive(bool _active) external {
        isActive = _active;
    }
}

contract FxGaugeRegistryTest is Test {
    FxGaugeRegistry internal registry;
    MockFxGaugeController internal mockController;
    MockFxGauge internal mockGauge;

    address internal owner = address(this);
    address internal gauge = makeAddr("gauge");

    address constant GAUGE_CONTROLLER = 0xe60eB8098B34eD775ac44B1ddE864e098C6d7f37;

    function setUp() public {
        mockController = new MockFxGaugeController();
        mockGauge = new MockFxGauge();

        vm.etch(GAUGE_CONTROLLER, address(mockController).code);
        vm.etch(gauge, address(mockGauge).code);

        address[] memory initial = new address[](0);
        registry = new FxGaugeRegistry(owner, initial);
    }

    function test_initialGaugesRegisteredWithoutValidation() public {
        address[] memory empty = new address[](0);
        address[] memory initial = new address[](2);
        initial[0] = gauge;
        initial[1] = makeAddr("fakeGauge");

        FxGaugeRegistry reg = new FxGaugeRegistry(owner, initial);

        assertEq(reg.gaugeLength(), 2);
        assertTrue(reg.isRegisteredGauge(gauge));
        assertTrue(reg.isRegisteredGauge(makeAddr("fakeGauge")));
        assertFalse(reg.isRegisteredGauge(makeAddr("nonExistent")));
    }

    function test_forceRemove() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);
        registry.setGauge(gauge);
        assertEq(registry.gaugeLength(), 1);

        registry.forceRemove(gauge);

        assertEq(registry.gaugeLength(), 0);
        assertFalse(registry.isRegisteredGauge(gauge));
        assertTrue(registry.forceRemoved(gauge));
    }

    function test_forceRemoveNotActive() public {
        assertFalse(registry.isRegisteredGauge(gauge));

        registry.forceRemove(gauge);

        assertFalse(registry.isRegisteredGauge(gauge));
        assertTrue(registry.forceRemoved(gauge));
    }

    function test_setGaugeCannotReAddForceRemoved() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);
        registry.setGauge(gauge);
        registry.forceRemove(gauge);

        registry.setGauge(gauge);

        assertFalse(registry.isRegisteredGauge(gauge));
        assertEq(registry.gaugeLength(), 0);
    }

    function test_reinstateForceRemoved() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);
        registry.setGauge(gauge);
        registry.forceRemove(gauge);
        assertTrue(registry.forceRemoved(gauge));

        registry.reinstate(gauge);

        assertFalse(registry.forceRemoved(gauge));
        assertFalse(registry.isRegisteredGauge(gauge));
    }

    function test_validGauge_type0_active() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);

        assertTrue(registry.isValidGauge(gauge));
    }

    function test_validGauge_type1_active() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 1);
        MockFxGauge(gauge).setActive(true);

        assertTrue(registry.isValidGauge(gauge));
    }

    function test_invalidGauge_type2() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 2);
        MockFxGauge(gauge).setActive(true);

        assertFalse(registry.isValidGauge(gauge));
    }

    function test_invalidGauge_inactive() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(false);

        assertFalse(registry.isValidGauge(gauge));
    }

    function test_setGauge_addsValid() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);

        registry.setGauge(gauge);

        assertEq(registry.gaugeLength(), 1);
        assertTrue(registry.isRegisteredGauge(gauge));
    }

    function test_setGauge_removesInvalid() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);

        registry.setGauge(gauge);
        assertEq(registry.gaugeLength(), 1);

        MockFxGauge(gauge).setActive(false);
        registry.setGauge(gauge);

        assertEq(registry.gaugeLength(), 0);
        assertFalse(registry.isRegisteredGauge(gauge));
    }

    function test_setGauge_noop_invalid() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 2);
        MockFxGauge(gauge).setActive(true);

        registry.setGauge(gauge);

        assertEq(registry.gaugeLength(), 0);
    }
}
