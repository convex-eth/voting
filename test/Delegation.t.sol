// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Delegation.sol";
import "../src/interface/IvlCVX.sol";
import "./mocks/simpleVlCvx.sol";

error SelfDelegation();

contract DelegationTest is Test {
    IvlCVX internal vlcvx;
    Delegation internal delegation;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal delegateA = makeAddr("delegateA");
    address internal delegateB = makeAddr("delegateB");
    address internal delegateC = makeAddr("delegateC");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WD = 1e17;

    function setUp() public {
        vm.warp(1700000000);
        simpleVlCvx impl = new simpleVlCvx();
        vlcvx = IvlCVX(address(impl));
        delegation = new Delegation("Convex Delegation", address(vlcvx));
    }

    function _currentEpoch() internal view returns (uint256) {
        return (block.timestamp / WEEK) * WEEK;
    }

    function _warpToNextEpoch() internal {
        uint256 ce = _currentEpoch();
        vm.warp(ce + WEEK + 1);
    }

    function _warpWeeks(uint256 n) internal {
        vm.warp(block.timestamp + WEEK * n);
    }

    function _nextEpoch() internal returns (uint256) {
        vlcvx.checkpointEpoch();
        return vlcvx.epochCount() - 1;
    }

    function _currentEpochIdx() internal view returns (uint256) {
        return vlcvx.findEpochId(block.timestamp);
    }

    function _lock(address user, uint256 amount) internal {
        vlcvx.lock(user, amount, 0);
    }

    function _relock(address user, uint256 amount) internal {
        vm.prank(user);
        simpleVlCvx(address(vlcvx)).relock(user, amount, 0);
    }

    function _processExpired(address user) internal {
        vm.prank(user);
        try simpleVlCvx(address(vlcvx)).processExpiredLocks() {} catch {}
    }

    function _assertWeightEq(uint256 epoch, address delegate, uint256 expected) internal {
        uint256 actual = delegation.balanceAtEpochOf(epoch, delegate);
        uint256 tol = WD;
        string memory label = string(abi.encodePacked("delegate weight epoch ", vm.toString(epoch)));
        if (actual > expected) {
            assertLe(actual - expected, tol, label);
        } else {
            assertLe(expected - actual, tol, label);
        }
    }

    function _assertUserWeightEq(uint256 epoch, address user, uint256 expected) internal {
        uint256 actual = delegation.userWeightAtEpochOf(epoch, user);
        uint256 tol = WD;
        string memory label = string(abi.encodePacked("user weight epoch ", vm.toString(epoch)));
        if (actual > expected) {
            assertLe(actual - expected, tol, label);
        } else {
            assertLe(expected - actual, tol, label);
        }
    }

    function _ensureEpochs(uint256 upTo) internal {
        vlcvx.checkpointEpoch();
        if (vlcvx.epochCount() > upTo) return;
        (, uint32 epoch0Date) = vlcvx.epochs(0);
        uint256 targetTime = uint256(epoch0Date) + (upTo + 1) * WEEK;
        uint256 savedTs = block.timestamp;
        vm.warp(targetTime);
        vlcvx.checkpointEpoch();
        vm.warp(savedTs);
    }

    function _vlCVXBalanceAtEpoch(uint256 epoch, address user) internal returns (uint256) {
        _ensureEpochs(epoch);
        return vlcvx.balanceAtEpochOf(epoch, user);
    }

    function _assertWeightMatchesVlCVX(uint256 epoch, address user) internal {
        uint256 expected = _vlCVXBalanceAtEpoch(epoch, user);
        _assertUserWeightEq(epoch, user, expected);
    }

    function _assertDelegateMatchesVlCVX(uint256 epoch, address user, address delegate) internal {
        uint256 expected = _vlCVXBalanceAtEpoch(epoch, user);
        _assertWeightEq(epoch, delegate, expected);
    }

    // ============================================================
    // BASIC: lock + delegate + sync
    // ============================================================

    function test_setDelegateAndSync() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 next = _nextEpoch();
        uint256 end = next + 16;

        assertEq(delegation.getDelegateAtEpoch(alice, next), delegateA);
        assertEq(delegation.syncedUserEpoch(alice), end);

        for (uint256 i = next; i < end; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }
    }

    function test_syncOnlyWritesFutureEpochs() public {
        _lock(alice, 1000 * WD);
        _warpToNextEpoch();

        uint256 current = _currentEpochIdx();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        assertEq(delegation.getUserWeight(alice), 0);
        assertEq(delegation.balanceAtEpochOf(current, delegateA), 0);
    }

    function test_syncUpdatesFutureEpochs() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 next = _nextEpoch();
        uint256 end = next + 16;

        for (uint256 i = next; i < end; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }
    }

    // ============================================================
    // NO LOCKS / ZERO WEIGHT
    // ============================================================

    function test_setDelegateWithNoLocks() public {
        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 3; i++) {
            _assertUserWeightEq(i, alice, 0);
            _assertWeightEq(i, delegateA, 0);
        }
    }

    function test_syncWithNoLocks() public {
        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpToNextEpoch();

        delegation.sync(alice);

        uint256 next = _nextEpoch();
        _assertUserWeightEq(next, alice, 0);
        _assertWeightEq(next, delegateA, 0);
    }

    function test_setDelegateNoLocksThenLockAndSync() public {
        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpToNextEpoch();

        _lock(alice, 1000 * WD);

        delegation.sync(alice);

        uint256 next = _nextEpoch();
        for (uint256 i = next; i < next + 2; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }
    }

    // ============================================================
    // MULTIPLE USERS
    // ============================================================

    function test_multipleDelegates() public {
        _lock(alice, 1000 * WD);
        _lock(bob, 2000 * WD);
        _lock(carol, 3000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateB);

        vm.prank(carol);
        delegation.setDelegate(delegateA);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            uint256 expA = _vlCVXBalanceAtEpoch(i, alice) + _vlCVXBalanceAtEpoch(i, carol);
            uint256 expB = _vlCVXBalanceAtEpoch(i, bob);
            _assertWeightEq(i, delegateA, expA);
            _assertWeightEq(i, delegateB, expB);
        }
    }

    function test_multipleUsersSameDelegate() public {
        _lock(alice, 1000 * WD);
        _lock(bob, 2000 * WD);
        _lock(carol, 3000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateA);

        vm.prank(carol);
        delegation.setDelegate(delegateA);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            uint256 exp = _vlCVXBalanceAtEpoch(i, alice)
                + _vlCVXBalanceAtEpoch(i, bob)
                + _vlCVXBalanceAtEpoch(i, carol);
            _assertWeightEq(i, delegateA, exp);
        }
    }

    function test_totalDelegatedMatchesTotalVlCVX() public {
        _lock(alice, 1000 * WD);
        _lock(bob, 2000 * WD);
        _lock(carol, 500 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateA);

        vm.prank(carol);
        delegation.setDelegate(delegateB);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            uint256 totalDel = delegation.balanceAtEpochOf(i, delegateA)
                + delegation.balanceAtEpochOf(i, delegateB);

            uint256 totalExp = _vlCVXBalanceAtEpoch(i, alice)
                + _vlCVXBalanceAtEpoch(i, bob)
                + _vlCVXBalanceAtEpoch(i, carol);

            uint256 tol = WD * 2;
            if (totalDel > totalExp) {
                assertLe(totalDel - totalExp, tol);
            } else {
                assertLe(totalExp - totalDel, tol);
            }
        }
    }

    // ============================================================
    // DELEGATE SWAPS
    // ============================================================

    function test_swapDelegateMigratesWeights() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 syncedUpTo = delegation.syncedUserEpoch(alice);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 newNext = _nextEpoch();

        for (uint256 i = newNext; i < syncedUpTo && i < newNext + 16; i++) {
            _assertWeightEq(i, delegateA, 0);
            _assertDelegateMatchesVlCVX(i, alice, delegateB);
        }

        assertEq(delegation.getDelegateAtEpoch(alice, newNext), delegateB);
    }

    function test_swapDelegateRemovesOldWeights() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 syncedUpTo = delegation.syncedUserEpoch(alice);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 newNext = _nextEpoch();

        for (uint256 i = newNext; i < syncedUpTo; i++) {
            _assertWeightEq(i, delegateA, 0);
        }
    }

    function test_setDelegateToZeroRemovesWeights() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 syncedUpTo = delegation.syncedUserEpoch(alice);

        vm.prank(alice);
        delegation.setDelegate(address(0));

        uint256 newNext = _nextEpoch();

        for (uint256 i = newNext; i < syncedUpTo; i++) {
            _assertWeightEq(i, delegateA, 0);
        }
    }

    function test_swapDelegateMultipleTimes() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
            _assertWeightEq(i, delegateB, 0);
        }
    }

    function test_userLeavesDelegateThenNewUserJoins() public {
        _lock(alice, 1000 * WD);
        _lock(bob, 2000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            _assertDelegateMatchesVlCVX(i, bob, delegateA);
            _assertDelegateMatchesVlCVX(i, alice, delegateB);
        }
    }

    function test_partialDelegateSwapMidEpoch() public {
        _lock(alice, 1000 * WD);
        _lock(bob, 2000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(bob);
        delegation.setDelegate(delegateA);

        _warpToNextEpoch();

        _lock(alice, 500 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            _assertDelegateMatchesVlCVX(i, bob, delegateA);
            _assertDelegateMatchesVlCVX(i, alice, delegateB);
        }
    }

    // ============================================================
    // DELEGATE HISTORY
    // ============================================================

    function test_delegateHistoryFirstRecord() public {
        uint256 next = _nextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        assertEq(delegation.getDelegateAtEpoch(alice, next), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, next + 5), delegateA);
    }

    function test_delegateHistoryPreviousEpochReturnsZero() public {
        uint256 next = _nextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        assertEq(delegation.getDelegateAtEpoch(alice, next), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, next - 1), address(0));
    }

    function test_delegateHistorySwapsTakeEffectNextEpoch() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 next1 = _nextEpoch();
        uint256 current = _currentEpochIdx();

        assertEq(delegation.getDelegateAtEpoch(alice, current), address(0));
        assertEq(delegation.getDelegateAtEpoch(alice, next1), delegateA);

        _warpToNextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 next2 = _nextEpoch();

        assertEq(delegation.getDelegateAtEpoch(alice, current), address(0));
        assertEq(delegation.getDelegateAtEpoch(alice, next1), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, next2), delegateB);
    }

    function test_delegateHistoryMultipleSwapsSameEpoch() public {
        uint256 next = _nextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        vm.prank(alice);
        delegation.setDelegate(delegateC);

        assertEq(delegation.getDelegateAtEpoch(alice, next), delegateC);

        (address d, uint32 startEpoch) = delegation.delegateHistory(alice, 0);
        assertEq(d, delegateC);
        assertEq(startEpoch, uint32(next));
    }

    function test_delegateHistoryMultipleSwapsAcrossEpochs() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 epoch1 = _nextEpoch();

        _warpToNextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 epoch2 = _nextEpoch();

        _warpToNextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateC);

        uint256 epoch3 = _nextEpoch();

        assertEq(delegation.getDelegateAtEpoch(alice, epoch1 - 1), address(0));
        assertEq(delegation.getDelegateAtEpoch(alice, epoch1), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, epoch2 - 1), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, epoch2), delegateB);
        assertEq(delegation.getDelegateAtEpoch(alice, epoch3 - 1), delegateB);
        assertEq(delegation.getDelegateAtEpoch(alice, epoch3), delegateC);
    }

    function test_delegateHistorySwapToZeroAddress() public {
        uint256 next = _nextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(address(0));

        assertEq(delegation.getDelegateAtEpoch(alice, next), address(0));
    }

    function test_setDelegateSameEpochOverwrites() public {
        uint256 next = _nextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        assertEq(delegation.getDelegateAtEpoch(alice, next), delegateB);

        (address d, uint32 startEpoch) = delegation.delegateHistory(alice, 0);
        assertEq(d, delegateB);
        assertEq(startEpoch, uint32(next));
    }

    function test_delegateHistoryRecords() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 epoch1 = _nextEpoch();

        _warpToNextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        uint256 epoch2 = _nextEpoch();

        (address d0, uint32 se0) = delegation.delegateHistory(alice, 0);
        (address d1, uint32 se1) = delegation.delegateHistory(alice, 1);
        assertEq(d0, delegateA);
        assertEq(se0, uint32(epoch1));
        assertEq(d1, delegateB);
        assertEq(se1, uint32(epoch2));
    }

    // ============================================================
    // SELF DELEGATION
    // ============================================================

    function test_cannotSelfDelegate() public {
        vm.prank(alice);
        vm.expectRevert(SelfDelegation.selector);
        delegation.setDelegate(alice);
    }

    // ============================================================
    // SYNC WITH NO DELEGATE
    // ============================================================

    function test_syncWithoutDelegateDoesNothing() public {
        delegation.sync(alice);
    }

    function test_cannotSyncAfterDelegateSetToZero() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        vm.prank(alice);
        delegation.setDelegate(address(0));

        delegation.sync(alice);
    }

    // ============================================================
    // ADDITIONAL LOCKS + SYNC
    // ============================================================

    function test_additionalLockThenSync() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpToNextEpoch();

        _lock(alice, 500 * WD);

        delegation.sync(alice);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }
    }

    function test_multipleLocksDifferentEpochs() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpToNextEpoch();

        _lock(alice, 500 * WD);

        delegation.sync(alice);

        _warpToNextEpoch();

        _lock(alice, 300 * WD);

        delegation.sync(alice);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }
    }

    function test_syncAfterMidEpochWarp() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpWeeks(3);

        _lock(alice, 500 * WD);

        delegation.sync(alice);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }
    }

    // ============================================================
    // RELOCK + SYNC
    // ============================================================

    function test_relockReducesFutureWeight() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpWeeks(17);

        _relock(alice, 800 * WD);

        delegation.sync(alice);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }
    }

    // ============================================================
    // EXPIRY + PROCESS EXPIRED + SYNC
    // ============================================================

    function test_expireLocksThenSync() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpWeeks(17);

        _processExpired(alice);

        delegation.sync(alice);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            _assertWeightMatchesVlCVX(i, alice);
        }
    }

    function test_syncAfterAllLocksExpired() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpWeeks(17);

        _processExpired(alice);

        delegation.sync(alice);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            _assertUserWeightEq(i, alice, 0);
            _assertWeightEq(i, delegateA, 0);
        }
    }

    function test_syncReducesWeightWhenPartialExpiry() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpToNextEpoch();

        _lock(alice, 500 * WD);

        delegation.sync(alice);

        _warpWeeks(17);

        _processExpired(alice);

        delegation.sync(alice);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 2; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }
    }

    // ============================================================
    // EXPIRED LOCKS REVERT GUARD
    // ============================================================

    function test_revertIfExpiredLocksNotProcessed() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpWeeks(17);

        vm.expectRevert(abi.encodeWithSignature("ExpiredLocks()"));
        delegation.sync(alice);
    }

    // ============================================================
    // vlCVX BALANCE TRACKS DELEGATION WEIGHT OVER TIME
    // ============================================================

    function test_weightsTrackVlCVXAcrossEpochsAndExpiry() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 5; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }

        _warpWeeks(8);
        _lock(alice, 500 * WD);
        delegation.sync(alice);

        next = _nextEpoch();
        for (uint256 i = next; i < next + 3; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }

        _warpWeeks(10);
        _processExpired(alice);
        delegation.sync(alice);

        next = _nextEpoch();
        for (uint256 i = next; i < next + 3; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }
    }

    function test_weightsTrackVlCVXAfterRelock() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 next = _nextEpoch();

        for (uint256 i = next; i < next + 3; i++) {
            _assertWeightMatchesVlCVX(i, alice);
        }

        _warpWeeks(17);
        _relock(alice, 700 * WD);
        delegation.sync(alice);

        next = _nextEpoch();
        for (uint256 i = next; i < next + 3; i++) {
            _assertWeightMatchesVlCVX(i, alice);
            _assertDelegateMatchesVlCVX(i, alice, delegateA);
        }
    }

    function test_weightsDropToZeroAfterFullExpiry() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 next = _nextEpoch();
        assertGt(_vlCVXBalanceAtEpoch(next, alice), 0);

        _warpWeeks(17);
        _processExpired(alice);

        next = _nextEpoch();
        assertEq(_vlCVXBalanceAtEpoch(next, alice), 0);

        delegation.sync(alice);

        for (uint256 i = next; i < next + 3; i++) {
            _assertUserWeightEq(i, alice, 0);
            _assertWeightEq(i, delegateA, 0);
        }
    }

    // ============================================================
    // SYNC SNAPSHOTS
    // ============================================================

    function test_syncStoresSnapshot() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpWeeks(17);
        _relock(alice, 1500 * WD);

        uint256 preWeight = delegation.userWeightAtEpochOf(_currentEpochIdx(), alice);

        uint256 ts = block.timestamp;
        delegation.sync(alice);

        (uint256 snapWeight, uint256 snapTs) = delegation.getSyncSnapshot(alice, _currentEpochIdx());
        assertEq(snapWeight, preWeight);
        assertEq(snapTs, ts);
    }

    function test_syncSnapshotCapturesPreSyncWeight() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpWeeks(17);
        _relock(alice, 1500 * WD);

        uint256 current = _currentEpochIdx();
        uint256 preWeight = delegation.userWeightAtEpochOf(current, alice);

        delegation.sync(alice);

        (uint256 snapWeight,) = delegation.getSyncSnapshot(alice, current);
        assertEq(snapWeight, preWeight);
    }

    function test_syncDoubleCallIdempotent() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpWeeks(17);
        _relock(alice, 1500 * WD);

        delegation.sync(alice);

        uint256 current = _currentEpochIdx();
        (uint256 sw1, uint256 st1) = delegation.getSyncSnapshot(alice, current);
        assertGt(st1, 0);

        delegation.sync(alice);

        (uint256 sw2, uint256 st2) = delegation.getSyncSnapshot(alice, current);
        assertEq(sw2, sw1);
        assertEq(st2, st1);

        _assertDelegateMatchesVlCVX(current, alice, delegateA);
    }

    function test_syncNewEpochAllowsResync() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpWeeks(17);
        _relock(alice, 1500 * WD);

        delegation.sync(alice);

        uint256 epoch1 = _currentEpochIdx();
        (, uint256 st1) = delegation.getSyncSnapshot(alice, epoch1);
        assertGt(st1, 0);

        _warpWeeks(17);
        _relock(alice, 2000 * WD);

        uint256 ts2 = block.timestamp;
        delegation.sync(alice);

        uint256 epoch2 = _currentEpochIdx();
        (, uint256 st2) = delegation.getSyncSnapshot(alice, epoch2);
        assertGt(st2, st1);
        assertEq(st2, ts2);

        _assertWeightMatchesVlCVX(epoch2, alice);
        _assertDelegateMatchesVlCVX(epoch2, alice, delegateA);
    }

    // ============================================================
    // SYNC + EPOCH BOUNDARIES
    // ============================================================

    function test_syncIncludesCurrentEpoch() public {
        _lock(alice, 1000 * WD);

        _warpToNextEpoch();

        uint256 current = _currentEpochIdx();
        uint256 expected = _vlCVXBalanceAtEpoch(current, alice);
        assertGt(expected, 0);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        assertEq(delegation.balanceAtEpochOf(current, delegateA), 0);

        delegation.sync(alice);

        assertEq(delegation.balanceAtEpochOf(current, delegateA), 0);

        uint256 future = current + 1;
        _assertWeightEq(future, delegateA, expected);
    }

    function test_syncCurrentEpochUsesCorrectDelegate() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpToNextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        assertEq(delegation.getDelegateAtEpoch(alice, _currentEpochIdx()), delegateA);

        delegation.sync(alice);

        uint256 current = _currentEpochIdx();
        uint256 expected = _vlCVXBalanceAtEpoch(current, alice);
        _assertWeightEq(current, delegateA, expected);
        _assertWeightEq(current, delegateB, 0);

        uint256 future = current + 1;
        _assertWeightEq(future, delegateB, expected);
        _assertWeightEq(future, delegateA, 0);
    }

    function test_syncAfterFirstDelegateSetDoesNotBackfillCurrentEpoch() public {
        _lock(alice, 1000 * WD);

        _warpToNextEpoch();

        uint256 current = _currentEpochIdx();
        uint256 next = _nextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        delegation.sync(alice);

        assertEq(delegation.getDelegateAtEpoch(alice, current), address(0));
        _assertWeightEq(current, delegateA, 0);
        _assertDelegateMatchesVlCVX(next, alice, delegateA);
    }

    function test_syncAfterDelegateChangeCreditsCurrentEpochDelegate() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpToNextEpoch();

        uint256 current = _currentEpochIdx();
        uint256 next = _nextEpoch();

        vm.prank(alice);
        delegation.setDelegate(delegateB);

        _lock(alice, 500 * WD);
        delegation.sync(alice);

        assertEq(delegation.getDelegateAtEpoch(alice, current), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, next), delegateB);
        _assertDelegateMatchesVlCVX(current, alice, delegateA);
        _assertWeightEq(current, delegateB, 0);
        _assertWeightEq(next, delegateA, 0);
        _assertDelegateMatchesVlCVX(next, alice, delegateB);
    }

    function test_syncAfterDelegateRemovalStillCreditsCurrentEpochDelegate() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpToNextEpoch();

        uint256 current = _currentEpochIdx();
        uint256 next = _nextEpoch();

        vm.prank(alice);
        delegation.setDelegate(address(0));

        _lock(alice, 500 * WD);
        delegation.sync(alice);

        assertEq(delegation.getDelegateAtEpoch(alice, current), delegateA);
        assertEq(delegation.getDelegateAtEpoch(alice, next), address(0));
        _assertDelegateMatchesVlCVX(current, alice, delegateA);
        _assertWeightEq(next, delegateA, 0);
    }

    function test_setDelegateDoesNotIncludeCurrentEpoch() public {
        _lock(alice, 1000 * WD);

        _warpToNextEpoch();

        uint256 current = _currentEpochIdx();

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        assertEq(delegation.balanceAtEpochOf(current, delegateA), 0);
        assertEq(delegation.getUserWeight(alice), 0);
    }

    // ============================================================
    // EPOCH COUNT
    // ============================================================

    function test_epochCount() public view {
        assertGt(delegation.epochCount(), 0);
    }

    // ============================================================
    // balanceAtEpochOf / userWeightAtEpochOf
    // ============================================================

    function test_balanceAtEpochOf() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        uint256 next = _nextEpoch();

        _assertWeightEq(next, delegateA, 1000 * WD);
        _assertWeightEq(next + 5, delegateA, 1000 * WD);
    }

    function test_weightsWalkThroughExpiryTogether() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegateA);

        _warpToNextEpoch();
        _lock(alice, 500 * WD);

        _warpToNextEpoch();
        _lock(alice, 300 * WD);

        delegation.sync(alice);

        uint256 startEpoch = _nextEpoch();

        for (uint256 e = startEpoch; e < startEpoch + 22; e++) {
            _warpToNextEpoch();
            _processExpired(alice);
            delegation.sync(alice);

            uint256 vlcvxBal = _vlCVXBalanceAtEpoch(e, alice);
            uint256 delWeight = delegation.userWeightAtEpochOf(e, alice);
            uint256 tol = WD;
            if (vlcvxBal > delWeight) {
                assertLe(vlcvxBal - delWeight, tol, string(abi.encodePacked("mismatch at epoch ", vm.toString(e))));
            } else {
                assertLe(delWeight - vlcvxBal, tol, string(abi.encodePacked("mismatch at epoch ", vm.toString(e))));
            }

            uint256 delBal = delegation.balanceAtEpochOf(e, delegateA);
            if (vlcvxBal > delBal) {
                assertLe(vlcvxBal - delBal, tol);
            } else {
                assertLe(delBal - vlcvxBal, tol);
            }
        }

        uint256 finalEpoch = startEpoch + 21;
        assertEq(_vlCVXBalanceAtEpoch(finalEpoch, alice), 0);
        assertEq(delegation.userWeightAtEpochOf(finalEpoch, alice), 0);
        assertEq(delegation.balanceAtEpochOf(finalEpoch, delegateA), 0);
    }
}
