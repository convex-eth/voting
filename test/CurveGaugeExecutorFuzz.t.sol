// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/CurveGaugeExecutor.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/Delegation.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/SurrogateRegistry.sol";
import "./mocks/MockGauges.sol";
import "./mocks/MockVlCVX.sol";
import "./mocks/MockVoteDelegateExtension.sol";

contract CurveGaugeExecutorFuzzTest is Test {
    uint256 internal constant WEEK = 86400 * 7;
    uint256 internal constant WD = 1e17;

    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;
    CurveGaugeRegistry internal gaugeRegistry;
    SurrogateRegistry internal surrogateRegistry;
    GaugeVotePlatform internal platform;
    CurveGaugeExecutor internal executor;
    MockVoteDelegateExtension internal voteDelegate;

    MockCurveGauge[6] internal gauges;

    address internal alice = makeAddr("alice");
    address internal operator = makeAddr("operator");

    function setUp() public {
        vm.warp(WEEK * 2);

        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));

        address gaugeController = address(new MockGaugeController());
        vm.etch(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB, gaugeController.code);

        gaugeRegistry = new CurveGaugeRegistry();
        surrogateRegistry = new SurrogateRegistry();
        platform = new GaugeVotePlatform(
            address(this), address(mockVlCVX), address(gaugeRegistry), address(surrogateRegistry), address(delegation)
        );

        voteDelegate = new MockVoteDelegateExtension();
        executor = new CurveGaugeExecutor(address(platform), address(voteDelegate));
        platform.setOperator(operator, true);

        for (uint256 i = 0; i < gauges.length; ++i) {
            gauges[i] = new MockCurveGauge();
            MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauges[i]), 1000);
            gaugeRegistry.setGauge(address(gauges[i]));
        }
    }

    function testFuzz_generatedBatchesPreserveExecutorAccounting(
        uint256 weightSeedA,
        uint256 weightSeedB,
        uint256 weightSeedC,
        uint256 orderSeed,
        uint8 cutSeedA,
        uint8 cutSeedB
    ) public {
        uint256[] memory voteWeights = _fourPositiveWeights(weightSeedA, weightSeedB, weightSeedC);
        uint256 pid = _createFinalizedFourGaugeProposal(voteWeights);

        address[] memory executionOrder = _permutedExecutionOrder(orderSeed);
        uint256 cutA = bound(uint256(cutSeedA), 1, executionOrder.length - 2);
        uint256 cutB = bound(uint256(cutSeedB), cutA + 1, executionOrder.length - 1);

        uint256 expectedPositiveCount;
        uint256 expectedSubmittedWeight;

        (expectedPositiveCount, expectedSubmittedWeight) = _executeAndCheckBatch(
            pid, _slice(executionOrder, 0, cutA), voteWeights, expectedPositiveCount, expectedSubmittedWeight
        );
        (expectedPositiveCount, expectedSubmittedWeight) = _executeAndCheckBatch(
            pid, _slice(executionOrder, cutA, cutB - cutA), voteWeights, expectedPositiveCount, expectedSubmittedWeight
        );
        (expectedPositiveCount, expectedSubmittedWeight) = _executeAndCheckBatch(
            pid,
            _slice(executionOrder, cutB, executionOrder.length - cutB),
            voteWeights,
            expectedPositiveCount,
            expectedSubmittedWeight
        );

        assertEq(expectedPositiveCount, 4);
        assertEq(executor.submittedGaugeCount(pid), 4);
        assertEq(executor.submittedWeight(pid), 10_000);
        assertTrue(executor.isDone(pid));

        uint256 oldCount = executor.submittedGaugeCount(pid);
        uint256 oldWeight = executor.submittedWeight(pid);
        vm.expectRevert(CurveGaugeExecutor.GaugeAlreadySubmitted.selector);
        executor.executeGaugeVote(pid, _single(executionOrder[orderSeed % executionOrder.length]));
        assertEq(executor.submittedGaugeCount(pid), oldCount);
        assertEq(executor.submittedWeight(pid), oldWeight);
    }

    function testFuzz_duplicateGeneratedBatchRevertsWithoutStateCorruption(
        uint256 weightSeedA,
        uint256 weightSeedB,
        uint256 weightSeedC,
        uint8 duplicateSeed,
        bool duplicateZeroWeightGauge
    ) public {
        uint256[] memory voteWeights = _fourPositiveWeights(weightSeedA, weightSeedB, weightSeedC);
        uint256 pid = _createFinalizedFourGaugeProposal(voteWeights);

        uint256 duplicateIndex =
            duplicateZeroWeightGauge ? 4 + (uint256(duplicateSeed) % 2) : uint256(duplicateSeed) % 4;
        address duplicateGauge = address(gauges[duplicateIndex]);

        address[] memory batch = new address[](3);
        batch[0] = duplicateGauge;
        batch[1] = address(gauges[(duplicateIndex + 1) % gauges.length]);
        batch[2] = duplicateGauge;

        vm.expectRevert(CurveGaugeExecutor.GaugeAlreadySubmitted.selector);
        executor.executeGaugeVote(pid, batch);

        assertEq(voteDelegate.callCount(), 0);
        assertEq(executor.submittedGaugeCount(pid), 0);
        assertEq(executor.submittedWeight(pid), 0);
        assertFalse(executor.submittedGauge(pid, duplicateGauge));
        assertFalse(executor.isDone(pid));
    }

    function _executeAndCheckBatch(
        uint256 pid,
        address[] memory batch,
        uint256[] memory voteWeights,
        uint256 expectedPositiveCount,
        uint256 expectedSubmittedWeight
    ) internal returns (uint256 newPositiveCount, uint256 newSubmittedWeight) {
        executor.executeGaugeVote(pid, batch);

        (address[] memory executedGauges, uint256[] memory executedWeights) = voteDelegate.getLastCall();
        assertEq(executedGauges.length, batch.length);
        assertEq(executedWeights.length, batch.length);

        newPositiveCount = expectedPositiveCount;
        newSubmittedWeight = expectedSubmittedWeight;
        uint256 batchWeightSum;
        for (uint256 i = 0; i < batch.length; ++i) {
            assertEq(executedGauges[i], batch[i]);
            assertTrue(executor.submittedGauge(pid, batch[i]));

            uint256 gaugeIndex = _gaugeIndex(batch[i]);
            if (gaugeIndex < 4) {
                ++newPositiveCount;
                if (newPositiveCount >= 4) {
                    uint256 paddedWeight = 10_000 - newSubmittedWeight;
                    assertEq(executedWeights[i], paddedWeight);
                    newSubmittedWeight = 10_000;
                    batchWeightSum += paddedWeight;
                } else {
                    assertEq(executedWeights[i], voteWeights[gaugeIndex]);
                    newSubmittedWeight += voteWeights[gaugeIndex];
                    batchWeightSum += voteWeights[gaugeIndex];
                }
            } else {
                assertEq(executedWeights[i], 0);
            }
        }

        assertLe(batchWeightSum, 10_000);
        assertLe(executor.submittedWeight(pid), 10_000);
        assertEq(executor.submittedGaugeCount(pid), newPositiveCount);
        assertEq(executor.submittedWeight(pid), newSubmittedWeight);
        assertEq(executor.isDone(pid), newPositiveCount == 4);
    }

    function _createFinalizedFourGaugeProposal(uint256[] memory voteWeights) internal returns (uint256 pid) {
        mockVlCVX.mockLock(alice, 100 * WD, 100 * WD);
        _warpToNextEpoch();
        pid = _createProposal();

        address[] memory voteGauges = new address[](4);
        for (uint256 i = 0; i < voteGauges.length; ++i) {
            voteGauges[i] = address(gauges[i]);
        }

        vm.prank(alice);
        platform.vote(alice, voteGauges, voteWeights);
        _finalizeProposal(pid);
    }

    function _fourPositiveWeights(uint256 seedA, uint256 seedB, uint256 seedC)
        internal
        pure
        returns (uint256[] memory weights)
    {
        weights = new uint256[](4);
        weights[0] = bound(seedA, 1, 9_997);
        weights[1] = bound(seedB, 1, 9_998 - weights[0]);
        weights[2] = bound(seedC, 1, 9_999 - weights[0] - weights[1]);
        weights[3] = 10_000 - weights[0] - weights[1] - weights[2];
    }

    function _permutedExecutionOrder(uint256 seed) internal view returns (address[] memory order) {
        order = new address[](6);
        for (uint256 i = 0; i < order.length; ++i) {
            order[i] = address(gauges[i]);
        }

        for (uint256 i = 0; i < order.length; ++i) {
            uint256 j = i + uint256(keccak256(abi.encode(seed, i))) % (order.length - i);
            address tmp = order[i];
            order[i] = order[j];
            order[j] = tmp;
        }
    }

    function _gaugeIndex(address gauge) internal view returns (uint256) {
        for (uint256 i = 0; i < gauges.length; ++i) {
            if (gauge == address(gauges[i])) return i;
        }
        revert("unknown gauge");
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

    function _slice(address[] memory values, uint256 start, uint256 len) internal pure returns (address[] memory out) {
        out = new address[](len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = values[start + i];
        }
    }

    function _single(address gauge) internal pure returns (address[] memory gauges_) {
        gauges_ = new address[](1);
        gauges_[0] = gauge;
    }
}
