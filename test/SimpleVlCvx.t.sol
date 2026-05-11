// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "./mocks/simpleVlCvx.sol";

contract SimpleVlCvxTest is Test {
    uint256 constant WEEK = 86400 * 7;
    uint256 constant LOCK_DURATION = WEEK * 16;

    simpleVlCvx internal vlcvx;
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1700000000);
        vlcvx = new simpleVlCvx();
    }

    function _currentEpoch() internal view returns (uint256) {
        return (block.timestamp / WEEK) * WEEK;
    }

    function _lockEpochOf(uint256 unlockTime) internal pure returns (uint256) {
        return unlockTime - LOCK_DURATION;
    }

    function _bal(address u) internal view returns (uint112 locked, uint112 boosted, uint32 nui) {
        (locked, boosted, nui) = vlcvx.balances(u);
    }

    function _lk(address u, uint256 i) internal view returns (uint112 amount, uint112 boosted, uint32 unlockTime) {
        (amount, boosted, unlockTime) = vlcvx.userLocks(u, i);
    }

    // === LOCK BASICS ===

    function test_lockCreatesEntry() public {
        vlcvx.lock(alice, 1000, 0);

        (uint112 locked, uint112 boosted, uint32 nui) = _bal(alice);
        assertEq(locked, 1000);
        assertEq(boosted, 1000);
        assertEq(nui, 0);
        assertEq(vlcvx.lockedSupply(), 1000);
        assertEq(vlcvx.boostedSupply(), 1000);

        (uint112 amt, uint112 bst, uint32 ut) = _lk(alice, 0);
        assertEq(amt, 1000);
        assertEq(bst, 1000);
        assertEq(ut, _currentEpoch() + WEEK + LOCK_DURATION);
    }

    function test_lockGoesToNextEpoch() public {
        uint256 currentEpoch = _currentEpoch();
        vlcvx.lock(alice, 1000, 0);
        (,, uint32 ut) = _lk(alice, 0);
        assertEq(_lockEpochOf(ut), currentEpoch + WEEK);
    }

    function test_pendingLockReturnsLockInNextEpoch() public {
        vlcvx.lock(alice, 1000, 0);
        assertEq(vlcvx.pendingLockOf(alice), 1000);
    }

    function test_pendingLockZeroAfterEpochPasses() public {
        vlcvx.lock(alice, 1000, 0);
        vm.warp(_currentEpoch() + WEEK + 1);
        assertEq(vlcvx.pendingLockOf(alice), 0);
    }

    function test_balanceAtEpochOf_afterLockBecomesActive() public {
        vlcvx.lock(alice, 1000, 0);
        (,, uint32 ut) = _lk(alice, 0);
        uint256 epochId = vlcvx.findEpochId(_lockEpochOf(ut));
        assertEq(vlcvx.balanceAtEpochOf(epochId, alice), 1000);
    }

    function test_balanceAtEpochOf_zeroBeforeActive() public {
        vlcvx.lock(alice, 1000, 0);
        uint256 currentEpochId = vlcvx.findEpochId(_currentEpoch());
        assertEq(vlcvx.balanceAtEpochOf(currentEpochId, alice), 0);
    }

    function test_balanceOf_zeroWhilePending() public {
        vlcvx.lock(alice, 1000, 0);
        assertEq(vlcvx.balanceOf(alice), 0);
    }

    function test_balanceOf_activeAfterEpochPasses() public {
        vlcvx.lock(alice, 1000, 0);
        vm.warp(_currentEpoch() + WEEK + 1);
        assertEq(vlcvx.balanceOf(alice), 1000);
    }

    // === EXPIRY ===

    function test_lockExpiresAfterLockDuration() public {
        vlcvx.lock(alice, 1000, 0);
        (,, uint32 ut) = _lk(alice, 0);

        uint256 lockEpoch = _lockEpochOf(ut);
        assertEq(lockEpoch, ut - LOCK_DURATION);

        vm.warp(ut + WEEK);
        vlcvx.checkpointEpoch();

        uint256 expiryEpoch = vlcvx.findEpochId(ut + WEEK);
        assertEq(vlcvx.balanceAtEpochOf(expiryEpoch, alice), 0);
    }

    function test_processExpiredLocks_updatesNextUnlockIndex() public {
        vlcvx.lock(alice, 1000, 0);
        (,, uint32 nuiBefore) = _bal(alice);
        assertEq(nuiBefore, 0);

        (,, uint32 ut) = _lk(alice, 0);
        vm.warp(ut);

        vm.prank(alice);
        vlcvx.processExpiredLocks();

        (uint112 locked, uint112 boosted, uint32 nuiAfter) = _bal(alice);
        assertEq(nuiAfter, 1);
        assertEq(locked, 0);
        assertEq(boosted, 0);
        assertEq(vlcvx.lockedSupply(), 0);
        assertEq(vlcvx.boostedSupply(), 0);
    }

    function test_processExpiredLocks_noExpiredLocks() public {
        vlcvx.lock(alice, 1000, 0);

        vm.prank(alice);
        vm.expectRevert("no expired locks");
        vlcvx.processExpiredLocks();
    }

    // === MULTIPLE LOCKS ===

    function test_secondLockInNextEpoch() public {
        vlcvx.lock(alice, 1000, 0);
        vm.warp(_currentEpoch() + WEEK + 1);
        vlcvx.lock(alice, 500, 0);

        (uint112 amt0,,) = _lk(alice, 0);
        (uint112 amt1,,) = _lk(alice, 1);
        assertEq(amt0, 1000);
        assertEq(amt1, 500);

        (uint112 locked, uint112 boosted, uint32 nui) = _bal(alice);
        assertEq(locked, 1500);
        assertEq(boosted, 1500);
        assertEq(nui, 0);
    }

    function test_partialExpiry_advancesNextUnlockIndex() public {
        vlcvx.lock(alice, 1000, 0);
        vm.warp(_currentEpoch() + WEEK + 1);
        vlcvx.lock(alice, 500, 0);

        (,, uint32 nuiBefore) = _bal(alice);
        assertEq(nuiBefore, 0);

        (,, uint32 ut0) = _lk(alice, 0);
        vm.warp(ut0);

        vm.prank(alice);
        vlcvx.processExpiredLocks();

        (uint112 locked, uint112 boosted, uint32 nuiAfter) = _bal(alice);
        assertEq(nuiAfter, 1);
        assertEq(locked, 500);
        assertEq(boosted, 500);
    }

    // === RELOCK ===

    function test_relockCreatesCurrentEpochEntry() public {
        vlcvx.lock(alice, 1000, 0);
        vm.warp(_currentEpoch() + WEEK * 17);

        vm.prank(alice);
        vlcvx.relock(alice, 800, 0);

        (,,, simpleVlCvx.LockedBalance[] memory lockData) = vlcvx.lockedBalances(alice);
        assertGt(lockData.length, 0);

        uint256 relockEpoch = _lockEpochOf(lockData[lockData.length - 1].unlockTime);
        assertEq(relockEpoch, _currentEpoch());
    }

    function test_relockAfterExpiry() public {
        vlcvx.lock(alice, 1000, 0);
        (,, uint32 ut) = _lk(alice, 0);
        vm.warp(ut + 1);

        assertEq(vlcvx.balanceOf(alice), 0);

        vm.prank(alice);
        vlcvx.relock(alice, 800, 0);

        assertEq(vlcvx.balanceOf(alice), 800);
        (,, uint32 nui) = _bal(alice);
        assertGt(nui, 0);
    }

    function test_relockAdvancesNextUnlockIndex() public {
        vlcvx.lock(alice, 1000, 0);
        (,, uint32 ut) = _lk(alice, 0);
        vm.warp(ut + 1);

        (,, uint32 nuiBefore) = _bal(alice);
        assertEq(nuiBefore, 0);

        vm.prank(alice);
        vlcvx.relock(alice, 800, 0);

        (,, uint32 nuiAfter) = _bal(alice);
        assertGt(nuiAfter, nuiBefore);
    }

    function test_relockPartialExpiry() public {
        vlcvx.lock(alice, 1000, 0);
        vm.warp(_currentEpoch() + WEEK + 1);
        vlcvx.lock(alice, 500, 0);

        (,, uint32 ut0) = _lk(alice, 0);
        vm.warp(ut0 + 1);

        (,, uint32 nuiBefore) = _bal(alice);
        assertEq(nuiBefore, 0);

        vm.prank(alice);
        vlcvx.relock(alice, 600, 0);

        (uint112 locked, uint112 boosted, uint32 nuiAfter) = _bal(alice);
        assertGt(nuiAfter, nuiBefore);
        assertEq(locked, 1100);
        assertEq(boosted, 1100);
    }

    function test_relockPreservesSecondLock() public {
        vlcvx.lock(alice, 1000, 0);
        vm.warp(_currentEpoch() + WEEK + 1);
        vlcvx.lock(alice, 500, 0);

        (,, uint32 ut0) = _lk(alice, 0);
        vm.warp(ut0 + 1);

        vm.prank(alice);
        vlcvx.relock(alice, 600, 0);

        assertEq(vlcvx.balanceOf(alice), 1100);
    }

    // === balanceAtEpochOf ===

    function test_balanceAtEpochOf_multipleLocks() public {
        vlcvx.lock(alice, 1000, 0);
        vm.warp(_currentEpoch() + WEEK + 1);
        vlcvx.lock(alice, 500, 0);

        (,, uint32 ut0) = _lk(alice, 0);
        (,, uint32 ut1) = _lk(alice, 1);

        uint256 epoch0 = vlcvx.findEpochId(_lockEpochOf(ut0));
        uint256 epoch1 = vlcvx.findEpochId(_lockEpochOf(ut1));

        assertEq(vlcvx.balanceAtEpochOf(epoch0, alice), 1000);
        assertEq(vlcvx.balanceAtEpochOf(epoch1, alice), 1500);
    }

    function test_balanceAtEpochOf_expiresOldLock() public {
        vlcvx.lock(alice, 1000, 0);
        vm.warp(_currentEpoch() + WEEK * 5 + 1);
        vlcvx.lock(alice, 500, 0);

        (,, uint32 ut0) = _lk(alice, 0);
        (,, uint32 ut1) = _lk(alice, 1);

        uint256 queryTime = _lockEpochOf(ut0) + LOCK_DURATION + WEEK;

        vm.warp(queryTime + 1);
        vlcvx.checkpointEpoch();

        uint256 afterExpiry = vlcvx.findEpochId(queryTime);

        assertEq(vlcvx.balanceAtEpochOf(afterExpiry, alice), 500);
    }

    // === SUPPLY ===

    function test_epochSupplyIncreasesOnLock() public {
        vlcvx.lock(alice, 1000, 0);
        (,, uint32 ut) = _lk(alice, 0);
        uint256 epochId = vlcvx.findEpochId(_lockEpochOf(ut));
        (uint224 supply,) = vlcvx.epochs(epochId);
        assertEq(supply, 1000);
    }

    function test_relockAddsToCurrentEpochSupply() public {
        vlcvx.lock(alice, 1000, 0);
        (,, uint32 ut) = _lk(alice, 0);
        vm.warp(ut + 1);

        uint256 currentEpoch = _currentEpoch();

        vm.prank(alice);
        vlcvx.relock(alice, 800, 0);

        uint256 epochId = vlcvx.findEpochId(currentEpoch);
        (uint224 supply,) = vlcvx.epochs(epochId);
        assertEq(supply, 800);
    }

    // === HISTORY PRESERVATION ===

    function test_relockDoesNotMutateOldLockEntries() public {
        vlcvx.lock(alice, 1000, 0);

        (uint112 origAmt, uint112 origBst, uint32 origUt) = _lk(alice, 0);

        vm.warp(_currentEpoch() + WEEK + 1);
        vlcvx.lock(alice, 500, 0);

        (uint112 amt1,, uint32 ut1) = _lk(alice, 1);

        vm.warp(_currentEpoch() + WEEK * 17 + 1);

        vm.prank(alice);
        vlcvx.relock(alice, 800, 0);

        (uint112 amt0, uint112 bst0, uint32 ut0) = _lk(alice, 0);
        assertEq(ut0, origUt);
        assertEq(amt0, origAmt);
        assertEq(bst0, origBst);

        (uint112 amt1After,, uint32 ut1After) = _lk(alice, 1);
        assertEq(ut1After, ut1);
        assertEq(amt1After, amt1);
    }

    function test_balanceAtEpochOf_stableAcrossRelocks() public {
        vlcvx.lock(alice, 1000, 0);
        (,, uint32 ut) = _lk(alice, 0);
        uint256 epochId = vlcvx.findEpochId(_lockEpochOf(ut));

        assertEq(vlcvx.balanceAtEpochOf(epochId, alice), 1000);

        vm.warp(_lockEpochOf(ut) + LOCK_DURATION + WEEK + 1);

        vm.prank(alice);
        vlcvx.relock(alice, 800, 0);

        assertEq(vlcvx.balanceAtEpochOf(epochId, alice), 1000);
    }
}
