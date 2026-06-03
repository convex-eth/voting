// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/CurveVoteExecutor.sol";
import "../src/DaoVotePlatform.sol";
import "../src/Delegation.sol";
import "../src/ResupplyVoteExecutor.sol";
import "../src/SurrogateRegistry.sol";
import "../src/interface/IvlCVX.sol";
import "./mocks/simpleVlCvx.sol";
import "./mocks/MockVoteDelegationExtension.sol";

contract ProtocolBoundaryMockResupplyStaker is IResupplyStaker {
    address public lastTarget;
    bytes public lastData;
    uint256 public callCount;

    function safeExecute(address target, bytes calldata data) external returns (bytes memory) {
        lastTarget = target;
        lastData = data;
        callCount++;
        return "";
    }

    function claimAndStake() external pure returns (uint256 amount) {
        return 0;
    }
}

contract DaoExecutorBoundaryFuzzTest is Test {
    uint256 internal constant WEEK = 86400 * 7;
    uint256 internal constant WD = 1e17;
    uint256 internal constant EXTERNAL_PROPOSAL_ID = 77;

    address internal constant RESUPPLY_STAKER = 0xCCCCCccc94bFeCDd365b4Ee6B86108fC91848901;
    address internal constant RESUPPLY_VOTER = 0x11111111063874cE8dC6232cb5C1C849359476E6;

    IvlCVX internal vlcvx;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    DaoVotePlatform internal daoPlatform;
    MockVoteDelegationExtension internal curveDelegate;
    CurveVoteExecutor internal curveExecutor;
    ResupplyVoteExecutor internal resupplyExecutor;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal operator = makeAddr("operator");

    function setUp() public {
        vm.warp(1700000000);

        simpleVlCvx impl = new simpleVlCvx();
        vlcvx = IvlCVX(address(impl));
        delegation = new Delegation("Convex Delegation", address(this), address(vlcvx));
        surrogateRegistry = new SurrogateRegistry("Convex Surrogate Registry");
        daoPlatform =
            new DaoVotePlatform("Convex Dao Voting", address(this), address(vlcvx), address(surrogateRegistry), address(delegation));
        daoPlatform.setOperator(operator, true);

        curveDelegate = new MockVoteDelegationExtension();
        curveExecutor = new CurveVoteExecutor("Curve Vote Executor", address(this), address(daoPlatform), address(curveDelegate), 0);

        ProtocolBoundaryMockResupplyStaker staker = new ProtocolBoundaryMockResupplyStaker();
        vm.etch(RESUPPLY_STAKER, address(staker).code);
        resupplyExecutor = new ResupplyVoteExecutor("Resupply Vote Executor", address(this), address(daoPlatform), 0);
    }

    function testFuzz_curveDaoExecutorQuorumAndPercentages(
        uint256 aliceAmountSeed,
        uint256 bobAmountSeed,
        uint256 yesWeightSeed,
        uint256 quorumSeed
    ) public {
        uint256 aliceAmount = bound(aliceAmountSeed, 1, 1_000_000);
        uint256 bobAmount = bound(bobAmountSeed, 1, 1_000_000);
        uint256 yesWeight = bound(yesWeightSeed, 0, 10_000);
        uint256 quorumBps = bound(quorumSeed, 0, 10_000);

        uint256 pid = _createFinalizedProposal(aliceAmount, bobAmount, yesWeight);
        curveExecutor.setQuorum(quorumBps);

        uint256 votedSupplyRatio = aliceAmount * 10_000 / (aliceAmount + bobAmount);
        if (quorumBps > votedSupplyRatio) {
            vm.expectRevert(CurveVoteExecutor.QuorumNotMet.selector);
            curveExecutor.executeDaoVote(pid);
            assertEq(curveDelegate.daoCallCount(), 0);
            assertFalse(curveExecutor.isDone(pid));
            return;
        }

        curveExecutor.executeDaoVote(pid);

        assertTrue(curveExecutor.isDone(pid));
        assertEq(curveDelegate.daoCallCount(), 1);
        assertEq(curveDelegate.lastVoteId(), EXTERNAL_PROPOSAL_ID);
        assertEq(curveDelegate.lastYay(), yesWeight);
        assertEq(curveDelegate.lastNay(), 10_000 - yesWeight);
        assertEq(curveDelegate.lastYay() + curveDelegate.lastNay(), 10_000);
    }

    function testFuzz_resupplyDaoExecutorQuorumAndEncodedVote(
        uint256 aliceAmountSeed,
        uint256 bobAmountSeed,
        uint256 yesWeightSeed,
        uint256 quorumSeed
    ) public {
        uint256 aliceAmount = bound(aliceAmountSeed, 1, 1_000_000);
        uint256 bobAmount = bound(bobAmountSeed, 1, 1_000_000);
        uint256 yesWeight = bound(yesWeightSeed, 0, 10_000);
        uint256 quorumBps = bound(quorumSeed, 0, 10_000);

        uint256 pid = _createFinalizedProposal(aliceAmount, bobAmount, yesWeight);
        resupplyExecutor.setQuorum(quorumBps);

        ProtocolBoundaryMockResupplyStaker staker = ProtocolBoundaryMockResupplyStaker(RESUPPLY_STAKER);
        uint256 votedSupplyRatio = aliceAmount * 10_000 / (aliceAmount + bobAmount);
        if (quorumBps > votedSupplyRatio) {
            vm.expectRevert(ResupplyVoteExecutor.QuorumNotMet.selector);
            resupplyExecutor.executeDaoVote(pid);
            assertEq(staker.callCount(), 0);
            assertFalse(resupplyExecutor.isDone(pid));
            return;
        }

        resupplyExecutor.executeDaoVote(pid);

        bytes memory expectedData = abi.encodeWithSelector(
            IResupplyVoter.voteForProposal.selector,
            RESUPPLY_STAKER,
            EXTERNAL_PROPOSAL_ID,
            yesWeight,
            10_000 - yesWeight
        );
        assertTrue(resupplyExecutor.isDone(pid));
        assertEq(staker.callCount(), 1);
        assertEq(staker.lastTarget(), RESUPPLY_VOTER);
        assertEq(staker.lastData(), expectedData);
    }

    function _createFinalizedProposal(uint256 aliceAmount, uint256 bobAmount, uint256 yesWeight)
        internal
        returns (uint256 pid)
    {
        vlcvx.lock(alice, aliceAmount * WD, 0);
        vlcvx.lock(bob, bobAmount * WD, 0);
        _warpToNextEpoch();

        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        daoPlatform.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Ownership, EXTERNAL_PROPOSAL_ID);
        pid = daoPlatform.proposalCount() - 1;

        vm.warp(startTime);
        vm.prank(alice);
        daoPlatform.vote(pid, alice, yesWeight, 10_000 - yesWeight);

        vm.warp(endTime + daoPlatform.finalizationTime() + 1);
    }

    function _warpToNextEpoch() internal {
        uint256 currentEpoch = (block.timestamp / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);
    }
}
