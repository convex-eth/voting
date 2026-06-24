// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/FxGaugeRegistry.sol";
import "../src/interface/IFxGauge.sol";
import "../src/interface/IFxGaugeController.sol";

contract MockFxGaugeController is IFxGaugeController {
    mapping(uint256 => address) public gauges;
    uint256 public n_gauges;
    mapping(address => uint256) public gaugeTypes;
    mapping(address => bool) public registeredGauges;

    function setGauge(uint256 _gaugeId, address _gauge) external {
        gauges[_gaugeId] = _gauge;
        registeredGauges[_gauge] = true;
        if (_gaugeId >= n_gauges) n_gauges = _gaugeId + 1;
    }

    function setGaugeType(address _gauge, uint256 _type) external {
        gaugeTypes[_gauge] = _type;
    }

    function gauge_types(address _gauge) external view override returns (uint256) {
        require(registeredGauges[_gauge], "gauge is not added");
        return gaugeTypes[_gauge];
    }
}

contract MockFxGauge is IFxGauge {
    bool public isActive;
    bool public is_killed;

    function setActive(bool _active) external {
        isActive = _active;
    }

    function setKilled(bool _killed) external {
        is_killed = _killed;
    }
}

contract FxGaugeRegistryTest is Test {
    FxGaugeRegistry internal registry;
    MockFxGaugeController internal mockController;
    MockFxGauge internal mockGauge;

    address internal owner = address(this);
    address internal gauge = makeAddr("gauge");
    address internal nonOwner = makeAddr("nonOwner");

    uint256 internal constant GAUGE_ID = 0;

    address constant GAUGE_CONTROLLER = 0xe60eB8098B34eD775ac44B1ddE864e098C6d7f37;

    function setUp() public {
        mockController = new MockFxGaugeController();
        mockGauge = new MockFxGauge();

        vm.etch(GAUGE_CONTROLLER, address(mockController).code);
        vm.etch(gauge, address(mockGauge).code);
        MockFxGaugeController(GAUGE_CONTROLLER).setGauge(GAUGE_ID, gauge);

        uint256[] memory initial = new uint256[](0);
        registry = new FxGaugeRegistry("Fx Gauge Registry", owner, initial);
    }

    function test_initialGaugesRegisteredWithoutValidation() public {
        address fakeGauge = makeAddr("fakeGauge");
        MockFxGaugeController(GAUGE_CONTROLLER).setGauge(1, fakeGauge);

        uint256[] memory initial = new uint256[](2);
        initial[0] = GAUGE_ID;
        initial[1] = 1;

        FxGaugeRegistry reg = new FxGaugeRegistry("Fx Gauge Registry", owner, initial);

        assertEq(reg.gaugeLength(), 2);
        assertTrue(reg.isRegisteredGauge(gauge));
        assertTrue(reg.isRegisteredGauge(fakeGauge));
        assertFalse(reg.isRegisteredGauge(makeAddr("nonExistent")));
    }

    function test_forceRemove() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);
        registry.setGauge(GAUGE_ID);
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
        registry.setGauge(GAUGE_ID);
        registry.forceRemove(gauge);

        registry.setGauge(GAUGE_ID);

        assertFalse(registry.isRegisteredGauge(gauge));
        assertEq(registry.gaugeLength(), 0);
    }

    function test_reinstateForceRemoved() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);
        registry.setGauge(GAUGE_ID);
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

        registry.setGauge(GAUGE_ID);

        assertEq(registry.gaugeLength(), 1);
        assertTrue(registry.isRegisteredGauge(gauge));
    }

    function test_setGaugeByAddress_addsValid() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);

        registry.setGauge(gauge);

        assertEq(registry.gaugeLength(), 1);
        assertTrue(registry.isRegisteredGauge(gauge));
        assertEq(registry.activeGauges(0), gauge);
    }

    function test_permissionlessSetGaugeAddsValidGauge() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);

        vm.prank(nonOwner);
        registry.setGauge(GAUGE_ID);

        assertEq(registry.gaugeLength(), 1);
        assertTrue(registry.isRegisteredGauge(gauge));
    }

    function test_setGauge_removesInvalid() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);

        registry.setGauge(GAUGE_ID);
        assertEq(registry.gaugeLength(), 1);

        MockFxGauge(gauge).setActive(false);
        registry.setGauge(GAUGE_ID);

        assertEq(registry.gaugeLength(), 0);
        assertFalse(registry.isRegisteredGauge(gauge));
    }

    function test_setGaugeByAddress_removesInvalid() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 0);
        MockFxGauge(gauge).setActive(true);

        registry.setGauge(gauge);
        assertEq(registry.gaugeLength(), 1);

        MockFxGauge(gauge).setActive(false);
        registry.setGauge(gauge);

        assertEq(registry.gaugeLength(), 0);
        assertFalse(registry.isRegisteredGauge(gauge));
    }

    function test_isValidGaugeUnregisteredReverts() public {
        address unregisteredGauge = makeAddr("unregisteredGauge");
        vm.etch(unregisteredGauge, address(mockGauge).code);

        vm.expectRevert("gauge is not added");
        registry.isValidGauge(unregisteredGauge);
    }

    function test_setGaugeByAddressUnregisteredReverts() public {
        address unregisteredGauge = makeAddr("unregisteredGauge");
        vm.etch(unregisteredGauge, address(mockGauge).code);

        vm.expectRevert("gauge is not added");
        registry.setGauge(unregisteredGauge);
    }

    function test_setGauge_noop_invalid() public {
        MockFxGaugeController(GAUGE_CONTROLLER).setGaugeType(gauge, 2);
        MockFxGauge(gauge).setActive(true);

        registry.setGauge(GAUGE_ID);

        assertEq(registry.gaugeLength(), 0);
    }
}
