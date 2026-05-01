// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ResupplyVoteExecutor.sol";
import "../src/DaoVotePlatform.sol";
import "../src/Delegation.sol";
import "../src/SurrogateRegistry.sol";
import "./mocks/MockVlCVX.sol";

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
    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    DaoVotePlatform internal daoVotePlatform;
    ResupplyVoteExecutor internal executor;
    MockResupplyStaker internal mockStaker;

    address internal alice = makeAddr("alice");
    address internal operator = makeAddr("operator");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WD = 1e17;

    address constant RESUPPLY_STAKER = 0xCCCCCccc94bFeCDd365b4Ee6B86108fC91848901;
    address constant RESUPPLY_VOTER = 0x11111111063874cE8dC6232cb5C1C849359476E6;

    function setUp() public {
        vm.warp(WEEK * 2);

        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));
        surrogateRegistry = new SurrogateRegistry();

        daoVotePlatform = new DaoVotePlatform(
            address(this),
            address(mockVlCVX),
            address(surrogateRegistry),
            address(delegation)
        );

        daoVotePlatform.setOperator(operator, true);

        mockStaker = new MockResupplyStaker();
        vm.etch(RESUPPLY_STAKER, address(mockStaker).code);

        executor = new ResupplyVoteExecutor(address(this), address(daoVotePlatform), 0);

        // Ensure the mock is set at the constant address
        require(RESUPPLY_STAKER.code.length > 0, "Mock not etched");
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
        daoVotePlatform.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Ownership, 1);
        uint256 pid = daoVotePlatform.proposalCount() - 1;
        vm.warp(startTime);
        return pid;
    }

    function _finalizeProposal(uint256 pid) internal {
        (, uint256 endTime,,,) = daoVotePlatform.proposals(pid);
        vm.warp(endTime + 13 hours);
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

    function test_setGuardian() public {
        address guardian = makeAddr("guardian");
        assertFalse(executor.guardians(guardian));

        executor.setGuardian(guardian, true);
        assertTrue(executor.guardians(guardian));

        executor.setGuardian(guardian, false);
        assertFalse(executor.guardians(guardian));
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

    function test_onlyOwnerCanSetQuorum() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        executor.setQuorum(1000);
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
