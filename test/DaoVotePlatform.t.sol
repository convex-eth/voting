// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/DaoVotePlatform.sol";
import "../src/SurrogateRegistry.sol";
import "../src/Delegation.sol";
import "./mocks/MockVlCVX.sol";

contract DaoVotePlatformTest is Test {
    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    DaoVotePlatform internal dao;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve");
    address internal operator = makeAddr("operator");
    address internal surrogate = makeAddr("surrogate");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WD = 1e17;

    uint256 internal proposalEpoch;

    function setUp() public {
        vm.warp(WEEK * 2);

        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));
        surrogateRegistry = new SurrogateRegistry();

        dao = new DaoVotePlatform(
            address(mockVlCVX),
            address(surrogateRegistry),
            address(delegation)
        );

        dao.setOperator(operator, true);
    }

    function _lockAndDelegate(address user, uint256 amount, address delegateAddr) internal {
        mockVlCVX.mockLock(user, amount * WD, amount * WD);
        if (delegateAddr != address(0)) {
            vm.prank(user);
            delegation.setDelegate(delegateAddr);
        }
    }

    function _warpToNextEpoch() internal {
        uint256 currentEpoch = (block.timestamp / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);
    }

    function _createProposal() internal returns (uint256) {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Parameter, 1);
        uint256 pid = dao.proposalCount() - 1;
        (,, proposalEpoch,,) = dao.proposals(pid);
        vm.warp(startTime);
        return pid;
    }

    function _finalizeProposal(uint256 pid) internal {
        (, uint256 endTime,,,) = dao.proposals(pid);
        vm.warp(endTime + dao.finalizationTime() + 1);
    }

    function _voteYes(address user) internal {
        vm.prank(user);
        dao.vote(user, 10000, 0);
    }

    function _voteNo(address user) internal {
        vm.prank(user);
        dao.vote(user, 0, 10000);
    }

    function _vote(address user, uint256 yesW, uint256 noW) internal {
        vm.prank(user);
        dao.vote(user, yesW, noW);
    }

    function _voteSurrogate(address signer, address user, uint256 yesW, uint256 noW) internal {
        vm.prank(signer);
        dao.vote(user, yesW, noW);
    }

    // ========== Proposal Tests ==========

    function test_createProposal() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Ownership, 42);

        (uint256 s, uint256 e,, uint8 vt, uint256 pId) = dao.proposals(0);
        assertEq(s, startTime);
        assertEq(e, endTime);
        assertEq(vt, uint8(DaoVotePlatform.VoteType.Ownership));
        assertEq(pId, 42);
    }

    function test_createProposalParameterType() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Parameter, 99);

        (,,, uint8 vt, uint256 pId) = dao.proposals(0);
        assertEq(vt, uint8(DaoVotePlatform.VoteType.Parameter));
        assertEq(pId, 99);
    }

    function test_cannotCreateProposalTooShort() public {
        uint256 startTime = block.timestamp + 1 days;
        vm.prank(operator);
        vm.expectRevert(DaoVotePlatform.BadTime.selector);
        dao.createProposal(startTime, startTime + 2 days, DaoVotePlatform.VoteType.Parameter, 1);
    }

    function test_cannotCreateProposalTooLong() public {
        uint256 startTime = block.timestamp + 1 days;
        vm.prank(operator);
        vm.expectRevert(DaoVotePlatform.BadTime.selector);
        dao.createProposal(startTime, startTime + 7 days, DaoVotePlatform.VoteType.Parameter, 1);
    }

    function test_cannotCreateBeforePreviousEnds() public {
        uint256 pid = _createProposal();
        vm.prank(operator);
        vm.expectRevert(DaoVotePlatform.PrevNotEnded.selector);
        dao.createProposal(block.timestamp + 5 days, block.timestamp + 9 days, DaoVotePlatform.VoteType.Parameter, 1);
    }

    function test_forceEndProposal() public {
        uint256 pid = _createProposal();
        vm.prank(operator);
        dao.forceEndProposal();

        (uint256 s, uint256 e, uint256 ep,,) = dao.proposals(pid);
        assertEq(s, 0);
        assertEq(e, 0);
        assertEq(ep, 0);
    }

    function test_forceEndDuringFinalizationWindow() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _voteYes(alice);

        (, uint256 endTime,,,) = dao.proposals(pid);
        vm.warp(endTime + 6 hours);

        vm.prank(operator);
        dao.forceEndProposal();
    }

    function test_cannotForceEndAfterFinalized() public {
        uint256 pid = _createProposal();
        _finalizeProposal(pid);

        vm.prank(operator);
        vm.expectRevert(DaoVotePlatform.Ended.selector);
        dao.forceEndProposal();
    }

    function test_isFinalized() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _voteYes(alice);

        (, uint256 endTime,,,) = dao.proposals(pid);

        vm.warp(endTime + 6 hours);
        assertFalse(dao.isFinalized(pid));

        vm.warp(endTime + dao.finalizationTime() + 1);
        assertTrue(dao.isFinalized(pid));
    }

    function test_isFinished() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _voteYes(alice);

        (, uint256 endTime,,,) = dao.proposals(pid);

        vm.warp(endTime - 1);
        assertFalse(dao.isFinished(pid));

        vm.warp(endTime + 1);
        assertTrue(dao.isFinished(pid));
        assertFalse(dao.isFinalized(pid));

        vm.warp(endTime + dao.finalizationTime() + 1);
        assertTrue(dao.isFinished(pid));
        assertTrue(dao.isFinalized(pid));
    }

    function test_isFinalized_forceEnded() public {
        uint256 pid = _createProposal();
        vm.prank(operator);
        dao.forceEndProposal();

        assertFalse(dao.isFinalized(pid));
    }

    // ========== Basic Voting ==========

    function test_voteYes() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteYes(alice);

        assertEq(dao.getYes(pid), 1000 * WD);
        assertEq(dao.getNo(pid), 0);
        assertEq(dao.voteTotals(pid), 1000 * WD);
    }

    function test_voteNo() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteNo(alice);

        assertEq(dao.getYes(pid), 0);
        assertEq(dao.getNo(pid), 1000 * WD);
        assertEq(dao.voteTotals(pid), 1000 * WD);
    }

    function test_voteSplit() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, 6000, 4000);

        assertEq(dao.getYes(pid), 600 * WD);
        assertEq(dao.getNo(pid), 400 * WD);
        assertEq(dao.voteTotals(pid), 1000 * WD);
    }

    function test_cannotVoteAfterEndTime() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        (, uint256 endTime,,,) = dao.proposals(pid);
        vm.warp(endTime + 1);

        vm.prank(alice);
        vm.expectRevert(DaoVotePlatform.Ended.selector);
        dao.vote(alice, 10000, 0);
    }

    function test_cannotVoteBeforeStart() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();

        uint256 startTime = block.timestamp + 2 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Ownership, 1);

        vm.prank(alice);
        vm.expectRevert(DaoVotePlatform.NotStarted.selector);
        dao.vote(alice, 10000, 0);
    }

    function test_cannotVoteWithoutWeight() public {
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        vm.prank(alice);
        vm.expectRevert(DaoVotePlatform.NoWeight.selector);
        dao.vote(alice, 10000, 0);
    }

    function test_cannotExceedMaxWeight() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        vm.prank(alice);
        vm.expectRevert(DaoVotePlatform.MaxWeight.selector);
        dao.vote(alice, 6000, 5000);
    }

    function test_revoteYesToYes() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteYes(alice);
        assertEq(dao.getYes(pid), 1000 * WD);

        _voteYes(alice);
        assertEq(dao.getYes(pid), 1000 * WD);
        assertEq(dao.voteTotals(pid), 1000 * WD);
    }

    function test_revoteYesToNo() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteYes(alice);
        assertEq(dao.getYes(pid), 1000 * WD);
        assertEq(dao.getNo(pid), 0);

        _voteNo(alice);
        assertEq(dao.getYes(pid), 0);
        assertEq(dao.getNo(pid), 1000 * WD);
    }

    function test_revoteNoToYes() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteNo(alice);
        assertEq(dao.getNo(pid), 1000 * WD);

        _voteYes(alice);
        assertEq(dao.getYes(pid), 1000 * WD);
        assertEq(dao.getNo(pid), 0);
    }

    function test_revoteChangeSplit() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, 8000, 2000);
        assertEq(dao.getYes(pid), 800 * WD);
        assertEq(dao.getNo(pid), 200 * WD);

        _vote(alice, 3000, 7000);
        assertEq(dao.getYes(pid), 300 * WD);
        assertEq(dao.getNo(pid), 700 * WD);
        assertEq(dao.voteTotals(pid), 1000 * WD);
    }

    function test_multipleVoters() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 500, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteYes(alice);
        _voteNo(bob);

        assertEq(dao.getYes(pid), 1000 * WD);
        assertEq(dao.getNo(pid), 500 * WD);
        assertEq(dao.voteTotals(pid), 1500 * WD);
    }

    function test_multipleVotersSplit() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 500, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, 6000, 4000);
        _vote(bob, 2000, 8000);

        assertEq(dao.getYes(pid), 600 * WD + 100 * WD);
        assertEq(dao.getNo(pid), 400 * WD + 400 * WD);
        assertEq(dao.voteTotals(pid), 1500 * WD);
    }

    // ========== Delegation ==========

    function test_delegateeVotesThenDelegate() public {
        _lockAndDelegate(alice, 500, bob);
        _lockAndDelegate(bob, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteYes(alice);
        _vote(bob, 5000, 5000);

        assertEq(dao.getYes(pid), 500 * WD + 500 * WD);
        assertEq(dao.getNo(pid), 500 * WD);
        assertEq(dao.voteTotals(pid), 1500 * WD);

        (bool voted, uint256 yw, uint256 nw, uint256 bw, int256 aw) = dao.getVote(pid, bob);
        assertTrue(voted);
        assertEq(yw, 5000);
        assertEq(nw, 5000);
        assertEq(bw, 1000 * WD);
        assertEq(aw, 0);
    }

    function test_delegateVotesFirstThenDelegatee() public {
        _lockAndDelegate(alice, 500, bob);
        _lockAndDelegate(bob, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(bob, 5000, 5000);
        assertEq(dao.getYes(pid), 750 * WD);
        assertEq(dao.getNo(pid), 750 * WD);

        _voteNo(alice);

        assertEq(dao.getYes(pid), 500 * WD);
        assertEq(dao.getNo(pid), 1000 * WD);
    }

    function test_selfDelegatingNoAdjustedWeight() public {
        _lockAndDelegate(alice, 3000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteYes(alice);

        (bool voted, uint256 yw, uint256 nw, uint256 bw, int256 aw) = dao.getVote(pid, alice);
        assertTrue(voted);
        assertEq(yw, 10000);
        assertEq(nw, 0);
        assertEq(bw, 3000 * WD);
        assertEq(aw, 0);
        assertEq(dao.getYes(pid), 3000 * WD);
    }

    function test_pureDelegateSplitVote() public {
        _lockAndDelegate(alice, 1000, dave);
        _lockAndDelegate(bob, 500, dave);
        vm.prank(dave);
        mockVlCVX.mockLock(dave, 0, 0);
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(dave, 6000, 4000);

        uint256 yesAfterDave = dao.getYes(pid);
        uint256 noAfterDave = dao.getNo(pid);
        assertEq(yesAfterDave, 900 * WD);
        assertEq(noAfterDave, 600 * WD);

        _vote(alice, 3000, 7000);

        uint256 yesFinal = dao.getYes(pid);
        uint256 noFinal = dao.getNo(pid);

        uint256 totalFinal = yesFinal + noFinal;
        assertEq(totalFinal, 1000 * WD + 500 * WD + 1000 * WD - 1000 * WD);
    }

    // ========== Surrogate ==========

    function test_surrogateVote() public {
        _lockAndDelegate(alice, 1000, address(0));
        vm.prank(alice);
        surrogateRegistry.setSurrogate(surrogate);
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteSurrogate(surrogate, alice, 10000, 0);

        (bool voted, uint256 yw, uint256 nw,,) = dao.getVote(pid, alice);
        assertTrue(voted);
        assertEq(yw, 10000);
        assertEq(nw, 0);
        assertEq(dao.getYes(pid), 1000 * WD);
    }

    function test_userCanOverrideSurrogateVote() public {
        _lockAndDelegate(alice, 1000, address(0));
        vm.prank(alice);
        surrogateRegistry.setSurrogate(surrogate);
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteSurrogate(surrogate, alice, 10000, 0);

        _voteNo(alice);

        (bool voted, uint256 yw, uint256 nw,,) = dao.getVote(pid, alice);
        assertTrue(voted);
        assertEq(yw, 0);
        assertEq(nw, 10000);
        assertEq(dao.getYes(pid), 0);
        assertEq(dao.getNo(pid), 1000 * WD);
    }

    function test_surrogateCannotOverrideDirectVote() public {
        _lockAndDelegate(alice, 1000, address(0));
        vm.prank(alice);
        surrogateRegistry.setSurrogate(surrogate);
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteYes(alice);

        vm.prank(surrogate);
        vm.expectRevert(DaoVotePlatform.NotVoteAuth.selector);
        dao.vote(alice, 0, 10000);
    }

    function test_randomAddressCannotVoteForOthers() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        vm.prank(bob);
        vm.expectRevert(DaoVotePlatform.NotSigner.selector);
        dao.vote(alice, 10000, 0);
    }

    // ========== forceEnd ==========

    function test_forceEndDisablesVoting() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        vm.prank(operator);
        dao.forceEndProposal();

        vm.prank(alice);
        vm.expectRevert(DaoVotePlatform.Ended.selector);
        dao.vote(alice, 10000, 0);
    }

    // ========== View functions ==========

    function test_getVote() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, 6000, 4000);

        (bool voted, uint256 yw, uint256 nw, uint256 bw, int256 aw) = dao.getVote(pid, alice);
        assertTrue(voted);
        assertEq(yw, 6000);
        assertEq(nw, 4000);
        assertEq(bw, 1000 * WD);
        assertEq(aw, 0);
    }

    function test_getVoteNotVoted() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        (bool voted, uint256 yw, uint256 nw, uint256 bw, int256 aw) = dao.getVote(pid, alice);
        assertFalse(voted);
        assertEq(yw, 0);
        assertEq(nw, 0);
        assertEq(bw, 0);
        assertEq(aw, 0);
    }

    function test_proposalCount() public {
        assertEq(dao.proposalCount(), 0);
        _createProposal();
        assertEq(dao.proposalCount(), 1);
    }

    function test_getVoterCount() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 500, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _voteYes(alice);
        _voteNo(bob);

        assertEq(dao.getVoterCount(pid), 2);
    }

    // ========== Multiple proposals ==========

    function test_multipleProposals() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid0 = _createProposal();

        _voteYes(alice);
        assertEq(dao.getYes(pid0), 1000 * WD);

        _finalizeProposal(pid0);
        _warpToNextEpoch();

        uint256 pid1 = _createProposal();
        _voteNo(alice);
        assertEq(dao.getNo(pid1), 1000 * WD);
        assertEq(dao.getYes(pid0), 1000 * WD);
    }

    // ========== Operator ==========

    function test_onlyOperatorCanCreateProposal() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(alice);
        vm.expectRevert(DaoVotePlatform.NotOperator.selector);
        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Parameter, 1);
    }

    function test_setOperator() public {
        address newOp = makeAddr("newOp");
        dao.setOperator(newOp, true);
        assertTrue(dao.operators(newOp));
    }

    // ========== Delegate with split vote ==========
}