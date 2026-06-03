// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";
import {FxGaugeRegistry} from "../../src/FxGaugeRegistry.sol";
import {FxGaugeExecutor} from "../../src/FxGaugeExecutor.sol";
import {GaugeVotePlatform} from "../../src/GaugeVotePlatform.sol";
import {IFxGaugeVoter} from "../../src/interface/IFxGaugeVoter.sol";

contract FxGaugeExecutorForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function _deployPlatform(address g1, address g2)
        internal
        returns (GaugeVotePlatform platform)
    {
        address[] memory initial = arr(g1, g2);
        FxGaugeRegistry registry = new FxGaugeRegistry("Fx Gauge Registry", address(this), initial);
        (,, platform) = deployGaugePlatform(address(registry));
    }

    function _finalizedFxGaugeVote()
        internal
        returns (GaugeVotePlatform platform, uint256 pid, address g1, address g2)
    {
        skipIfGaugeEpochCannotFinalize(1 days, 10 minutes);
        (address holder,,) = liveVlCvxHolder();
        (g1, g2) = twoLiveFxGauges();
        platform = _deployPlatform(g1, g2);

        pid = createGaugeProposal(platform, 1 days);
        voteGaugeAsHolder(platform, holder, arr(g1, g2), weights(6000, 4000));
        finalizeGaugeProposal(platform, pid);
    }

    function _mockFxGaugeVoteCall() internal {
        vm.mockCall(
            FX_GAUGE_VOTER,
            abi.encodeWithSelector(IFxGaugeVoter.voteGaugeWeight.selector),
            bytes("")
        );
    }

    function testFork_partialFxGaugeBatchDoesNotMarkDone() public {
        (GaugeVotePlatform platform, uint256 pid, address g1,) = _finalizedFxGaugeVote();
        FxGaugeExecutor executor = new FxGaugeExecutor("Fx Gauge Executor", address(platform), address(this));
        _mockFxGaugeVoteCall();

        executor.executeGaugeVote(pid, arr(g1));

        uint256 expectedWeight = platform.gaugeTotal(pid, g1) * WEIGHT_BPS / platform.voteTotals(pid);
        assertEq(executor.submittedGaugeCount(pid), 1);
        assertEq(executor.submittedWeight(pid), expectedWeight);
        assertFalse(executor.isDone(pid));
    }

    function testFork_duplicateFxGaugeBatchReverts() public {
        (GaugeVotePlatform platform, uint256 pid, address g1,) = _finalizedFxGaugeVote();
        FxGaugeExecutor executor = new FxGaugeExecutor("Fx Gauge Executor", address(platform), address(this));
        _mockFxGaugeVoteCall();

        vm.expectRevert();
        executor.executeGaugeVote(pid, arr(g1, g1));

        assertEq(platform.getGaugeCount(pid), 2);
        assertEq(executor.submittedGaugeCount(pid), 0);
        assertEq(executor.submittedWeight(pid), 0);
        assertFalse(executor.isDone(pid));
    }

    function testFork_alreadySubmittedFxGaugeBatchReverts() public {
        (GaugeVotePlatform platform, uint256 pid, address g1,) = _finalizedFxGaugeVote();
        FxGaugeExecutor executor = new FxGaugeExecutor("Fx Gauge Executor", address(platform), address(this));
        _mockFxGaugeVoteCall();

        executor.executeGaugeVote(pid, arr(g1));

        vm.expectRevert();
        executor.executeGaugeVote(pid, arr(g1));

        uint256 expectedWeight = platform.gaugeTotal(pid, g1) * WEIGHT_BPS / platform.voteTotals(pid);
        assertEq(platform.getGaugeCount(pid), 2);
        assertEq(executor.submittedGaugeCount(pid), 1);
        assertEq(executor.submittedWeight(pid), expectedWeight);
        assertFalse(executor.isDone(pid));
    }

    function testFork_tinyFxGaugeWeightDoesNotBlockCompletion() public {
        skipIfGaugeEpochCannotFinalize(1 days, 10 minutes);
        (address holder,,) = liveVlCvxHolder();
        (address g1, address g2) = twoLiveFxGauges();
        GaugeVotePlatform platform = _deployPlatform(g1, g2);

        uint256 pid = createGaugeProposal(platform, 1 days);
        voteGaugeAsHolder(platform, holder, arr(g1, g2), weights(1, 9999));
        finalizeGaugeProposal(platform, pid);

        FxGaugeExecutor executor = new FxGaugeExecutor("Fx Gauge Executor", address(platform), address(this));
        _mockFxGaugeVoteCall();
        executor.executeGaugeVote(pid, arr(g1, g2));

        uint256 tinyOutput = platform.gaugeTotal(pid, g1) * WEIGHT_BPS / platform.voteTotals(pid);
        assertEq(platform.getGaugeCount(pid), 2);
        assertEq(tinyOutput, 0);
        assertGt(platform.gaugeTotal(pid, g1), 0);
        assertEq(executor.submittedGaugeCount(pid), 2);
        assertEq(executor.submittedWeight(pid), WEIGHT_BPS);
        assertTrue(executor.isDone(pid));
    }

    function testFork_liveFxAdapterRevertRollsBackLocalState() public {
        (GaugeVotePlatform platform, uint256 pid, address g1,) = _finalizedFxGaugeVote();
        FxGaugeExecutor executor = new FxGaugeExecutor("Fx Gauge Executor", address(platform), address(this));

        vm.expectRevert();
        executor.executeGaugeVote(pid, arr(g1));

        assertEq(executor.submittedGaugeCount(pid), 0);
        assertEq(executor.submittedWeight(pid), 0);
        assertFalse(executor.isDone(pid));
    }
}
