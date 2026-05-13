// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";
import {CurveGaugeRegistry} from "../../src/CurveGaugeRegistry.sol";
import {CurveGaugeExecutor} from "../../src/CurveGaugeExecutor.sol";
import {GaugeVotePlatform} from "../../src/GaugeVotePlatform.sol";
import {MockVoteDelegationExtension} from "../mocks/MockVoteDelegationExtension.sol";

contract CurveGaugeExecutorForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function _deployPlatform(address g1, address g2)
        internal
        returns (GaugeVotePlatform platform)
    {
        address[] memory initial = arr(g1, g2);
        CurveGaugeRegistry registry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), initial);
        (,, platform) = deployGaugePlatform(address(registry));
    }

    function _finalizedCurveGaugeVote()
        internal
        returns (GaugeVotePlatform platform, uint256 pid, address g1, address g2)
    {
        skipIfGaugeEpochCannotFinalize(1 days, 10 minutes);
        (address holder,,) = liveVlCvxHolder();
        (g1, g2) = twoLiveCurveGauges();
        platform = _deployPlatform(g1, g2);

        pid = createGaugeProposal(platform, 1 days);
        voteGaugeAsHolder(platform, holder, arr(g1, g2), weights(6000, 4000));
        finalizeGaugeProposal(platform, pid);
    }

    function testFork_getGaugeEntryOutputsDuplicateFreeTotals() public {
        skipIfGaugeEpochCannotFinalize(1 days, 10 minutes);
        (address holder,, uint256 holderWeight) = liveVlCvxHolder();
        (address g1, address g2) = twoLiveCurveGauges();
        GaugeVotePlatform platform = _deployPlatform(g1, g2);

        uint256 pid = createGaugeProposal(platform, 1 days);
        voteGaugeAsHolder(platform, holder, arr(g1, g1), weights(6000, 4000));

        assertEq(platform.getGaugeCount(pid), 1);
        (address gauge, uint256 totalWeight) = platform.getGaugeEntry(pid, 0);
        assertEq(gauge, g1);
        assertEq(totalWeight, holderWeight * 6000 / WEIGHT_BPS + holderWeight * 4000 / WEIGHT_BPS);
    }

    function testFork_partialCurveGaugeBatchDoesNotMarkDone() public {
        (GaugeVotePlatform platform, uint256 pid, address g1,) = _finalizedCurveGaugeVote();
        MockVoteDelegationExtension voteDelegate = new MockVoteDelegationExtension();
        CurveGaugeExecutor executor = new CurveGaugeExecutor("Curve Gauge Executor", address(platform), address(voteDelegate));

        executor.executeGaugeVote(pid, arr(g1));

        uint256 expectedWeight = platform.gaugeTotal(pid, g1) * WEIGHT_BPS / platform.voteTotals(pid);
        assertEq(executor.submittedGaugeCount(pid), 1);
        assertEq(executor.submittedWeight(pid), expectedWeight);
        assertFalse(executor.isDone(pid));
        assertEq(voteDelegate.gaugeCallCount(), 1);
        (, uint256[] memory w0) = voteDelegate.getLastCall();
        assertEq(w0[0], expectedWeight);
    }

    function testFork_duplicateCurveGaugeBatchReverts() public {
        (GaugeVotePlatform platform, uint256 pid, address g1,) = _finalizedCurveGaugeVote();
        MockVoteDelegationExtension voteDelegate = new MockVoteDelegationExtension();
        CurveGaugeExecutor executor = new CurveGaugeExecutor("Curve Gauge Executor", address(platform), address(voteDelegate));

        vm.expectRevert();
        executor.executeGaugeVote(pid, arr(g1, g1));

        assertEq(platform.getGaugeCount(pid), 2);
        assertEq(executor.submittedGaugeCount(pid), 0);
        assertEq(executor.submittedWeight(pid), 0);
        assertFalse(executor.isDone(pid));
        assertEq(voteDelegate.gaugeCallCount(), 0);
    }

    function testFork_alreadySubmittedCurveGaugeBatchReverts() public {
        (GaugeVotePlatform platform, uint256 pid, address g1,) = _finalizedCurveGaugeVote();
        MockVoteDelegationExtension voteDelegate = new MockVoteDelegationExtension();
        CurveGaugeExecutor executor = new CurveGaugeExecutor("Curve Gauge Executor", address(platform), address(voteDelegate));

        executor.executeGaugeVote(pid, arr(g1));

        vm.expectRevert();
        executor.executeGaugeVote(pid, arr(g1));

        uint256 expectedWeight = platform.gaugeTotal(pid, g1) * WEIGHT_BPS / platform.voteTotals(pid);
        assertEq(platform.getGaugeCount(pid), 2);
        assertEq(executor.submittedGaugeCount(pid), 1);
        assertEq(executor.submittedWeight(pid), expectedWeight);
        assertFalse(executor.isDone(pid));
        assertEq(voteDelegate.gaugeCallCount(), 1);
    }

    function testFork_tinyCurveGaugeWeightDoesNotBlockCompletion() public {
        skipIfGaugeEpochCannotFinalize(1 days, 10 minutes);
        (address holder,,) = liveVlCvxHolder();
        (address g1, address g2) = twoLiveCurveGauges();
        GaugeVotePlatform platform = _deployPlatform(g1, g2);

        uint256 pid = createGaugeProposal(platform, 1 days);
        voteGaugeAsHolder(platform, holder, arr(g1, g2), weights(1, 9999));
        finalizeGaugeProposal(platform, pid);

        MockVoteDelegationExtension voteDelegate = new MockVoteDelegationExtension();
        CurveGaugeExecutor executor = new CurveGaugeExecutor("Curve Gauge Executor", address(platform), address(voteDelegate));
        executor.executeGaugeVote(pid, arr(g1, g2));

        uint256 tinyOutput = platform.gaugeTotal(pid, g1) * WEIGHT_BPS / platform.voteTotals(pid);
        uint256 largeOutput = platform.gaugeTotal(pid, g2) * WEIGHT_BPS / platform.voteTotals(pid);

        assertEq(platform.getGaugeCount(pid), 2);
        assertEq(tinyOutput, 0);
        assertGt(platform.gaugeTotal(pid, g1), 0);
        assertEq(executor.submittedGaugeCount(pid), 2);
        assertEq(executor.submittedWeight(pid), WEIGHT_BPS);
        assertTrue(executor.isDone(pid));
        (, uint256[] memory tw) = voteDelegate.getLastCall();
        assertEq(tw[0], 0);
        assertEq(tw[1], largeOutput + (WEIGHT_BPS - largeOutput));
    }

    function testFork_liveCurveAdapterRevertRollsBackLocalState() public {
        (GaugeVotePlatform platform, uint256 pid, address g1,) = _finalizedCurveGaugeVote();
        CurveGaugeExecutor executor = new CurveGaugeExecutor("Curve Gauge Executor", address(platform), VOTE_DELEGATE_EXTENSION);

        vm.expectRevert();
        executor.executeGaugeVote(pid, arr(g1));

        assertEq(executor.submittedGaugeCount(pid), 0);
        assertEq(executor.submittedWeight(pid), 0);
        assertFalse(executor.isDone(pid));
    }
}
