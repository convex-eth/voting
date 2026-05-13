// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ResupplyVoteExecutor.sol";
import "../src/DaoVotePlatform.sol";
import "../src/Delegation.sol";
import "../src/SurrogateRegistry.sol";
import "../src/interface/IvlCVX.sol";
import "./mocks/simpleVlCvx.sol";

contract MockResupplyStaker is IResupplyStaker {
    address public lastTarget;
    bytes public lastData;
    uint256 public callCount;
    uint256 public claimAndStakeCallCount;

    function safeExecute(address target, bytes calldata data) external returns (bytes memory) {
        lastTarget = target;
        lastData = data;
        callCount++;
        return "";
    }

    function claimAndStake() external returns (uint256 amount) {
        claimAndStakeCallCount++;
        return 1000;
    }
}

contract ResupplyVoteExecutorTest is Test {
    IvlCVX internal vlcvx;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    DaoVotePlatform internal daoVotePlatform;
    ResupplyVoteExecutor internal executor;
    MockResupplyStaker internal mockStaker;

    address internal alice = makeAddr("alice");
    address internal operator = makeAddr("operator");
    address internal guardian = makeAddr("guardian");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WD = 1e17;

    address constant RESUPPLY_STAKER = 0xCCCCCccc94bFeCDd365b4Ee6B86108fC91848901;
    address constant RESUPPLY_VOTER = 0x11111111063874cE8dC6232cb5C1C849359476E6;

    function setUp() public {
        vm.warp(1700000000);

        simpleVlCvx impl = new simpleVlCvx();
        vlcvx = IvlCVX(address(impl));
        delegation = new Delegation("Convex Delegation", address(vlcvx));
        surrogateRegistry = new SurrogateRegistry("Convex Surrogate Registry");

        daoVotePlatform = new DaoVotePlatform("Convex Dao Voting", 
            address(this),
            address(vlcvx),
            address(surrogateRegistry),
            address(delegation)
        );

        daoVotePlatform.setOperator(operator, true);

        mockStaker = new MockResupplyStaker();
        vm.etch(RESUPPLY_STAKER, address(mockStaker).code);

        executor = new ResupplyVoteExecutor("Resupply Vote Executor", address(this), address(daoVotePlatform), 0);
        executor.setGuardian(guardian, true);

        // Ensure the mock is set at the constant address
        require(RESUPPLY_STAKER.code.length > 0, "Mock not etched");
    }

    function _lockAndDelegate(address user, uint256 amount, address delegateAddr) internal {
        vlcvx.lock(user, amount * WD, 0);
        if (delegateAddr != address(0)) {
            vm.prank(user);
            delegation.setDelegate(delegateAddr);
        }
    }

    function _warpToNextEpoch() internal {
        uint256 currentEpoch = (vm.getBlockTimestamp() / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);
    }

    function _createProposal() internal returns (uint256) {
        uint256 startTime = vm.getBlockTimestamp() + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        daoVotePlatform.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Ownership, 1);
        uint256 pid = daoVotePlatform.proposalCount() - 1;
        vm.warp(startTime);
        return pid;
    }

    function _finalizeProposal(uint256 pid) internal {
        (, uint256 endTime,,,) = daoVotePlatform.proposals(pid);
        vm.warp(endTime + 13 hours);
    }

    function _finishProposal(uint256 pid) internal {
        (, uint256 endTime,,,) = daoVotePlatform.proposals(pid);
        vm.warp(endTime + 1);
    }

    function _voteYes(address user) internal {
        vm.prank(user);
        daoVotePlatform.vote(user, 10000, 0);
    }

    function test_executeDaoVote() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _voteYes(alice);
        _finalizeProposal(pid);

        executor.executeDaoVote(pid);

        assertTrue(executor.isDone(pid));
    }

    function test_revertIfNotFinished() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _voteYes(alice);

        vm.expectRevert(ResupplyVoteExecutor.NotFinished.selector);
        executor.executeDaoVote(pid);
    }

    function test_revertIfAlreadyExecuted() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _voteYes(alice);
        _finalizeProposal(pid);

        executor.executeDaoVote(pid);

        vm.expectRevert(ResupplyVoteExecutor.AlreadyExecuted.selector);
        executor.executeDaoVote(pid);
    }

    function test_anyoneCanExecute() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _voteYes(alice);
        _finalizeProposal(pid);

        vm.prank(alice);
        executor.executeDaoVote(pid);

        assertTrue(executor.isDone(pid));
    }

    function test_guardianCanExecuteAfterFinished() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _voteYes(alice);
        _finishProposal(pid);

        assertTrue(daoVotePlatform.isFinished(pid));
        assertFalse(daoVotePlatform.isFinalized(pid));

        vm.prank(guardian);
        executor.executeDaoVote(pid);

        assertTrue(executor.isDone(pid));
    }

    function test_nonGuardianCannotExecuteBeforeFinalized() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _voteYes(alice);
        _finishProposal(pid);

        vm.prank(alice);
        vm.expectRevert(ResupplyVoteExecutor.NotFinished.selector);
        executor.executeDaoVote(pid);
    }

    function test_setGuardian() public {
        address newGuardian = makeAddr("newGuardian");
        assertFalse(executor.guardians(newGuardian));

        executor.setGuardian(newGuardian, true);
        assertTrue(executor.guardians(newGuardian));

        executor.setGuardian(newGuardian, false);
        assertFalse(executor.guardians(newGuardian));
    }

    function test_onlyOwnerCanSetGuardian() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        executor.setGuardian(makeAddr("guardian"), true);
    }

    function test_setQuorum() public {
        assertEq(executor.quorumBps(), 0);

        executor.setQuorum(1000);
        assertEq(executor.quorumBps(), 1000);
    }

    function test_quorumNotMetWhenTotalSupplyZero() public {
        _warpToNextEpoch();

        executor.setQuorum(1000);

        uint256 pid = _createProposal();
        _finalizeProposal(pid);

        vm.expectRevert();
        executor.executeDaoVote(pid);
    }

    function test_onlyOwnerCanSetQuorum() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        executor.setQuorum(1000);
    }

    function test_setQuorumCannotExceedMax() public {
        vm.expectRevert(ResupplyVoteExecutor.InvalidQuorum.selector);
        executor.setQuorum(10001);
    }

    function test_cannotConstructWithQuorumAboveBps() public {
        vm.expectRevert(ResupplyVoteExecutor.InvalidQuorum.selector);
        new ResupplyVoteExecutor("Resupply Vote Executor", address(this), address(daoVotePlatform), 10001);
    }

    function test_eventEmitted() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _voteYes(alice);
        _finalizeProposal(pid);

        vm.expectEmit(true, false, false, false);
        emit ResupplyVoteExecutor.DaoVoteExecuted(pid, 10000, 0);
        executor.executeDaoVote(pid);
    }
}
