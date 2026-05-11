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
        delegation = new Delegation(address(vlcvx));
        surrogateRegistry = new SurrogateRegistry();

        dao = new DaoVotePlatform(
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

    function test_syncRelockVoteEdgeCase() public {
        vm.prank(alice);
        delegation.setDelegate(delegate1);

        _lock(alice, 1000 * WD);
        _lock(delegate1, 500 * WD);

        uint256 currentEpoch = (vm.getBlockTimestamp() / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);

        uint256 startTime = vm.getBlockTimestamp() + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Parameter, 1);
        uint256 pid = dao.proposalCount() - 1;
        vm.warp(startTime);

        (,, uint48 propEpoch,,) = dao.proposals(pid);

        vm.prank(delegate1);
        dao.vote(delegate1, 10000, 0);

        delegation.sync(alice);

        _relock(alice, 500 * WD);

        vm.prank(alice);
        dao.vote(alice, 10000, 0);

        uint256 voteTotals = dao.voteTotals(pid);
        uint256 yes = dao.getYes(pid);
        uint256 no = dao.getNo(pid);

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

        vm.warp(vm.getBlockTimestamp() + WEEK * 17);

        _relock(alice, 800 * WD);

        uint256 startTime = vm.getBlockTimestamp() + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Parameter, 1);
        uint256 pid = dao.proposalCount() - 1;
        vm.warp(startTime);

        delegation.sync(alice);

        vm.prank(delegate1);
        dao.vote(delegate1, 10000, 0);

        vm.prank(alice);
        dao.vote(alice, 10000, 0);

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

    function test_syncAtEpochAfterExpiryNoRevert() public {
        _lock(alice, 1000 * WD);

        vm.prank(alice);
        delegation.setDelegate(delegate1);

        vm.warp(vm.getBlockTimestamp() + WEEK * 2);

        delegation.sync(alice);

        uint256 currentEpoch = vlcvx.findEpochId(vm.getBlockTimestamp());

        vm.warp(vm.getBlockTimestamp() + WEEK * 17);

        delegation.syncAtEpoch(alice, currentEpoch);

        uint256 weight = delegation.userWeightAtEpochOf(currentEpoch, alice);
        assertEq(weight, 1000 * WD);
    }
}
