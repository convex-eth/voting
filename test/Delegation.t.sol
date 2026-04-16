// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Delegation.sol";
import "./mocks/MockVlCVX.sol";

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

        assertEq(delegation.delegates(alice), delegateA);
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

        assertEq(delegation.delegates(alice), delegateB);
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

        assertEq(delegation.delegates(alice), address(0));

        uint256 newNextEpoch = nextEpochIndex();
        for (uint256 i = newNextEpoch; i < syncedUpTo; i++) {
            assertWeightMatches(i, delegateA, 0);
        }
    }

    function test_cannotSyncWithoutDelegate() public {
        vm.expectRevert("No delegate");
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
}
