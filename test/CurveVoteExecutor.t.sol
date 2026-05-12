// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/DaoVotePlatform.sol";
import "../src/SurrogateRegistry.sol";
import "../src/Delegation.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "../src/CurveVoteExecutor.sol";
import "../src/interface/IvlCVX.sol";
import "./mocks/simpleVlCvx.sol";
import "./mocks/MockVoteDelegationExtension.sol";

contract CurveVoteExecutorTest is Test {
    IvlCVX internal vlcvx;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    DaoVotePlatform internal dao;
    CurveVoteExecutor internal executor;
    MockVoteDelegationExtension internal voteDelegate;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal operator = makeAddr("operator");
    address internal guardian = makeAddr("guardian");

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

        voteDelegate = new MockVoteDelegationExtension();
        executor = new CurveVoteExecutor(address(this), address(dao), address(voteDelegate), 0);
        executor.setGuardian(guardian, true);
    }

    function _lockAndDelegate(address user, uint256 amount, address delegateAddr) internal {
        vlcvx.lock(user, amount * WD, 0);
        if (delegateAddr != address(0)) {
            vm.prank(user);
            delegation.setDelegate(delegateAddr);
        }
    }

    function _warpToNextEpoch() internal {
        uint256 currentEpoch = (block.timestamp / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);
    }

    function _createProposal(DaoVotePlatform.VoteType vt, uint256 proposalId) internal returns (uint256) {
        uint256 startTime = vm.getBlockTimestamp() + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        dao.createProposal(startTime, endTime, vt, proposalId);
        uint256 pid = dao.proposalCount() - 1;
        vm.warp(startTime);
        return pid;
    }

    function _finalizeProposal(uint256 pid) internal {
        (, uint256 endTime,,,) = dao.proposals(pid);
        vm.warp(endTime + dao.finalizationTime() + 1);
    }

    function _finishProposal(uint256 pid) internal {
        (, uint256 endTime,,,) = dao.proposals(pid);
        vm.warp(endTime + 1);
    }

    function _voteYes(address user) internal {
        vm.prank(user);
        dao.vote(user, 10000, 0);
    }

    function _voteNo(address user) internal {
        vm.prank(user);
        dao.vote(user, 0, 10000);
    }

    function _vote(address user, uint256 yw, uint256 nw) internal {
        vm.prank(user);
        dao.vote(user, yw, nw);
    }

    // ========== Access Control ==========

    function test_anyoneCanExecuteAfterFinalized() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 42);
        _voteYes(alice);
        _finalizeProposal(pid);

        vm.prank(alice);
        executor.executeDaoVote(pid);

        assertEq(voteDelegate.daoCallCount(), 1);
    }

    function test_guardianCanExecuteAfterFinished() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 42);
        _voteYes(alice);
        _finishProposal(pid);

        assertFalse(dao.isFinalized(pid));
        assertTrue(dao.isFinished(pid));

        vm.prank(guardian);
        executor.executeDaoVote(pid);

        assertEq(voteDelegate.daoCallCount(), 1);
    }

    function test_nonGuardianCannotExecuteBeforeFinalized() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 42);
        _voteYes(alice);
        _finishProposal(pid);

        vm.prank(alice);
        vm.expectRevert(CurveVoteExecutor.NotFinished.selector);
        executor.executeDaoVote(pid);
    }

    // ========== State Checks ==========

    function test_revertIfNotFinished() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 42);
        _voteYes(alice);

        vm.expectRevert(CurveVoteExecutor.NotFinished.selector);
        executor.executeDaoVote(pid);
    }

    function test_revertIfAlreadyExecuted() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 42);
        _voteYes(alice);
        _finalizeProposal(pid);

        executor.executeDaoVote(pid);

        vm.expectRevert(CurveVoteExecutor.AlreadyExecuted.selector);
        executor.executeDaoVote(pid);
    }

    // ========== Vote Data ==========

    function test_sendsCorrectYesNoTotals() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 500, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 42);
        _vote(alice, 6000, 4000);
        _vote(bob, 2000, 8000);
        _finalizeProposal(pid);

        uint256 yesTotal = dao.getYes(pid);
        uint256 noTotal = dao.getNo(pid);
        uint256 total = yesTotal + noTotal;
        uint256 expectedYay = yesTotal * 10000 / total;

        executor.executeDaoVote(pid);

        assertEq(voteDelegate.lastVoteId(), 42);
        assertEq(voteDelegate.lastYay(), expectedYay);
        assertEq(voteDelegate.lastNay(), 10000 - expectedYay);
        assertFalse(voteDelegate.lastIsOwnership());
    }

    function test_ownershipTypeSendsTrue() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Ownership, 99);
        _voteYes(alice);
        _finalizeProposal(pid);

        executor.executeDaoVote(pid);

        assertEq(voteDelegate.lastVoteId(), 99);
        assertEq(voteDelegate.lastYay(), 10000);
        assertEq(voteDelegate.lastNay(), 0);
        assertTrue(voteDelegate.lastIsOwnership());
    }

    function test_parameterTypeSendsFalse() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 7);
        _voteNo(alice);
        _finalizeProposal(pid);

        executor.executeDaoVote(pid);

        assertEq(voteDelegate.lastYay(), 0);
        assertEq(voteDelegate.lastNay(), 10000);
        assertFalse(voteDelegate.lastIsOwnership());
    }

    function test_yayNayAlwaysSumTo10000() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 777, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 1);
        _vote(alice, 3333, 6667);
        _vote(bob, 5000, 5000);
        _finalizeProposal(pid);

        executor.executeDaoVote(pid);

        assertEq(voteDelegate.lastYay() + voteDelegate.lastNay(), 10000);
    }

    // ========== isDone ==========

    function test_isDoneFalseBeforeExecution() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 1);
        _voteYes(alice);
        _finalizeProposal(pid);

        assertFalse(executor.isDone(pid));
    }

    function test_isDoneTrueAfterExecution() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 1);
        _voteYes(alice);
        _finalizeProposal(pid);

        executor.executeDaoVote(pid);

        assertTrue(executor.isDone(pid));
    }

    // ========== Multiple proposals ==========

    function test_canExecuteMultipleProposals() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();

        uint256 pid0 = _createProposal(DaoVotePlatform.VoteType.Parameter, 10);
        _voteYes(alice);
        _finalizeProposal(pid0);

        _warpToNextEpoch();
        uint256 pid1 = _createProposal(DaoVotePlatform.VoteType.Ownership, 20);
        _voteNo(alice);
        _finalizeProposal(pid1);

        executor.executeDaoVote(pid0);
        assertEq(voteDelegate.lastVoteId(), 10);
        assertFalse(voteDelegate.lastIsOwnership());
        assertTrue(executor.isDone(pid0));
        assertFalse(executor.isDone(pid1));

        executor.executeDaoVote(pid1);
        assertEq(voteDelegate.lastVoteId(), 20);
        assertTrue(voteDelegate.lastIsOwnership());
        assertTrue(executor.isDone(pid1));
    }

    // ========== Out of order ==========

    function test_canExecuteOlderProposalAfterNewer() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();

        uint256 pid0 = _createProposal(DaoVotePlatform.VoteType.Parameter, 1);
        _voteYes(alice);
        _finalizeProposal(pid0);

        _warpToNextEpoch();
        uint256 pid1 = _createProposal(DaoVotePlatform.VoteType.Parameter, 2);
        _voteNo(alice);
        _finalizeProposal(pid1);

        executor.executeDaoVote(pid1);
        assertTrue(executor.isDone(pid1));
        assertFalse(executor.isDone(pid0));

        executor.executeDaoVote(pid0);
        assertTrue(executor.isDone(pid0));
    }

    // ========== Events ==========

    function test_daoVoteExecutedEvent() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Ownership, 5);
        _voteYes(alice);
        _finalizeProposal(pid);

        vm.expectEmit(true, false, false, false);
        emit CurveVoteExecutor.DaoVoteExecuted(pid, dao.getYes(pid), dao.getNo(pid), true);
        executor.executeDaoVote(pid);
    }

    // ========== Guardian management ==========

    function test_setGuardian() public {
        address newGuard = makeAddr("newGuard");
        executor.setGuardian(newGuard, true);
        assertTrue(executor.guardians(newGuard));
    }

    function test_removeGuardian() public {
        executor.setGuardian(guardian, false);
        assertFalse(executor.guardians(guardian));
    }

    function test_setGuardianOnlyOwner() public {
        address newGuard = makeAddr("newGuard");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        executor.setGuardian(newGuard, true);
    }

    // ========== Quorum ==========

    function test_quorumMet() public {
        _lockAndDelegate(alice, 500, address(0));
        _lockAndDelegate(bob, 500, address(0));
        _warpToNextEpoch();

        executor.setQuorum(1500);

        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 1);
        _voteYes(alice);
        _voteNo(bob);
        _finalizeProposal(pid);

        executor.executeDaoVote(pid);
        assertTrue(executor.isDone(pid));
    }

    function test_quorumNotMet() public {
        _lockAndDelegate(alice, 500, address(0));
        _lockAndDelegate(bob, 500, address(0));
        _warpToNextEpoch();

        executor.setQuorum(6000);

        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 1);
        _voteYes(alice);
        _finalizeProposal(pid);

        vm.expectRevert(CurveVoteExecutor.QuorumNotMet.selector);
        executor.executeDaoVote(pid);
    }

    function test_quorumNotMetWhenTotalSupplyZero() public {
        _warpToNextEpoch();

        executor.setQuorum(1000);

        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 1);
        _finalizeProposal(pid);

        vm.expectRevert();
        executor.executeDaoVote(pid);
    }

    function test_quorumZeroAlwaysPasses() public {
        _lockAndDelegate(alice, 100, address(0));
        _warpToNextEpoch();

        assertEq(executor.quorumBps(), 0);

        uint256 pid = _createProposal(DaoVotePlatform.VoteType.Parameter, 1);
        _voteYes(alice);
        _finalizeProposal(pid);

        executor.executeDaoVote(pid);
        assertTrue(executor.isDone(pid));
    }

    function test_setQuorumOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        executor.setQuorum(1000);
    }

    function test_setQuorumCannotExceedMax() public {
        vm.expectRevert(CurveVoteExecutor.InvalidQuorum.selector);
        executor.setQuorum(10001);
    }

    function test_cannotConstructWithQuorumAboveBps() public {
        vm.expectRevert(CurveVoteExecutor.InvalidQuorum.selector);
        new CurveVoteExecutor(address(this), address(dao), address(voteDelegate), 10001);
    }
}
