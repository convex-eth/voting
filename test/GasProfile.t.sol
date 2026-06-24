// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/SurrogateRegistry.sol";
import "../src/Delegation.sol";
import "../src/interface/IvlCVX.sol";
import "./mocks/simpleVlCvx.sol";
import "./mocks/MockGauges.sol";

contract GasProfile is Test {
    IvlCVX internal vlcvx;
    Delegation internal delegation;
    CurveGaugeRegistry internal gaugeRegistry;
    SurrogateRegistry internal surrogateRegistry;
    GaugeVotePlatform internal platform;

    MockCurveGauge internal gauge1;
    MockCurveGauge internal gauge2;
    MockCurveGauge internal gauge3;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal operator = makeAddr("operator");
    address internal surrogate = makeAddr("surrogate");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WD = 1e17;

    function setUp() public {
        vm.warp(1700000000);

        simpleVlCvx impl = new simpleVlCvx();
        vlcvx = IvlCVX(address(impl));
        delegation = new Delegation("Convex Delegation", address(this), address(vlcvx));

        address gaugeController = address(new MockGaugeController());
        vm.etch(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB, address(gaugeController).code);

        gaugeRegistry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), new uint256[](0));
        surrogateRegistry = new SurrogateRegistry("Convex Surrogate Registry");

        platform = new GaugeVotePlatform(
            "Convex Gauge Voting",
            address(this),
            address(vlcvx),
            address(gaugeRegistry),
            address(surrogateRegistry),
            address(delegation)
        );

        gauge1 = new MockCurveGauge();
        gauge2 = new MockCurveGauge();
        gauge3 = new MockCurveGauge();

        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGauge(0, address(gauge1));
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGauge(1, address(gauge2));
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGauge(2, address(gauge3));
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge1), 1000);
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge2), 2000);
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge3), 500);

        gaugeRegistry.setGauge(0);
        gaugeRegistry.setGauge(1);
        gaugeRegistry.setGauge(2);

        platform.setOperator(operator, true);
    }

    function _lock(address user, uint256 amount) internal {
        vlcvx.lock(user, amount * WD, 0);
    }

    function _lockAndDelegate(address user, uint256 amount, address delegateAddr) internal {
        vlcvx.lock(user, amount * WD, 0);
        if (delegateAddr != address(0)) {
            vm.prank(user);
            delegation.setDelegate(delegateAddr);
        }
    }

    function _warpToNextEpoch() internal {
        uint256 currentEpoch = (vm.getBlockTimestamp() / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);
    }

    function _createProposal() internal returns (uint256) {
        uint256 startTime = vm.getBlockTimestamp() + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        platform.createProposal(startTime, endTime);
        vm.warp(startTime);
        return platform.proposalCount() - 1;
    }

    function _gauges1(address g) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = g;
        return arr;
    }

    function _weights1(uint256 w) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = w;
        return arr;
    }

    function _gauges3(address g1, address g2, address g3) internal pure returns (address[] memory) {
        address[] memory arr = new address[](3);
        arr[0] = g1;
        arr[1] = g2;
        arr[2] = g3;
        return arr;
    }

    function _weights3(uint256 w1, uint256 w2, uint256 w3) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](3);
        arr[0] = w1;
        arr[1] = w2;
        arr[2] = w3;
        return arr;
    }

    // ──────────────────────────────────────────────────────
    // Profile: No delegate, first vote, 1 gauge
    // ──────────────────────────────────────────────────────
    function test_gas_noDelegate_firstVote_1gauge() public {
        _lock(alice, 1000);
        _warpToNextEpoch();
        _createProposal();

        vm.prank(alice);
        platform.vote(alice, _gauges1(address(gauge1)), _weights1(10000));
    }

    // ──────────────────────────────────────────────────────
    // Profile: No delegate, first vote, 2 gauges
    // (subtract 1-gauge cost to get marginal cost of +1 gauge)
    // ──────────────────────────────────────────────────────
    function test_gas_noDelegate_firstVote_2gauges() public {
        _lock(alice, 1000);
        _warpToNextEpoch();
        _createProposal();

        address[] memory g = new address[](2);
        g[0] = address(gauge1);
        g[1] = address(gauge2);
        uint256[] memory w = new uint256[](2);
        w[0] = 5000;
        w[1] = 5000;

        vm.prank(alice);
        platform.vote(alice, g, w);
    }

    // ──────────────────────────────────────────────────────
    // Profile: No delegate, first vote, 3 gauges
    // ──────────────────────────────────────────────────────
    function test_gas_noDelegate_firstVote_3gauges() public {
        _lock(alice, 1000);
        _warpToNextEpoch();
        _createProposal();

        vm.prank(alice);
        platform.vote(alice, _gauges3(address(gauge1), address(gauge2), address(gauge3)), _weights3(3333, 3333, 3334));
    }

    // ──────────────────────────────────────────────────────
    // Profile: Delegate already voted 1 gauge, user overwrites with 1 gauge
    // ──────────────────────────────────────────────────────
    function test_gas_delegateVoted1gauge_userOverwrites_1gauge() public {
        _lockAndDelegate(alice, 500, bob);
        _lockAndDelegate(bob, 2000, address(0));
        _warpToNextEpoch();
        _createProposal();

        vm.prank(bob);
        platform.vote(bob, _gauges1(address(gauge1)), _weights1(10000));

        vm.prank(alice);
        platform.vote(alice, _gauges1(address(gauge2)), _weights1(10000));
    }

    // ──────────────────────────────────────────────────────
    // Profile: Delegate already voted 3 gauges, user overwrites with 1 gauge
    // (shows cost of removing delegate's contributions from 3 gauges)
    // ──────────────────────────────────────────────────────
    function test_gas_delegateVoted3gauges_userOverwrites_1gauge() public {
        _lockAndDelegate(alice, 500, bob);
        _lockAndDelegate(bob, 2000, address(0));
        _warpToNextEpoch();
        _createProposal();

        vm.prank(bob);
        platform.vote(bob, _gauges3(address(gauge1), address(gauge2), address(gauge3)), _weights3(3333, 3333, 3334));

        vm.prank(alice);
        platform.vote(alice, _gauges1(address(gauge1)), _weights1(10000));
    }

    // ──────────────────────────────────────────────────────
    // Profile: Second vote, same 3 gauges, different weightings
    // ──────────────────────────────────────────────────────
    function test_gas_revote_same3gauges_differentWeights() public {
        _lock(alice, 1000);
        _warpToNextEpoch();
        _createProposal();

        vm.prank(alice);
        platform.vote(alice, _gauges3(address(gauge1), address(gauge2), address(gauge3)), _weights3(5000, 3000, 2000));

        vm.prank(alice);
        platform.vote(alice, _gauges3(address(gauge1), address(gauge2), address(gauge3)), _weights3(2000, 5000, 3000));
    }

    // ──────────────────────────────────────────────────────
    // Profile: Second vote, 3 different gauges
    // ──────────────────────────────────────────────────────
    function test_gas_revote_3differentGauges() public {
        _lock(alice, 1000);
        _warpToNextEpoch();
        _createProposal();

        vm.prank(alice);
        platform.vote(alice, _gauges3(address(gauge1), address(gauge2), address(gauge3)), _weights3(3333, 3333, 3334));

        MockCurveGauge gauge4 = new MockCurveGauge();
        MockCurveGauge gauge5 = new MockCurveGauge();
        MockCurveGauge gauge6 = new MockCurveGauge();
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGauge(3, address(gauge4));
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGauge(4, address(gauge5));
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGauge(5, address(gauge6));
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge4), 1000);
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge5), 1000);
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge6), 1000);
        gaugeRegistry.setGauge(3);
        gaugeRegistry.setGauge(4);
        gaugeRegistry.setGauge(5);

        vm.prank(alice);
        platform.vote(alice, _gauges3(address(gauge4), address(gauge5), address(gauge6)), _weights3(3333, 3333, 3334));
    }

    // ──────────────────────────────────────────────────────
    // Profile: Delegate votes after delegatee already voted (1 delegatee, 1 gauge)
    // ──────────────────────────────────────────────────────
    function test_gas_delegateeVotedFirst_delegateVotes_1gauge() public {
        _lockAndDelegate(alice, 500, bob);
        _lockAndDelegate(bob, 2000, address(0));
        _warpToNextEpoch();
        _createProposal();

        vm.prank(alice);
        platform.vote(alice, _gauges1(address(gauge1)), _weights1(10000));

        vm.prank(bob);
        platform.vote(bob, _gauges1(address(gauge2)), _weights1(10000));
    }

    // ──────────────────────────────────────────────────────
    // Profile: Surrogate votes for user (no delegate, 1 gauge)
    // ──────────────────────────────────────────────────────
    function test_gas_surrogateVote_1gauge() public {
        _lock(alice, 1000);
        _warpToNextEpoch();
        _createProposal();

        vm.prank(alice);
        surrogateRegistry.setSurrogate(surrogate);

        vm.prank(surrogate);
        platform.vote(alice, _gauges1(address(gauge1)), _weights1(10000));
    }

    // ──────────────────────────────────────────────────────
    // Profile: User overrides surrogate vote (1 gauge -> 1 gauge)
    // ──────────────────────────────────────────────────────
    function test_gas_userOverridesSurrogate_1gauge() public {
        _lock(alice, 1000);
        _warpToNextEpoch();
        _createProposal();

        vm.prank(alice);
        surrogateRegistry.setSurrogate(surrogate);

        vm.prank(surrogate);
        platform.vote(alice, _gauges1(address(gauge1)), _weights1(10000));

        vm.prank(alice);
        platform.vote(alice, _gauges1(address(gauge2)), _weights1(10000));
    }

    // ──────────────────────────────────────────────────────
    // Profile: Delegate with 2 delegatees voting (delegate votes last)
    // ──────────────────────────────────────────────────────
    function test_gas_twoDelegateesThenDelegate() public {
        _lockAndDelegate(alice, 500, carol);
        _lockAndDelegate(bob, 700, carol);
        _lockAndDelegate(carol, 2000, address(0));
        _warpToNextEpoch();
        _createProposal();

        vm.prank(alice);
        platform.vote(alice, _gauges1(address(gauge1)), _weights1(10000));

        vm.prank(bob);
        platform.vote(bob, _gauges1(address(gauge2)), _weights1(10000));

        vm.prank(carol);
        platform.vote(carol, _gauges1(address(gauge3)), _weights1(10000));
    }

    // ──────────────────────────────────────────────────────
    // Profile: Delegation._syncUser (setDelegate triggers it)
    // ──────────────────────────────────────────────────────

    function test_gas_syncUser_1lock() public {
        _lock(alice, 1000);
        vm.prank(alice);
        delegation.setDelegate(bob);
    }

    function test_gas_syncUser_2locks() public {
        _lock(alice, 1000);
        _warpToNextEpoch();
        _lock(alice, 500);
        vm.prank(alice);
        delegation.setDelegate(bob);
    }

    function test_gas_syncUser_3locks() public {
        _lock(alice, 1000);
        _warpToNextEpoch();
        _lock(alice, 500);
        _warpToNextEpoch();
        _lock(alice, 300);
        vm.prank(alice);
        delegation.setDelegate(bob);
    }

    function test_gas_syncUser_resync_1lock() public {
        _lockAndDelegate(alice, 1000, bob);
        _warpToNextEpoch();
        delegation.sync(alice);
    }

    function test_gas_syncUser_resync_2locks() public {
        _lockAndDelegate(alice, 1000, bob);
        _warpToNextEpoch();
        _lock(alice, 500);
        delegation.sync(alice);
    }

    function test_gas_isolated_setDelegate_1lock() public {
        _lock(alice, 1000);
        uint256 g = gasleft();
        vm.prank(alice);
        delegation.setDelegate(bob);
        console.log("setDelegate 1 lock:", g - gasleft());
    }

    function test_gas_isolated_setDelegate_2locks() public {
        _lock(alice, 1000);
        _warpToNextEpoch();
        _lock(alice, 500);
        uint256 g = gasleft();
        vm.prank(alice);
        delegation.setDelegate(bob);
        console.log("setDelegate 2 locks:", g - gasleft());
    }

    function test_gas_isolated_setDelegate_3locks() public {
        _lock(alice, 1000);
        _warpToNextEpoch();
        _lock(alice, 500);
        _warpToNextEpoch();
        _lock(alice, 300);
        uint256 g = gasleft();
        vm.prank(alice);
        delegation.setDelegate(bob);
        console.log("setDelegate 3 locks:", g - gasleft());
    }

    function test_gas_isolated_sync_1lock() public {
        _lockAndDelegate(alice, 1000, bob);
        _warpToNextEpoch();
        uint256 g = gasleft();
        delegation.sync(alice);
        console.log("sync 1 lock:", g - gasleft());
    }

    function test_gas_isolated_sync_2locks() public {
        _lockAndDelegate(alice, 1000, bob);
        _warpToNextEpoch();
        _lock(alice, 500);
        uint256 g = gasleft();
        delegation.sync(alice);
        console.log("sync 2 locks:", g - gasleft());
    }

    function test_gas_isolated_sync_3locks() public {
        _lockAndDelegate(alice, 1000, bob);
        _warpToNextEpoch();
        _lock(alice, 500);
        _warpToNextEpoch();
        _lock(alice, 300);
        uint256 g = gasleft();
        delegation.sync(alice);
        console.log("sync 3 locks:", g - gasleft());
    }
}
