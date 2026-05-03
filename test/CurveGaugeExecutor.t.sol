// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/SurrogateRegistry.sol";
import "../src/Delegation.sol";
import "../src/CurveGaugeExecutor.sol";
import "./mocks/MockVlCVX.sol";
import "./mocks/MockGauges.sol";
import "./mocks/MockVoteDelegateExtension.sol";

contract CurveGaugeExecutorTest is Test {
    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;
    CurveGaugeRegistry internal gaugeRegistry;
    SurrogateRegistry internal surrogateRegistry;
    GaugeVotePlatform internal platform;
    CurveGaugeExecutor internal executor;
    MockVoteDelegateExtension internal voteDelegate;

    MockCurveGauge internal gauge1;
    MockCurveGauge internal gauge2;
    MockCurveGauge internal gauge3;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal operator = makeAddr("operator");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WD = 1e17;

    function setUp() public {
        vm.warp(WEEK * 2);

        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));

        address gaugeController = address(new MockGaugeController());
        vm.etch(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB, gaugeController.code);

        gaugeRegistry = new CurveGaugeRegistry();
        surrogateRegistry = new SurrogateRegistry();

        platform = new GaugeVotePlatform(
            address(this),
            address(mockVlCVX),
            address(gaugeRegistry),
            address(surrogateRegistry),
            address(delegation)
        );

        voteDelegate = new MockVoteDelegateExtension();
        executor = new CurveGaugeExecutor( address(platform), address(voteDelegate));

        gauge1 = new MockCurveGauge();
        gauge2 = new MockCurveGauge();
        gauge3 = new MockCurveGauge();

        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge1), 1000);
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge2), 2000);
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge3), 500);

        gaugeRegistry.setGauge(address(gauge1));
        gaugeRegistry.setGauge(address(gauge2));
        gaugeRegistry.setGauge(address(gauge3));

        platform.setOperator(operator, true);
    }

    function _lockAndDelegate(address user, uint256 amount, address delegateAddr) internal {
        mockVlCVX.mockLock(user, amount * WD, amount * WD);
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
        uint256 pid = platform.proposalCount() - 1;
        vm.warp(startTime);
        return pid;
    }

    function _finalizeProposal(uint256 pid) internal {
        (, uint256 endTime,) = platform.proposals(pid);
        vm.warp(endTime + platform.overtime() + 1);
    }

    function _vote(address user, address[] memory gauges, uint256[] memory weights) internal {
        vm.prank(user);
        platform.vote(user, gauges, weights);
    }

    function _getGauges(address g1) internal pure returns (address[] memory) {
        address[] memory gauges = new address[](1);
        gauges[0] = g1;
        return gauges;
    }

    function _getWeights(uint256 w1) internal pure returns (uint256[] memory) {
        uint256[] memory weights = new uint256[](1);
        weights[0] = w1;
        return weights;
    }

    function _getGauges2(address g1, address g2) internal pure returns (address[] memory) {
        address[] memory gauges = new address[](2);
        gauges[0] = g1;
        gauges[1] = g2;
        return gauges;
    }

    function _getWeights2(uint256 w1, uint256 w2) internal pure returns (uint256[] memory) {
        uint256[] memory weights = new uint256[](2);
        weights[0] = w1;
        weights[1] = w2;
        return weights;
    }

    function _getGauges3(address g1, address g2, address g3) internal pure returns (address[] memory) {
        address[] memory gauges = new address[](3);
        gauges[0] = g1;
        gauges[1] = g2;
        gauges[2] = g3;
        return gauges;
    }

    function _getWeights3(uint256 w1, uint256 w2, uint256 w3) internal pure returns (uint256[] memory) {
        uint256[] memory weights = new uint256[](3);
        weights[0] = w1;
        weights[1] = w2;
        weights[2] = w3;
        return weights;
    }

    // ========== Finalization Checks ==========

    function test_revertIfNotFinalized() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        (, uint256 endTime,) = platform.proposals(pid);
        vm.warp(endTime);

        address[] memory gauges = _getGauges(address(gauge1));
        vm.expectRevert(CurveGaugeExecutor.NotFinalized.selector);
        executor.executeGaugeVote(pid, gauges);
    }

    function test_revertIfNotLatestProposal() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid0 = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid0);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _lockAndDelegate(bob, 500, address(0));
        _warpToNextEpoch();

        uint256 startTime = vm.getBlockTimestamp() + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        platform.createProposal(startTime, endTime);
        uint256 pid1 = platform.proposalCount() - 1;
        vm.warp(startTime);
        _vote(bob, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid1);

        address[] memory gauges = _getGauges(address(gauge1));
        vm.expectRevert(CurveGaugeExecutor.NotLatestProposal.selector);
        executor.executeGaugeVote(pid0, gauges);
    }

    function test_revertIfEpochExpired() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        _warpToNextEpoch();

        address[] memory gauges = _getGauges(address(gauge1));
        vm.expectRevert(CurveGaugeExecutor.EpochExpired.selector);
        executor.executeGaugeVote(pid, gauges);
    }

    // ========== Weight Calculation ==========

    function test_singleGaugeFullWeight() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges(address(gauge1));
        executor.executeGaugeVote(pid, gauges);

        (address[] memory g, uint256[] memory w) = voteDelegate.getLastCall();
        assertEq(g.length, 1);
        assertEq(g[0], address(gauge1));
        assertEq(w[0], 10000);
    }

    function test_twoGaugesSplitWeight() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges2(address(gauge1), address(gauge2)), _getWeights2(6000, 4000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges2(address(gauge1), address(gauge2));
        executor.executeGaugeVote(pid, gauges);

        (address[] memory g, uint256[] memory w) = voteDelegate.getLastCall();
        assertEq(g.length, 2);
        assertEq(g[0], address(gauge1));
        assertEq(g[1], address(gauge2));
        assertEq(w[0], 6000);
        assertEq(w[1], 4000);
    }

    function test_multipleVotersWeightPaddedTo10000() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 500, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges2(address(gauge1), address(gauge2)), _getWeights2(6000, 4000));
        _vote(bob, _getGauges2(address(gauge1), address(gauge2)), _getWeights2(5000, 5000));

        _finalizeProposal(pid);

        uint256 totalVotes = platform.voteTotals(pid);
        uint256 gauge1Total = platform.gaugeTotal(pid, address(gauge1));
        uint256 expectedG1Weight = gauge1Total * 10000 / totalVotes;

        address[] memory gauges = _getGauges2(address(gauge1), address(gauge2));
        executor.executeGaugeVote(pid, gauges);

        (, uint256[] memory w) = voteDelegate.getLastCall();
        assertEq(w[0], expectedG1Weight);
        assertEq(w[0] + w[1], 10000);
    }

    function test_gaugeNotVotedGetsZeroWeight() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges2(address(gauge1), address(gauge2));
        executor.executeGaugeVote(pid, gauges);

        (address[] memory g, uint256[] memory w) = voteDelegate.getLastCall();
        assertEq(g.length, 2);
        assertEq(g[0], address(gauge1));
        assertEq(g[1], address(gauge2));
        assertEq(w[0], 10000);
        assertEq(w[1], 0);
    }

    function test_threeGaugesOneNotVoted() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges2(address(gauge1), address(gauge2)), _getWeights2(7000, 3000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges3(address(gauge1), address(gauge2), address(gauge3));
        executor.executeGaugeVote(pid, gauges);

        (address[] memory g, uint256[] memory w) = voteDelegate.getLastCall();
        assertEq(g.length, 3);
        assertEq(w[0], 7000);
        assertEq(w[1], 3000);
        assertEq(w[2], 0);
    }

    // ========== Permissionless ==========

    function test_anyoneCanExecute() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges(address(gauge1));
        vm.prank(bob);
        executor.executeGaugeVote(pid, gauges);

        assertEq(voteDelegate.callCount(), 1);
    }

    // ========== Edge Cases ==========

    function test_emptyGaugesArray() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        address[] memory gauges = new address[](0);
        executor.executeGaugeVote(pid, gauges);

        (address[] memory g, uint256[] memory w) = voteDelegate.getLastCall();
        assertEq(g.length, 0);
        assertEq(w.length, 0);
    }

    function test_revertOnNoVotes() public {
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges(address(gauge1));
        vm.expectRevert();
        executor.executeGaugeVote(pid, gauges);
    }

    function test_threeWayEvenSplitPaddedTo10000() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 1000, address(0));
        _lockAndDelegate(carol, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges3(address(gauge1), address(gauge2), address(gauge3)), _getWeights3(3333, 3334, 3333));
        _vote(bob, _getGauges3(address(gauge1), address(gauge2), address(gauge3)), _getWeights3(3334, 3333, 3333));
        _vote(carol, _getGauges3(address(gauge1), address(gauge2), address(gauge3)), _getWeights3(3333, 3333, 3334));

        _finalizeProposal(pid);

        uint256 totalVotes = platform.voteTotals(pid);
        assertEq(totalVotes, 3000 * WD);

        address[] memory gauges = _getGauges3(address(gauge1), address(gauge2), address(gauge3));
        executor.executeGaugeVote(pid, gauges);

        (address[] memory g, uint256[] memory w) = voteDelegate.getLastCall();
        assertEq(g.length, 3);

        uint256 g1Total = platform.gaugeTotal(pid, address(gauge1));
        assertEq(w[0], g1Total * 10000 / totalVotes);
        assertEq(w[0] + w[1] + w[2], 10000);
    }

    // ========== isDone ==========

    function test_isDoneFalseBeforeExecution() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        assertFalse(executor.isDone(pid));
    }

    function test_isDoneFalseIfNotFinalized() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        assertFalse(executor.isDone(pid));
    }

    function test_isDoneTrueAfterAllGaugesExecuted() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges(address(gauge1));
        executor.executeGaugeVote(pid, gauges);

        assertTrue(executor.isDone(pid));
    }

    function test_isDoneFalseAfterPartialExecution() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges2(address(gauge1), address(gauge2)), _getWeights2(6000, 4000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges(address(gauge1));
        executor.executeGaugeVote(pid, gauges);

        assertFalse(executor.isDone(pid));
        assertEq(executor.submittedGaugeCount(pid), 1);
        assertEq(executor.submittedWeight(pid), 6000);
    }

    // ========== Multi-batch with padding ==========

    function test_multiBatchPadsOnLastBatch() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 500, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges3(address(gauge1), address(gauge2), address(gauge3)), _getWeights3(5000, 3000, 2000));
        _vote(bob, _getGauges3(address(gauge1), address(gauge2), address(gauge3)), _getWeights3(4000, 4000, 2000));

        _finalizeProposal(pid);

        assertEq(platform.getGaugeCount(pid), 3);

        executor.executeGaugeVote(pid, _getGauges(address(gauge1)));
        assertEq(executor.submittedGaugeCount(pid), 1);
        assertFalse(executor.isDone(pid));

        executor.executeGaugeVote(pid, _getGauges(address(gauge2)));
        assertEq(executor.submittedGaugeCount(pid), 2);
        assertFalse(executor.isDone(pid));

        executor.executeGaugeVote(pid, _getGauges(address(gauge3)));
        assertEq(executor.submittedGaugeCount(pid), 3);
        assertEq(executor.submittedWeight(pid), 10000);
        assertTrue(executor.isDone(pid));

        (, uint256[] memory w) = voteDelegate.getLastCall();
        assertEq(w[0] + executor.submittedWeight(pid) - w[0], 10000);
    }

    function test_multiBatchWithZeroWeightGaugesMixedIn() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges2(address(gauge1), address(gauge2)), _getWeights2(6000, 4000));
        _finalizeProposal(pid);

        assertEq(platform.getGaugeCount(pid), 2);

        executor.executeGaugeVote(pid, _getGauges(address(gauge1)));
        assertEq(executor.submittedGaugeCount(pid), 1);
        assertFalse(executor.isDone(pid));

        address[] memory batch2 = new address[](2);
        batch2[0] = address(gauge3);
        batch2[1] = address(gauge2);
        executor.executeGaugeVote(pid, batch2);

        assertEq(executor.submittedGaugeCount(pid), 2);
        assertEq(executor.submittedWeight(pid), 10000);
        assertTrue(executor.isDone(pid));

        (, uint256[] memory w) = voteDelegate.getLastCall();
        assertEq(w[0], 0);
        assertEq(w[1], 4000);
    }

    // ========== State tracking ==========

    function test_submittedWeightTracksAcrossBatches() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges3(address(gauge1), address(gauge2), address(gauge3)), _getWeights3(5000, 3000, 2000));
        _finalizeProposal(pid);

        assertEq(executor.submittedGaugeCount(pid), 0);
        assertEq(executor.submittedWeight(pid), 0);

        executor.executeGaugeVote(pid, _getGauges(address(gauge1)));
        assertEq(executor.submittedGaugeCount(pid), 1);
        assertEq(executor.submittedWeight(pid), 5000);

        executor.executeGaugeVote(pid, _getGauges(address(gauge2)));
        assertEq(executor.submittedGaugeCount(pid), 2);
        assertEq(executor.submittedWeight(pid), 8000);

        executor.executeGaugeVote(pid, _getGauges(address(gauge3)));
        assertEq(executor.submittedGaugeCount(pid), 3);
        assertEq(executor.submittedWeight(pid), 10000);
    }

    // ========== Event ==========

    function test_gaugeVoteExecutedEvent() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges(address(gauge1));
        vm.expectEmit(true, false, false, false);
        emit CurveGaugeExecutor.GaugeVoteExecuted(pid, gauges, _getWeights(10000));
        executor.executeGaugeVote(pid, gauges);
    }
}