// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/SurrogateRegistry.sol";
import "../src/Delegation.sol";
import "../src/FxGaugeExecutor.sol";
import "../src/interface/IFxGaugeVoter.sol";
import "./mocks/MockVlCVX.sol";
import "./mocks/MockGauges.sol";

contract FxGaugeExecutorTest is Test {
    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;
    CurveGaugeRegistry internal gaugeRegistry;
    SurrogateRegistry internal surrogateRegistry;
    GaugeVotePlatform internal platform;
    FxGaugeExecutor internal executor;
    MockFxGaugeVoter internal gaugeVoter;

    MockCurveGauge internal gauge1;
    MockCurveGauge internal gauge2;
    MockCurveGauge internal gauge3;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal operator = makeAddr("operator");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WD = 1e17;

    address constant FX_GAUGE_VOTER = 0xAffe966B27ba3E4Ebb8A0eC124C7b7019CC762f8;

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

        gaugeVoter = new MockFxGaugeVoter();
        vm.etch(FX_GAUGE_VOTER, address(gaugeVoter).code);

        executor = new FxGaugeExecutor(address(platform));

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
        uint256 currentEpoch = (block.timestamp / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);
    }

    function _createProposal() internal returns (uint256) {
        uint256 startTime = block.timestamp + 1 days;
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

    function _mockVoter() internal pure returns (MockFxGaugeVoter) {
        return MockFxGaugeVoter(FX_GAUGE_VOTER);
    }

    function test_singleGaugeFullWeight() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges(address(gauge1));
        executor.executeGaugeVote(pid, gauges);

        (address[] memory g, uint256[] memory w) = _mockVoter().getLastCall();
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

        (address[] memory g, uint256[] memory w) = _mockVoter().getLastCall();
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

        executor.executeGaugeVote(pid, _getGauges2(address(gauge1), address(gauge2)));

        (, uint256[] memory w) = _mockVoter().getLastCall();
        assertEq(w[0], expectedG1Weight);
        assertEq(w[0] + w[1], 10000);
    }

    function test_revertIfNotFinalized() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        (, uint256 endTime,) = platform.proposals(pid);
        vm.warp(endTime);

        address[] memory gauges = _getGauges(address(gauge1));
        vm.expectRevert(FxGaugeExecutor.NotFinalized.selector);
        executor.executeGaugeVote(pid, gauges);
    }

    function test_revertIfNotLatestProposal() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid0 = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid0);

        vm.warp(block.timestamp + 1 days);
        _lockAndDelegate(bob, 500, address(0));
        _warpToNextEpoch();

        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        platform.createProposal(startTime, endTime);
        uint256 pid1 = platform.proposalCount() - 1;
        vm.warp(startTime);
        _vote(bob, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid1);

        vm.expectRevert(FxGaugeExecutor.NotLatestProposal.selector);
        executor.executeGaugeVote(pid0, _getGauges(address(gauge1)));
    }

    function test_revertIfEpochExpired() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        _warpToNextEpoch();

        vm.expectRevert(FxGaugeExecutor.EpochExpired.selector);
        executor.executeGaugeVote(pid, _getGauges(address(gauge1)));
    }

    function test_anyoneCanExecute() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges(address(gauge1));
        vm.prank(bob);
        executor.executeGaugeVote(pid, gauges);

        assertEq(_mockVoter().callCount(), 1);
    }

    function test_isDoneTrueAfterExecution() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges(address(gauge1));
        executor.executeGaugeVote(pid, gauges);

        assertTrue(executor.isDone(pid));
    }

    function test_revertDuplicatePositiveGaugeInSameBatch() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges2(address(gauge1), address(gauge2)), _getWeights2(6000, 4000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges2(address(gauge1), address(gauge1));
        vm.expectRevert(FxGaugeExecutor.GaugeAlreadySubmitted.selector);
        executor.executeGaugeVote(pid, gauges);
    }

    function test_revertPositiveGaugeRepeatedAcrossBatches() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges2(address(gauge1), address(gauge2)), _getWeights2(6000, 4000));
        _finalizeProposal(pid);

        executor.executeGaugeVote(pid, _getGauges(address(gauge1)));

        vm.expectRevert(FxGaugeExecutor.GaugeAlreadySubmitted.selector);
        executor.executeGaugeVote(pid, _getGauges(address(gauge1)));

        assertFalse(executor.isDone(pid));
        assertEq(executor.submittedGaugeCount(pid), 1);
        assertEq(executor.submittedWeight(pid), 6000);
    }

    function test_zeroWeightGaugeDoesNotAdvanceCompletion() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges2(address(gauge1), address(gauge2)), _getWeights2(6000, 4000));
        _finalizeProposal(pid);

        executor.executeGaugeVote(pid, _getGauges(address(gauge3)));

        assertFalse(executor.isDone(pid));
        assertEq(executor.submittedGaugeCount(pid), 0);
        assertEq(executor.submittedWeight(pid), 0);
    }

    function test_gaugeVoteExecutedEvent() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _finalizeProposal(pid);

        address[] memory gauges = _getGauges(address(gauge1));
        vm.expectEmit(true, false, false, false);
        emit FxGaugeExecutor.GaugeVoteExecuted(pid, gauges, _getWeights(10000));
        executor.executeGaugeVote(pid, gauges);
    }
}

contract MockFxGaugeVoter is IFxGaugeVoter {
    address[] public lastGauges;
    uint256[] public lastWeights;
    uint256 public callCount;

    function voteGaugeWeight(address, address[] calldata _gauge, uint256[] calldata _weight) external {
        lastGauges = _gauge;
        lastWeights = _weight;
        callCount++;
    }

    function getLastCall() external view returns (address[] memory, uint256[] memory) {
        return (lastGauges, lastWeights);
    }
}
