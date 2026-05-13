// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";
import {CurveGaugeRegistry} from "../../src/CurveGaugeRegistry.sol";
import {CurveGaugeExecutor} from "../../src/CurveGaugeExecutor.sol";
import {FxGaugeRegistry} from "../../src/FxGaugeRegistry.sol";
import {FxGaugeExecutor} from "../../src/FxGaugeExecutor.sol";
import {CurveVoteExecutor} from "../../src/CurveVoteExecutor.sol";
import {ResupplyVoteExecutor, IResupplyStaker} from "../../src/ResupplyVoteExecutor.sol";
import {GaugeVotePlatform} from "../../src/GaugeVotePlatform.sol";
import {DaoVotePlatform} from "../../src/DaoVotePlatform.sol";
import {IvlCVX} from "../../src/interface/IvlCVX.sol";
import {IFxGaugeVoter} from "../../src/interface/IFxGaugeVoter.sol";

contract ForkRecordingVoteDelegate {
    address[] internal lastGauges;
    uint256[] internal lastWeights;

    function GaugeVote(address[] calldata gauges, uint256[] calldata voteWeights) external {
        delete lastGauges;
        delete lastWeights;
        for (uint256 i; i < gauges.length; i++) {
            lastGauges.push(gauges[i]);
            lastWeights.push(voteWeights[i]);
        }
    }

    function lastWeight(uint256 index) external view returns (uint256) {
        return lastWeights[index];
    }
}

contract ForkRecordingDaoVoteDelegate {
    uint256 public callCount;

    function DaoVoteWithWeights(uint256, uint256, uint256, bool) external returns (bool) {
        callCount++;
        return true;
    }
}

contract RegistryForkFuzzTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_curveRegistryRegistrationMatchesLiveValidity(uint256 seed) public {
        address[] memory candidates = curveGaugeCandidates();
        address gauge = candidates[bound(seed, 0, candidates.length - 1)];
        bool expected = _isLiveValidCurveGauge(gauge);
        CurveGaugeRegistry registry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), new address[](0));

        registry.setGauge(gauge);

        assertEq(registry.isRegisteredGauge(gauge), expected);
        assertEq(registry.gaugeLength(), expected ? 1 : 0);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_fxRegistryRegistrationMatchesLiveValidity(uint256 seed) public {
        address[] memory candidates = fxGaugeCandidates();
        address gauge = candidates[bound(seed, 0, candidates.length - 1)];
        bool expected = _isLiveValidFxGauge(gauge);
        FxGaugeRegistry registry = new FxGaugeRegistry("Fx Gauge Registry", address(this), new address[](0));

        registry.setGauge(gauge);

        assertEq(registry.isRegisteredGauge(gauge), expected);
        assertEq(registry.gaugeLength(), expected ? 1 : 0);
    }
}

contract GaugeExecutorForkFuzzTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function _curvePlatform(address g1, address g2) internal returns (GaugeVotePlatform platform) {
        CurveGaugeRegistry registry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), arr(g1, g2));
        (,, platform) = deployGaugePlatform(address(registry));
    }

    function _fxPlatform(address g1, address g2) internal returns (GaugeVotePlatform platform) {
        FxGaugeRegistry registry = new FxGaugeRegistry("Fx Gauge Registry", address(this), arr(g1, g2));
        (,, platform) = deployGaugePlatform(address(registry));
    }

    function _expectedSubmittedWeights(GaugeVotePlatform platform, uint256 pid, address g1, address g2)
        internal
        view
        returns (uint256 expectedA, uint256 expectedB)
    {
        uint256 totalVotes = platform.voteTotals(pid);
        expectedA = platform.gaugeTotal(pid, g1) * WEIGHT_BPS / totalVotes;
        expectedB = platform.gaugeTotal(pid, g2) * WEIGHT_BPS / totalVotes;
        uint256 rawSum = expectedA + expectedB;
        if (rawSum < WEIGHT_BPS) expectedB += WEIGHT_BPS - rawSum;
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_curveExecutorUniqueFullBatchPadsToBps(uint256 rawWeightA) public {
        skipIfGaugeEpochCannotFinalize(1 days, 10 minutes);
        uint256 weightA = bound(rawWeightA, 2, WEIGHT_BPS - 2);
        uint256 weightB = WEIGHT_BPS - weightA;
        (address holder,,) = liveVlCvxHolder();
        (address g1, address g2) = twoLiveCurveGauges();
        GaugeVotePlatform platform = _curvePlatform(g1, g2);

        uint256 pid = createGaugeProposal(platform, 1 days);
        voteGaugeAsHolder(platform, holder, arr(g1, g2), weights(weightA, weightB));
        finalizeGaugeProposal(platform, pid);

        ForkRecordingVoteDelegate voteDelegate = new ForkRecordingVoteDelegate();
        CurveGaugeExecutor executor = new CurveGaugeExecutor("Curve Gauge Executor", address(platform), address(voteDelegate));
        executor.executeGaugeVote(pid, arr(g1, g2));

        (uint256 expectedA, uint256 expectedB) = _expectedSubmittedWeights(platform, pid, g1, g2);
        assertEq(executor.submittedGaugeCount(pid), 2);
        assertEq(executor.submittedWeight(pid), WEIGHT_BPS);
        assertTrue(executor.isDone(pid));
        assertEq(voteDelegate.lastWeight(0), expectedA);
        assertEq(voteDelegate.lastWeight(1), expectedB);
        assertEq(voteDelegate.lastWeight(0) + voteDelegate.lastWeight(1), WEIGHT_BPS);
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_fxExecutorUniqueFullBatchPadsToBps(uint256 rawWeightA) public {
        skipIfGaugeEpochCannotFinalize(1 days, 10 minutes);
        uint256 weightA = bound(rawWeightA, 2, WEIGHT_BPS - 2);
        uint256 weightB = WEIGHT_BPS - weightA;
        (address holder,,) = liveVlCvxHolder();
        (address g1, address g2) = twoLiveFxGauges();
        GaugeVotePlatform platform = _fxPlatform(g1, g2);

        uint256 pid = createGaugeProposal(platform, 1 days);
        voteGaugeAsHolder(platform, holder, arr(g1, g2), weights(weightA, weightB));
        finalizeGaugeProposal(platform, pid);

        vm.mockCall(FX_GAUGE_VOTER, abi.encodeWithSelector(IFxGaugeVoter.voteGaugeWeight.selector), bytes(""));
        FxGaugeExecutor executor = new FxGaugeExecutor("Fx Gauge Executor", address(platform));
        executor.executeGaugeVote(pid, arr(g1, g2));

        assertEq(executor.submittedGaugeCount(pid), 2);
        assertEq(executor.submittedWeight(pid), WEIGHT_BPS);
        assertTrue(executor.isDone(pid));
    }
}

contract LazyDelegationForkFuzzTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_daoLiveWeightSplitTotalsRemainExact(uint256 rawYesWeight) public {
        uint256 yesWeight = bound(rawYesWeight, 0, WEIGHT_BPS);
        uint256 noWeight = WEIGHT_BPS - yesWeight;
        (address holder,, uint256 holderWeight) = liveVlCvxHolder();
        (,, DaoVotePlatform platform) = deployDaoPlatform();

        uint256 pid = createDaoProposal(platform, 1 days, 400_001);
        voteDaoAsHolder(platform, holder, yesWeight, noWeight);

        uint256 expectedYes = holderWeight * yesWeight / WEIGHT_BPS;
        assertEq(platform.voteTotals(pid), holderWeight);
        assertEq(platform.getYes(pid), expectedYes);
        assertEq(platform.getNo(pid), holderWeight - expectedYes);
        assertEq(platform.getYes(pid) + platform.getNo(pid), platform.voteTotals(pid));
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_gaugeLiveWeightSplitDustIsBounded(uint256 rawWeightA) public {
        uint256 weightA = bound(rawWeightA, 1, WEIGHT_BPS - 1);
        uint256 weightB = WEIGHT_BPS - weightA;
        (address holder,, uint256 holderWeight) = liveVlCvxHolder();
        (address g1, address g2) = twoLiveCurveGauges();
        CurveGaugeRegistry registry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), arr(g1, g2));
        (,, GaugeVotePlatform platform) = deployGaugePlatform(address(registry));

        uint256 pid = createGaugeProposal(platform, 1 days);
        voteGaugeAsHolder(platform, holder, arr(g1, g2), weights(weightA, weightB));

        uint256 gaugeSum = platform.gaugeTotal(pid, g1) + platform.gaugeTotal(pid, g2);
        assertEq(platform.voteTotals(pid), holderWeight);
        assertLe(gaugeSum, holderWeight);
        assertLt(holderWeight - gaugeSum, 2);
    }
}

contract DaoExecutorForkFuzzTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function _liveVotedFinalizedProposal(uint256 yesWeight)
        internal
        returns (DaoVotePlatform platform, uint256 pid, uint256 participationBps)
    {
        uint256 noWeight = WEIGHT_BPS - yesWeight;
        (address holder,, uint256 holderWeight) = liveVlCvxHolder();
        (,, platform) = deployDaoPlatform();

        pid = createDaoProposal(platform, 1 days, 500_001);
        voteDaoAsHolder(platform, holder, yesWeight, noWeight);
        finalizeDaoProposal(platform, pid);

        (,, uint48 epoch,,) = platform.proposals(pid);
        uint256 totalSupply = IvlCVX(VLCVX).totalSupplyAtEpoch(epoch);
        participationBps = holderWeight * WEIGHT_BPS / totalSupply;
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_curveDaoExecutorQuorumBoundaryUsesLiveSupply(uint256 rawYesWeight, uint256 rawQuorum) public {
        uint256 yesWeight = bound(rawYesWeight, 0, WEIGHT_BPS);
        uint256 quorum = bound(rawQuorum, 0, WEIGHT_BPS);
        (DaoVotePlatform platform, uint256 pid, uint256 participationBps) = _liveVotedFinalizedProposal(yesWeight);
        ForkRecordingDaoVoteDelegate voteDelegate = new ForkRecordingDaoVoteDelegate();
        CurveVoteExecutor executor = new CurveVoteExecutor("Curve Vote Executor", address(this), address(platform), address(voteDelegate), quorum);

        if (quorum > participationBps) {
            vm.expectRevert(CurveVoteExecutor.QuorumNotMet.selector);
            executor.executeDaoVote(pid);
            assertFalse(executor.isDone(pid));
            assertEq(voteDelegate.callCount(), 0);
        } else {
            executor.executeDaoVote(pid);
            assertTrue(executor.isDone(pid));
            assertEq(voteDelegate.callCount(), 1);
        }
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_resupplyDaoExecutorQuorumBoundaryUsesLiveSupply(uint256 rawYesWeight, uint256 rawQuorum) public {
        uint256 yesWeight = bound(rawYesWeight, 0, WEIGHT_BPS);
        uint256 quorum = bound(rawQuorum, 0, WEIGHT_BPS);
        (DaoVotePlatform platform, uint256 pid, uint256 participationBps) = _liveVotedFinalizedProposal(yesWeight);
        ResupplyVoteExecutor executor = new ResupplyVoteExecutor("Resupply Vote Executor", address(this), address(platform), quorum);

        if (quorum > participationBps) {
            vm.expectRevert(ResupplyVoteExecutor.QuorumNotMet.selector);
            executor.executeDaoVote(pid);
            assertFalse(executor.isDone(pid));
        } else {
            vm.mockCall(
                RESUPPLY_PERMA_STAKER,
                abi.encodeWithSelector(IResupplyStaker.safeExecute.selector),
                abi.encode(bytes(""))
            );
            executor.executeDaoVote(pid);
            assertTrue(executor.isDone(pid));
        }
    }
}
