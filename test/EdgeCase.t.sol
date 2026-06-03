// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/DaoVotePlatform.sol";
import "../src/SurrogateRegistry.sol";
import "../src/Delegation.sol";
import "../src/interface/IvlCVX.sol";
import "./mocks/simpleVlCvx.sol";

contract EdgeCaseTest is Test {
    IvlCVX internal vlcvx;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    DaoVotePlatform internal dao;

    address internal alice = makeAddr("alice");
    address internal delegate1 = makeAddr("delegate1");
    address internal operator = makeAddr("operator");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WD = 1e17;

    function setUp() public {
        vm.warp(1700000000);

        simpleVlCvx impl = new simpleVlCvx();
        vlcvx = IvlCVX(address(impl));
        delegation = new Delegation("Convex Delegation", address(this), address(vlcvx));
        surrogateRegistry = new SurrogateRegistry("Convex Surrogate Registry");

        dao = new DaoVotePlatform("Convex Dao Voting", 
            address(this),
            address(vlcvx),
            address(surrogateRegistry),
            address(delegation)
        );

        dao.setOperator(operator, true);
    }

    function _lock(address user, uint256 amount) internal {
        vlcvx.lock(user, amount, 0);
    }

    function _relock(address user, uint256 amount) internal {
        vm.prank(user);
        simpleVlCvx(address(vlcvx)).relock(user, amount, 0);
    }

    function _warpToNextEpoch() internal {
        uint256 ce = (block.timestamp / WEEK) * WEEK;
        vm.warp(ce + WEEK + 1);
    }

    function test_syncRelockVoteEdgeCase() public {
        vm.prank(alice);
        delegation.setDelegate(delegate1);

        _lock(alice, 1000 * WD);
        _lock(delegate1, 500 * WD);

        vm.warp(block.timestamp + WEEK * 17);

        vm.expectRevert(abi.encodeWithSignature("ExpiredLocks()"));
        delegation.sync(alice);

        _relock(alice, 800 * WD);

        delegation.sync(alice);

        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Parameter, 1);
        uint256 pid = dao.proposalCount() - 1;
        vm.warp(startTime);

        vm.prank(delegate1);
        dao.vote(pid, delegate1, 10000, 0);

        vm.prank(alice);
        dao.vote(pid, alice, 10000, 0);

        uint256 voteTotals = dao.voteTotals(pid);

        uint256 sumEffective;
        uint256 voterCount = dao.getVoterCount(pid);
        for (uint256 i = 0; i < voterCount; i++) {
            address voter = dao.getVoterAtIndex(pid, i);
            (,,, uint256 baseWeight, int256 adjustedWeight) = dao.getVote(pid, voter);
            int256 effective = int256(baseWeight) + adjustedWeight;
            if (effective > 0) sumEffective += uint256(effective);
        }

        assertEq(voteTotals, sumEffective, "vote totals mismatch");
    }

    function test_syncExpiredRelockVote() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegate1);

        _lock(delegate1, 500 * WD);

        vm.warp(block.timestamp + WEEK * 17);

        _relock(alice, 800 * WD);

        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Parameter, 1);
        uint256 pid = dao.proposalCount() - 1;
        vm.warp(startTime);

        delegation.sync(alice);

        vm.prank(delegate1);
        dao.vote(pid, delegate1, 10000, 0);

        vm.prank(alice);
        dao.vote(pid, alice, 10000, 0);

        uint256 voteTotals = dao.voteTotals(pid);

        uint256 sumEffective;
        uint256 voterCount = dao.getVoterCount(pid);
        for (uint256 i = 0; i < voterCount; i++) {
            address voter = dao.getVoterAtIndex(pid, i);
            (,,, uint256 baseWeight, int256 adjustedWeight) = dao.getVote(pid, voter);
            int256 effective = int256(baseWeight) + adjustedWeight;
            if (effective > 0) sumEffective += uint256(effective);
        }

        assertEq(voteTotals, sumEffective, "vote totals mismatch");
    }

    function test_syncAtEpochRevertsOnExpiredLocks() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegate1);

        _warpToNextEpoch();
        delegation.sync(alice);

        uint256 currentEpoch = vlcvx.findEpochId(block.timestamp);

        vm.warp(block.timestamp + WEEK * 17);

        vm.expectRevert(abi.encodeWithSignature("ExpiredLocks()"));
        delegation.syncAtEpoch(alice, currentEpoch);
    }

    function test_syncRevertsOnExpiredLocks() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegate1);

        _warpToNextEpoch();
        delegation.sync(alice);

        vm.warp(block.timestamp + WEEK * 17);

        vm.expectRevert(abi.encodeWithSignature("ExpiredLocks()"));
        delegation.sync(alice);
    }

    function test_relockWithoutExpiredReverts() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        vm.expectRevert("no expired locks");
        simpleVlCvx(address(vlcvx)).relock(alice, 500 * WD, 0);
    }

    // === Gap #2: syncAtEpoch with no delegate history ===

    function test_syncAtEpochNoDelegateHistoryNoOp() public {
        _lock(alice, 1000 * WD);
        _warpToNextEpoch();
        delegation.syncAtEpoch(alice, 0);
        assertEq(delegation.userWeightAtEpochOf(0, alice), 0);
    }

    // === Gap #3: syncAtEpoch when delegate at that epoch is address(0) ===

    function test_syncAtEpochRemovedDelegateNoOp() public {
        _lock(alice, 1000 * WD);
        vm.prank(alice);
        delegation.setDelegate(delegate1);
        _warpToNextEpoch();
        delegation.sync(alice);

        vm.prank(alice);
        delegation.setDelegate(address(0));
        _warpToNextEpoch();

        delegation.syncAtEpoch(alice, 0);

        assertEq(delegation.userWeightAtEpochOf(0, alice), 0);
    }

    // === Gap #4: sync() with currentDelegate == address(0) + futureDelegate != address(0) ===

    function test_syncDelegateOnlyFutureWhenCurrentIsZero() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegate1);

        delegation.sync(alice);

        assertEq(delegation.getDelegateAtEpoch(alice, 0), address(0));
    }
}
