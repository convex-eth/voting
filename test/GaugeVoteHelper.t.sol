// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/SurrogateRegistry.sol";
import "../src/Delegation.sol";
import "../src/GaugeVoteHelper.sol";
import "../src/interface/IvlCVX.sol";
import "./mocks/simpleVlCvx.sol";
import "./mocks/MockGauges.sol";

contract GaugeVoteHelperTest is Test {
    IvlCVX internal vlcvx;
    Delegation internal delegation;
    CurveGaugeRegistry internal gaugeRegistry;
    SurrogateRegistry internal surrogateRegistry;
    GaugeVotePlatform internal platform;
    GaugeVoteHelper internal calc;

    MockCurveGauge internal gauge1;
    MockCurveGauge internal gauge2;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal delegate1 = makeAddr("delegate1");
    address internal operator = makeAddr("operator");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WD = 1e17;

    address[] internal singleGauge;
    uint256[] internal fullWeight;

    function setUp() public {
        vm.warp(1700000000);

        simpleVlCvx impl = new simpleVlCvx();
        vlcvx = IvlCVX(address(impl));
        delegation = new Delegation("Convex Delegation", address(vlcvx));

        address gaugeController = address(new MockGaugeController());
        vm.etch(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB, address(gaugeController).code);

        gaugeRegistry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), new address[](0));
        surrogateRegistry = new SurrogateRegistry("Convex Surrogate Registry");

        platform = new GaugeVotePlatform("Convex Gauge Voting", 
            address(this),
            address(vlcvx),
            address(gaugeRegistry),
            address(surrogateRegistry),
            address(delegation)
        );

        calc = new GaugeVoteHelper("Convex Gauge Vote Helper", address(delegation), address(platform));

        gauge1 = new MockCurveGauge();
        gauge2 = new MockCurveGauge();

        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge1), 1000);
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge2), 2000);

        gaugeRegistry.setGauge(address(gauge1));
        gaugeRegistry.setGauge(address(gauge2));

        platform.setOperator(operator, true);

        singleGauge.push(address(gauge1));
        fullWeight.push(10000);
    }

    function _lock(address user, uint256 amount) internal {
        vlcvx.lock(user, amount * WD, 0);
    }

    function _lockAndDelegate(address user, uint256 amount, address del) internal {
        _lock(user, amount);
        if (del != address(0)) {
            vm.prank(user);
            delegation.setDelegate(del);
        }
    }

    function _nextEpoch() internal {
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

    function _vote(address user, address[] memory gauges, uint256[] memory weights) internal {
        vm.prank(user);
        platform.vote(user, gauges, weights);
    }

    function _query(address user, uint256 pid) internal returns (uint256) {
        address[] memory users = new address[](1);
        users[0] = user;
        uint256[] memory weights = calc.getContributingWeights(pid, delegate1, users);
        return weights[0];
    }

    // === Pattern A: user votes themselves - no relock ===
    function test_A_userVotesNoRelock() public {
        _lockAndDelegate(alice, 100, delegate1);
        _nextEpoch();

        uint256 pid = _createProposal();
        _vote(alice, singleGauge, fullWeight);

        assertEq(_query(alice, pid), 0);
    }

    // === Pattern B: user votes themselves - relocked+synced BEFORE voting ===
    function test_B_userVotesRelockBeforeVote() public {
        _lockAndDelegate(alice, 100, delegate1);
        _nextEpoch();

        uint256 pid = _createProposal();
        vlcvx.lock(alice, 50 * WD, 0);
        delegation.sync(alice);
        _vote(alice, singleGauge, fullWeight);

        assertEq(_query(alice, pid), 0);
    }

    // === Pattern C: user votes, relocks+syncs after, then votes again ===
    function test_C_userVotesRelockThenRevotes() public {
        _lockAndDelegate(alice, 100, delegate1);
        _nextEpoch();

        uint256 pid = _createProposal();
        _vote(alice, singleGauge, fullWeight);

        vm.warp(vm.getBlockTimestamp() + 100);
        vlcvx.lock(alice, 50 * WD, 0);
        delegation.sync(alice);

        _vote(alice, singleGauge, fullWeight);

        assertEq(_query(alice, pid), 0);
    }

    // === Pattern D: user votes, relocks+syncs after, does NOT vote again ===
    function test_D_userVotesRelockNoRevote() public {
        _lockAndDelegate(alice, 100, delegate1);
        _lockAndDelegate(delegate1, 200, address(0));
        _nextEpoch();

        uint256 pid = _createProposal();
        _vote(alice, singleGauge, fullWeight);

        vm.warp(vm.getBlockTimestamp() + 100);
        vlcvx.lock(alice, 50 * WD, 0);
        delegation.sync(alice);

        assertEq(_query(alice, pid), 0);
    }

    // === Pattern E: user does NOT vote - no relock ===
    function test_E_userNoVoteNoRelock() public {
        _lockAndDelegate(alice, 100, delegate1);
        _lockAndDelegate(delegate1, 200, address(0));
        _nextEpoch();

        uint256 pid = _createProposal();
        _vote(delegate1, singleGauge, fullWeight);

        assertEq(_query(alice, pid), 100 * WD);
    }

    // === Pattern F: user does NOT vote - relock/sync BEFORE delegate's last vote ===
    function test_F_userNoVoteRelockBeforeDelegateVotes() public {
        _lockAndDelegate(alice, 100, delegate1);
        _lockAndDelegate(delegate1, 200, address(0));
        _nextEpoch();

        uint256 pid = _createProposal();

        vlcvx.lock(alice, 50 * WD, 0);
        delegation.sync(alice);

        _vote(delegate1, singleGauge, fullWeight);

        assertEq(_query(alice, pid), 100 * WD);
    }

    // === Pattern G: user does NOT vote - relock/sync AFTER delegate's last vote ===
    function test_G_userNoVoteRelockAfterDelegateVotes() public {
        _lockAndDelegate(alice, 100, delegate1);
        _lockAndDelegate(delegate1, 200, address(0));
        _nextEpoch();

        uint256 pid = _createProposal();
        _vote(delegate1, singleGauge, fullWeight);

        vm.warp(vm.getBlockTimestamp() + 100);
        vlcvx.lock(alice, 50 * WD, 0);
        delegation.sync(alice);

        assertEq(_query(alice, pid), 100 * WD);
    }

    function test_userNotDelegatedToThisDelegate() public {
        _lock(alice, 100);
        _lockAndDelegate(delegate1, 200, address(0));
        _nextEpoch();

        uint256 pid = _createProposal();
        _vote(delegate1, singleGauge, fullWeight);

        assertEq(_query(alice, pid), 0);
    }

    function test_delegateNotVoted() public {
        _lockAndDelegate(alice, 100, delegate1);
        _nextEpoch();

        uint256 pid = _createProposal();

        assertEq(_query(alice, pid), 100 * WD);
    }

    function test_multipleUsers() public {
        _lockAndDelegate(alice, 100, delegate1);
        _lockAndDelegate(bob, 50, delegate1);
        _lock(carol, 75);
        _lockAndDelegate(delegate1, 200, address(0));
        _nextEpoch();

        uint256 pid = _createProposal();
        _vote(delegate1, singleGauge, fullWeight);

        vm.warp(vm.getBlockTimestamp() + 100);
        vlcvx.lock(alice, 50 * WD, 0);
        delegation.sync(alice);

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;

        uint256[] memory weights = calc.getContributingWeights(pid, delegate1, users);

        assertEq(weights[0], 100 * WD, "alice: G - pre-sync, delegate voted before");
        assertEq(weights[1], 50 * WD, "bob: E - no sync, full weight");
        assertEq(weights[2], 0, "carol: not delegated");
    }
}
