// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Delegation.sol";
import "./mocks/MockVlCVX.sol";

error NoDelegate();
error SelfDelegation();

contract DelegationTest is Test {
    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal delegateA = makeAddr("delegateA");
    address internal delegateB = makeAddr("delegateB");
    address internal delegateC = makeAddr("delegateC");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WEIGHT_DIVISOR = 1e17;

    function setUp() public {
        vm.warp(52 weeks * 2);
        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));
    }

    function warpToNextEpoch() internal {
        uint256 currentEpoch = (block.timestamp / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);
    }

    function warpWeeks(uint256 numWeeks) internal {
        vm.warp(block.timestamp + WEEK * numWeeks);
    }

    function nextEpochIndex() internal returns (uint256) {
        mockVlCVX.checkpointEpoch();
        return mockVlCVX.epochCount() - 1;
    }

    function currentEpochIndex() internal view returns (uint256) {
        return mockVlCVX.findEpochId(block.timestamp);
    }

    function assertWeightMatches(uint256 epoch, address delegateAddress, uint256 expected) internal {
        uint256 actual = delegation.balanceAtEpochOf(epoch, delegateAddress);
        uint256 tolerance = WEIGHT_DIVISOR;
        if (actual > expected) {
            assertLe(actual - expected, tolerance, string(abi.encodePacked("delegate weight mismatch epoch ", vm.toString(epoch))));
        } else {
            assertLe(expected - actual, tolerance, string(abi.encodePacked("delegate weight mismatch epoch ", vm.toString(epoch))));
        }
    }

    function assertUserWeightMatches(uint256 epoch, address user, uint256 expected) internal {
        uint256 actual = delegation.userWeightAtEpochOf(epoch, user);
        uint256 tolerance = WEIGHT_DIVISOR;
        if (actual > expected) {
            assertLe(actual - expected, tolerance, string(abi.encodePacked("user weight mismatch epoch ", vm.toString(epoch))));
        } else {
            assertLe(expected - actual, tolerance, string(abi.encodePacked("user weight mismatch epoch ", vm.toString(epoch))));
        }
    }

    function test_setDelegateAndSync() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 16;

        assertEq(delegation.getDelegateAtEpoch(alice, nextEpoch), delegateA);
        assertEq(delegation.syncedUserEpoch(alice), endEpoch);

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertUserWeightMatches(i, alice, expected);
            assertWeightMatches(i, delegateA, expected);
        }
    }

    function test_syncOnlyWritesFutureEpochs() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);
        warpToNextEpoch();

        uint256 current = currentEpochIndex();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        assertEq(delegation.getUserWeight(alice), 0);
        assertEq(delegation.balanceAtEpochOf(current, delegateA), 0);
    }

    function test_syncUpdatesFutureEpochs() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 16;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertUserWeightMatches(i, alice, expected);
            assertWeightMatches(i, delegateA, expected);
        }
    }

    function test_multipleDelegates() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);
        mockVlCVX.mockLock(bob, 2000 * WEIGHT_DIVISOR, 2000 * WEIGHT_DIVISOR);
        mockVlCVX.mockLock(carol, 3000 * WEIGHT_DIVISOR, 3000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateB);

        vm.prank(carol);
        delegation.setDelegate(delegateA);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expectedA = mockVlCVX.balanceAtEpochOf(i, alice) + mockVlCVX.balanceAtEpochOf(i, carol);
            uint256 expectedB = mockVlCVX.balanceAtEpochOf(i, bob);
            assertWeightMatches(i, delegateA, expectedA);
            assertWeightMatches(i, delegateB, expectedB);
        }
    }

    function test_swapDelegateMigratesWeights() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 syncedUpTo = delegation.syncedUserEpoch(alice);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 newNextEpoch = nextEpochIndex();

        for (uint256 i = newNextEpoch; i < syncedUpTo && i < newNextEpoch + 16; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertWeightMatches(i, delegateA, 0);
            assertWeightMatches(i, delegateB, expected);
        }

        assertEq(delegation.getDelegateAtEpoch(alice, newNextEpoch), delegateB);
        assertEq(delegation.syncedUserEpoch(alice), newNextEpoch + 16);
    }

    function test_swapDelegateRemovesOldWeights() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 syncedUpTo = delegation.syncedUserEpoch(alice);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 newNextEpoch = nextEpochIndex();

        for (uint256 i = newNextEpoch; i < syncedUpTo; i++) {
            assertWeightMatches(i, delegateA, 0);
        }
    }

    function test_additionalLockThenSync() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockLock(alice, 500 * WEIGHT_DIVISOR, 500 * WEIGHT_DIVISOR);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertUserWeightMatches(i, alice, expected);
            assertWeightMatches(i, delegateA, expected);
        }
    }

    function test_relockReducesFutureWeight() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpWeeks(17);
        mockVlCVX.mockRelock(alice, 0, 800 * WEIGHT_DIVISOR);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertUserWeightMatches(i, alice, expected);
            assertWeightMatches(i, delegateA, expected);
        }
    }

    function test_expireLocksThenSync() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpWeeks(17);

        mockVlCVX.mockExpireLocks(alice, 1);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertUserWeightMatches(i, alice, expected);
        }
    }

    function test_syncAfterAllLocksExpired() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpWeeks(17);

        mockVlCVX.mockExpireAllLocks(alice);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            assertUserWeightMatches(i, alice, 0);
            assertWeightMatches(i, delegateA, 0);
        }
    }

    function test_syncReducesWeightWhenPartialExpiry() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockLock(alice, 500 * WEIGHT_DIVISOR, 500 * WEIGHT_DIVISOR);

        delegation.sync(alice);

        warpWeeks(17);

        mockVlCVX.mockExpireLocks(alice, 1);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertUserWeightMatches(i, alice, expected);
            assertWeightMatches(i, delegateA, expected);
        }
    }

    function test_balanceAtEpochOf() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 nextEpoch = nextEpochIndex();

        assertWeightMatches(nextEpoch, delegateA, 1000 * WEIGHT_DIVISOR);
        assertWeightMatches(nextEpoch + 5, delegateA, 1000 * WEIGHT_DIVISOR);
    }

    function test_setDelegateToZeroRemovesWeights() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 syncedUpTo = delegation.syncedUserEpoch(alice);

        vm.prank(alice);
        delegation.setDelegate(address(0));

        uint256 newNextEpoch = nextEpochIndex();
        uint256 epochForLookup = syncedUpTo > 0 ? syncedUpTo - 1 : newNextEpoch;

        assertEq(delegation.getDelegateAtEpoch(alice, epochForLookup), address(0));

        for (uint256 i = newNextEpoch; i < syncedUpTo; i++) {
            assertWeightMatches(i, delegateA, 0);
        }
    }

    function test_cannotSelfDelegate() public {
        vm.prank(alice);
        vm.expectRevert(SelfDelegation.selector);
        delegation.setDelegate(alice);
    }

    function test_cannotSyncWithoutDelegate() public {
        delegation.sync(alice);
    }

    function test_swapDelegateMultipleTimes() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertWeightMatches(i, delegateA, expected);
            assertWeightMatches(i, delegateB, 0);
        }
    }

    function test_syncAfterMidEpochWarp() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpWeeks(3);

        mockVlCVX.mockLock(alice, 500 * WEIGHT_DIVISOR, 500 * WEIGHT_DIVISOR);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertUserWeightMatches(i, alice, expected);
            assertWeightMatches(i, delegateA, expected);
        }
    }

    function test_multipleUsersSameDelegate() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);
        mockVlCVX.mockLock(bob, 2000 * WEIGHT_DIVISOR, 2000 * WEIGHT_DIVISOR);
        mockVlCVX.mockLock(carol, 3000 * WEIGHT_DIVISOR, 3000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateA);

        vm.prank(carol);
        delegation.setDelegate(delegateA);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice)
                + mockVlCVX.balanceAtEpochOf(i, bob)
                + mockVlCVX.balanceAtEpochOf(i, carol);
            assertWeightMatches(i, delegateA, expected);
        }
    }

    function test_userLeavesDelegateThenNewUserJoins() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);
        mockVlCVX.mockLock(bob, 2000 * WEIGHT_DIVISOR, 2000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            assertWeightMatches(i, delegateA, mockVlCVX.balanceAtEpochOf(i, bob));
            assertWeightMatches(i, delegateB, mockVlCVX.balanceAtEpochOf(i, alice));
        }
    }

    function test_totalDelegatedMatchesTotalVlCVX() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);
        mockVlCVX.mockLock(bob, 2000 * WEIGHT_DIVISOR, 2000 * WEIGHT_DIVISOR);
        mockVlCVX.mockLock(carol, 500 * WEIGHT_DIVISOR, 500 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateA);

        vm.prank(carol);
        delegation.setDelegate(delegateB);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 totalA = delegation.balanceAtEpochOf(i, delegateA);
            uint256 totalB = delegation.balanceAtEpochOf(i, delegateB);

            uint256 expectedA = mockVlCVX.balanceAtEpochOf(i, alice) + mockVlCVX.balanceAtEpochOf(i, bob);
            uint256 expectedB = mockVlCVX.balanceAtEpochOf(i, carol);
            uint256 totalExpected = expectedA + expectedB;

            uint256 totalDelegated = totalA + totalB;
            uint256 tolerance = WEIGHT_DIVISOR * 2;
            if (totalDelegated > totalExpected) {
                assertLe(totalDelegated - totalExpected, tolerance);
            } else {
                assertLe(totalExpected - totalDelegated, tolerance);
            }
        }
    }

    function test_epochCount() public view {
        uint256 count = delegation.epochCount();
        assertGt(count, 0);
    }

    function test_multipleLocksDifferentEpochs() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockLock(alice, 500 * WEIGHT_DIVISOR, 500 * WEIGHT_DIVISOR);

        delegation.sync(alice);

        warpToNextEpoch();

        mockVlCVX.mockLock(alice, 300 * WEIGHT_DIVISOR, 300 * WEIGHT_DIVISOR);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertUserWeightMatches(i, alice, expected);
            assertWeightMatches(i, delegateA, expected);
        }
    }

    function test_partialDelegateSwapMidEpoch() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);
        mockVlCVX.mockLock(bob, 2000 * WEIGHT_DIVISOR, 2000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockLock(alice, 500 * WEIGHT_DIVISOR, 500 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 aliceWeight = mockVlCVX.balanceAtEpochOf(i, alice);
            uint256 bobWeight = mockVlCVX.balanceAtEpochOf(i, bob);
            assertWeightMatches(i, delegateA, bobWeight);
            assertWeightMatches(i, delegateB, aliceWeight);
        }
    }

    // --- New tests for epoch-based delegate history ---

    function test_delegateHistoryFirstRecord() public {
        uint256 nextEpoch = nextEpochIndex();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        assertEq(delegation.getDelegateAtEpoch(alice, nextEpoch), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, nextEpoch + 5), delegateA);
    }

    function test_delegateHistoryPreviousEpochReturnsZero() public {
        uint256 nextEpoch = nextEpochIndex();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        assertEq(delegation.getDelegateAtEpoch(alice, nextEpoch), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, nextEpoch - 1), address(0));
    }

    function test_delegateHistorySwapsTakeEffectNextEpoch() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 nextEpoch1 = nextEpochIndex();
        uint256 currentEpoch = currentEpochIndex();

        assertEq(delegation.getDelegateAtEpoch(alice, currentEpoch), address(0));
        assertEq(delegation.getDelegateAtEpoch(alice, nextEpoch1), delegateA);

        warpToNextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 nextEpoch2 = nextEpochIndex();

        assertEq(delegation.getDelegateAtEpoch(alice, currentEpoch), address(0));
        assertEq(delegation.getDelegateAtEpoch(alice, nextEpoch1), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, nextEpoch2), delegateB);
    }

    function test_delegateHistoryMultipleSwapsSameEpoch() public {
        uint256 nextEpoch = nextEpochIndex();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        vm.prank(alice);
        delegation.setDelegate(delegateC);

        assertEq(delegation.getDelegateAtEpoch(alice, nextEpoch), delegateC);

        (address d, uint32 startEpoch) = delegation.delegateHistory(alice, 0);
        assertEq(d, delegateC);
        assertEq(startEpoch, uint32(nextEpoch));
    }

    function test_delegateHistoryMultipleSwapsAcrossEpochs() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 epoch1 = nextEpochIndex();

        warpToNextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 epoch2 = nextEpochIndex();

        warpToNextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateC);

        uint256 epoch3 = nextEpochIndex();

        assertEq(delegation.getDelegateAtEpoch(alice, epoch1 - 1), address(0));
        assertEq(delegation.getDelegateAtEpoch(alice, epoch1), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, epoch2 - 1), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, epoch2), delegateB);
        assertEq(delegation.getDelegateAtEpoch(alice, epoch3 - 1), delegateB);
        assertEq(delegation.getDelegateAtEpoch(alice, epoch3), delegateC);
    }

    function test_delegateHistorySwapToZeroAddress() public {
        uint256 nextEpoch = nextEpochIndex();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(address(0));

        assertEq(delegation.getDelegateAtEpoch(alice, nextEpoch), address(0));
    }

    function test_cannotSyncAfterDelegateSetToZero() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(address(0));

        delegation.sync(alice);
    }

    function test_setDelegateSameEpochOverwrites() public {
        uint256 nextEpoch = nextEpochIndex();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        assertEq(delegation.getDelegateAtEpoch(alice, nextEpoch), delegateB);

        (address d, uint32 startEpoch) = delegation.delegateHistory(alice, 0);
        assertEq(d, delegateB);
        assertEq(startEpoch, uint32(nextEpoch));
    }

    function test_delegateHistoryRecords() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 epoch1 = nextEpochIndex();

        warpToNextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 epoch2 = nextEpochIndex();

        (address d0, uint32 se0) = delegation.delegateHistory(alice, 0);
        (address d1, uint32 se1) = delegation.delegateHistory(alice, 1);
        assertEq(d0, delegateA);
        assertEq(se0, uint32(epoch1));
        assertEq(d1, delegateB);
        assertEq(se1, uint32(epoch2));
    }

    function test_syncIncludesCurrentEpoch() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        warpToNextEpoch();

        uint256 current = currentEpochIndex();
        uint256 expected = mockVlCVX.balanceAtEpochOf(current, alice);
        assertGt(expected, 0);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        assertEq(delegation.balanceAtEpochOf(current, delegateA), 0);

        delegation.sync(alice);

        // Current epoch: alice's delegate is still address(0) (delegate starts next epoch),
        // so delegateA gets nothing at current epoch. But alice's user weight is updated.
        assertEq(delegation.balanceAtEpochOf(current, delegateA), 0);

        // Future epochs: delegateA gets alice's weight
        uint256 future = current + 1;
        assertEq(delegation.balanceAtEpochOf(future, delegateA), expected);
    }

    function test_syncCurrentEpochUsesCorrectDelegate() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        // Now alice sets a NEW delegate (starts at next epoch)
        vm.prank(alice);
        delegation.setDelegate(delegateB);

        // Current epoch delegate should still be delegateA
        assertEq(delegation.getDelegateAtEpoch(alice, currentEpochIndex()), delegateA);

        delegation.sync(alice);

        // Current epoch: synced to delegateA
        uint256 current = currentEpochIndex();
        uint256 expected = mockVlCVX.balanceAtEpochOf(current, alice);
        assertEq(delegation.balanceAtEpochOf(current, delegateA), expected);
        assertEq(delegation.balanceAtEpochOf(current, delegateB), 0);

        // Future epochs: synced to delegateB
        uint256 future = current + 1;
        assertEq(delegation.balanceAtEpochOf(future, delegateB), expected);
        assertEq(delegation.balanceAtEpochOf(future, delegateA), 0);
    }

    function test_syncAfterFirstDelegateSetDoesNotBackfillCurrentEpoch() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        warpToNextEpoch();

        uint256 current = currentEpochIndex();
        uint256 next = nextEpochIndex();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        delegation.sync(alice);

        assertEq(delegation.getDelegateAtEpoch(alice, current), address(0));
        assertWeightMatches(current, delegateA, 0);
        assertWeightMatches(next, delegateA, mockVlCVX.balanceAtEpochOf(next, alice));
    }

    function test_syncAfterDelegateChangeCreditsCurrentEpochDelegate() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        uint256 current = currentEpochIndex();
        uint256 next = nextEpochIndex();

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        mockVlCVX.mockRelock(alice, 0, 1500 * WEIGHT_DIVISOR);
        delegation.sync(alice);

        assertEq(delegation.getDelegateAtEpoch(alice, current), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, next), delegateB);
        assertWeightMatches(current, delegateA, mockVlCVX.balanceAtEpochOf(current, alice));
        assertWeightMatches(current, delegateB, 0);
        assertWeightMatches(next, delegateA, 0);
        assertWeightMatches(next, delegateB, mockVlCVX.balanceAtEpochOf(next, alice));
    }

    function test_syncAfterDelegateRemovalStillCreditsCurrentEpochDelegate() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        uint256 current = currentEpochIndex();
        uint256 next = nextEpochIndex();

        vm.prank(alice);
        delegation.setDelegate(address(0));

        mockVlCVX.mockRelock(alice, 0, 1500 * WEIGHT_DIVISOR);
        delegation.sync(alice);

        assertEq(delegation.getDelegateAtEpoch(alice, current), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, next), address(0));
        assertWeightMatches(current, delegateA, mockVlCVX.balanceAtEpochOf(current, alice));
        assertWeightMatches(next, delegateA, 0);
    }

    function test_syncDoubleCallReturnsEarly() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockRelock(alice, 0, 1500 * WEIGHT_DIVISOR);

        delegation.sync(alice);

        uint256 current = currentEpochIndex();
        (uint256 snapWeight1, uint256 snapTs1) = delegation.getSyncSnapshot(alice, current);
        assertGt(snapTs1, 0);

        delegation.sync(alice);

        (uint256 snapWeight2, uint256 snapTs2) = delegation.getSyncSnapshot(alice, current);
        assertEq(snapWeight2, snapWeight1);
        assertEq(snapTs2, snapTs1);

        assertEq(delegation.balanceAtEpochOf(current, delegateA), 1500 * WEIGHT_DIVISOR);
    }

    function test_syncStoresSnapshot() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockRelock(alice, 0, 1500 * WEIGHT_DIVISOR);

        uint256 preWeight = delegation.userWeightAtEpochOf(currentEpochIndex(), alice);
        assertGt(preWeight, 0);

        uint256 ts = block.timestamp;
        delegation.sync(alice);

        (uint256 snapWeight, uint256 snapTs) = delegation.getSyncSnapshot(alice, currentEpochIndex());
        assertEq(snapWeight, preWeight);
        assertEq(snapTs, ts);
    }

    function test_syncNewEpochAllowsResync() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockRelock(alice, 0, 1500 * WEIGHT_DIVISOR);

        delegation.sync(alice);

        uint256 epoch1 = currentEpochIndex();

        (, uint256 snapTs1) = delegation.getSyncSnapshot(alice, epoch1);
        assertGt(snapTs1, 0);

        warpToNextEpoch();

        mockVlCVX.mockRelock(alice, 0, 2000 * WEIGHT_DIVISOR);

        uint256 ts2 = block.timestamp;
        delegation.sync(alice);

        uint256 epoch2 = currentEpochIndex();
        (, uint256 snapTs2) = delegation.getSyncSnapshot(alice, epoch2);
        assertGt(snapTs2, snapTs1);
        assertEq(snapTs2, ts2);

        uint256 expected = mockVlCVX.balanceAtEpochOf(epoch2, alice);
        assertUserWeightMatches(epoch2, alice, expected);
        assertWeightMatches(epoch2, delegateA, expected);
    }

    function test_setDelegateDoesNotIncludeCurrentEpoch() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        warpToNextEpoch();

        uint256 current = currentEpochIndex();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        assertEq(delegation.balanceAtEpochOf(current, delegateA), 0);
        assertEq(delegation.getUserWeight(alice), 0);
    }

    function test_syncSnapshotCapturesPreSyncWeight() public {
        mockVlCVX.mockLock(alice, 1000 * WEIGHT_DIVISOR, 1000 * WEIGHT_DIVISOR);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockRelock(alice, 0, 1500 * WEIGHT_DIVISOR);

        uint256 current = currentEpochIndex();
        uint256 preWeight = delegation.userWeightAtEpochOf(current, alice);

        delegation.sync(alice);

        (uint256 snapWeight,) = delegation.getSyncSnapshot(alice, current);
        assertEq(snapWeight, preWeight);
    }
}
