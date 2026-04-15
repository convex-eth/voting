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

    function test_setDelegateAndSync() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 16;

        assertEq(delegation.delegates(alice), delegateA);
        assertEq(delegation.syncedUserEpoch(alice), endEpoch);

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertEq(delegation.userEpochWeights(alice, i), expected);
            assertEq(delegation.delegateEpochWeights(delegateA, i), expected);
        }
    }

    function test_syncOnlyWritesFutureEpochs() public {
        mockVlCVX.mockLock(alice, 1000, 1000);
        warpToNextEpoch();

        uint256 current = currentEpochIndex();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        assertEq(delegation.userEpochWeights(alice, current), 0);
        assertEq(delegation.delegateEpochWeights(delegateA, current), 0);
    }

    function test_syncUpdatesFutureEpochs() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 16;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertEq(delegation.userEpochWeights(alice, i), expected);
            assertEq(delegation.delegateEpochWeights(delegateA, i), expected);
        }
    }

    function test_multipleDelegates() public {
        mockVlCVX.mockLock(alice, 1000, 1000);
        mockVlCVX.mockLock(bob, 2000, 2000);
        mockVlCVX.mockLock(carol, 3000, 3000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateB);

        vm.prank(carol);
        delegation.setDelegate(delegateA);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            assertEq(
                delegation.delegateEpochWeights(delegateA, i),
                mockVlCVX.balanceAtEpochOf(i, alice) + mockVlCVX.balanceAtEpochOf(i, carol)
            );
            assertEq(
                delegation.delegateEpochWeights(delegateB, i),
                mockVlCVX.balanceAtEpochOf(i, bob)
            );
        }
    }

    function test_swapDelegateMigratesWeights() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 syncedUpTo = delegation.syncedUserEpoch(alice);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 newNextEpoch = nextEpochIndex();

        for (uint256 i = newNextEpoch; i < syncedUpTo && i < newNextEpoch + 16; i++) {
            assertEq(delegation.delegateEpochWeights(delegateA, i), 0, "delegateA should be zero");
            assertEq(delegation.delegateEpochWeights(delegateB, i), mockVlCVX.balanceAtEpochOf(i, alice), "delegateB weight mismatch");
        }

        assertEq(delegation.delegates(alice), delegateB);
        assertEq(delegation.syncedUserEpoch(alice), newNextEpoch + 16);
    }

    function test_swapDelegateRemovesOldWeights() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 syncedUpTo = delegation.syncedUserEpoch(alice);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 newNextEpoch = nextEpochIndex();

        for (uint256 i = newNextEpoch; i < syncedUpTo; i++) {
            assertEq(delegation.delegateEpochWeights(delegateA, i), 0);
        }
    }

    function test_additionalLockThenSync() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockLock(alice, 500, 500);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertEq(delegation.userEpochWeights(alice, i), expected);
            assertEq(delegation.delegateEpochWeights(delegateA, i), expected);
        }
    }

    function test_relockReducesFutureWeight() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpWeeks(17);
        mockVlCVX.mockRelock(alice, 0, 800);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertEq(delegation.userEpochWeights(alice, i), expected);
            assertEq(delegation.delegateEpochWeights(delegateA, i), expected);
        }
    }

    function test_expireLocksThenSync() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpWeeks(17);

        mockVlCVX.mockExpireLocks(alice, 1);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertEq(delegation.userEpochWeights(alice, i), expected);
        }
    }

    function test_syncAfterAllLocksExpired() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpWeeks(17);

        mockVlCVX.mockExpireAllLocks(alice);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            assertEq(delegation.userEpochWeights(alice, i), 0);
            assertEq(delegation.delegateEpochWeights(delegateA, i), 0);
        }
    }

    function test_syncReducesWeightWhenPartialExpiry() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockLock(alice, 500, 500);

        delegation.sync(alice);

        warpWeeks(17);

        mockVlCVX.mockExpireLocks(alice, 1);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertEq(delegation.userEpochWeights(alice, i), expected);
            assertEq(delegation.delegateEpochWeights(delegateA, i), expected);
        }
    }

    function test_balanceAtEpochOf() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 nextEpoch = nextEpochIndex();

        assertEq(delegation.balanceAtEpochOf(nextEpoch, delegateA), 1000);
        assertEq(delegation.balanceAtEpochOf(nextEpoch + 5, delegateA), 1000);
    }

    function test_setDelegateToZeroRemovesWeights() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 syncedUpTo = delegation.syncedUserEpoch(alice);

        vm.prank(alice);
        delegation.setDelegate(address(0));

        assertEq(delegation.delegates(alice), address(0));

        uint256 newNextEpoch = nextEpochIndex();
        for (uint256 i = newNextEpoch; i < syncedUpTo; i++) {
            assertEq(delegation.delegateEpochWeights(delegateA, i), 0);
        }
    }

    function test_cannotSyncWithoutDelegate() public {
        vm.expectRevert("No delegate");
        delegation.sync(alice);
    }

    function test_swapDelegateMultipleTimes() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

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
            assertEq(delegation.delegateEpochWeights(delegateA, i), expected);
            assertEq(delegation.delegateEpochWeights(delegateB, i), 0);
        }
    }

    function test_syncAfterMidEpochWarp() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpWeeks(3);

        mockVlCVX.mockLock(alice, 500, 500);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertEq(delegation.userEpochWeights(alice, i), expected);
            assertEq(delegation.delegateEpochWeights(delegateA, i), expected);
        }
    }

    function test_multipleUsersSameDelegate() public {
        mockVlCVX.mockLock(alice, 1000, 1000);
        mockVlCVX.mockLock(bob, 2000, 2000);
        mockVlCVX.mockLock(carol, 3000, 3000);

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
            assertEq(delegation.delegateEpochWeights(delegateA, i), expected);
        }
    }

    function test_userLeavesDelegateThenNewUserJoins() public {
        mockVlCVX.mockLock(alice, 1000, 1000);
        mockVlCVX.mockLock(bob, 2000, 2000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            assertEq(delegation.delegateEpochWeights(delegateA, i), mockVlCVX.balanceAtEpochOf(i, bob));
            assertEq(delegation.delegateEpochWeights(delegateB, i), mockVlCVX.balanceAtEpochOf(i, alice));
        }
    }

    function test_totalDelegatedMatchesTotalVlCVX() public {
        mockVlCVX.mockLock(alice, 1000, 1000);
        mockVlCVX.mockLock(bob, 2000, 2000);
        mockVlCVX.mockLock(carol, 500, 500);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateA);

        vm.prank(carol);
        delegation.setDelegate(delegateB);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 totalA = delegation.delegateEpochWeights(delegateA, i);
            uint256 totalB = delegation.delegateEpochWeights(delegateB, i);

            assertEq(totalA, mockVlCVX.balanceAtEpochOf(i, alice) + mockVlCVX.balanceAtEpochOf(i, bob));
            assertEq(totalB, mockVlCVX.balanceAtEpochOf(i, carol));

            uint256 totalDelegated = totalA + totalB;
            uint256 totalWeight = mockVlCVX.balanceAtEpochOf(i, alice)
                + mockVlCVX.balanceAtEpochOf(i, bob)
                + mockVlCVX.balanceAtEpochOf(i, carol);
            assertEq(totalDelegated, totalWeight);
        }
    }

    function test_epochCount() public {
        uint256 count = delegation.epochCount();
        assertGt(count, 0);
    }

    function test_multipleLocksDifferentEpochs() public {
        mockVlCVX.mockLock(alice, 1000, 1000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockLock(alice, 500, 500);

        delegation.sync(alice);

        warpToNextEpoch();

        mockVlCVX.mockLock(alice, 300, 300);

        delegation.sync(alice);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 expected = mockVlCVX.balanceAtEpochOf(i, alice);
            assertEq(delegation.userEpochWeights(alice, i), expected);
            assertEq(delegation.delegateEpochWeights(delegateA, i), expected);
        }
    }

    function test_partialDelegateSwapMidEpoch() public {
        mockVlCVX.mockLock(alice, 1000, 1000);
        mockVlCVX.mockLock(bob, 2000, 2000);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateA);

        warpToNextEpoch();

        mockVlCVX.mockLock(alice, 500, 500);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 nextEpoch = nextEpochIndex();
        uint256 endEpoch = nextEpoch + 2;

        for (uint256 i = nextEpoch; i < endEpoch; i++) {
            uint256 aliceWeight = mockVlCVX.balanceAtEpochOf(i, alice);
            uint256 bobWeight = mockVlCVX.balanceAtEpochOf(i, bob);
            assertEq(delegation.delegateEpochWeights(delegateA, i), bobWeight);
            assertEq(delegation.delegateEpochWeights(delegateB, i), aliceWeight);
        }
    }
}