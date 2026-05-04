// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ConvexCore.sol";
import "../src/CurveVoteExecutor.sol";
import "../src/GenericDaoProposer.sol";
import "../src/ResupplyVoteExecutor.sol";
import "../src/VotingRegistry.sol";
import "../src/interface/IDaoVotePlatform.sol";

contract OperationalMockDaoVotePlatform is IDaoVotePlatform {
    uint256 public proposalCount;
    address public lastOperator;
    bool public lastActive;
    uint256 public lastStartTime;
    uint256 public lastEndTime;
    VoteType public lastVoteType;
    uint256 public lastVoteId;

    function MIN_PROPOSAL_DURATION() external pure returns (uint256) {
        return 3 days;
    }

    function MAX_PROPOSAL_DURATION() external pure returns (uint256) {
        return 6 days;
    }

    function createProposal(uint256 startTime, uint256 endTime, VoteType voteType, uint256 voteId) external {
        lastStartTime = startTime;
        lastEndTime = endTime;
        lastVoteType = voteType;
        lastVoteId = voteId;
        proposalCount++;
    }

    function setOperator(address operator, bool active) external {
        lastOperator = operator;
        lastActive = active;
    }
}

contract OperationalControlMockResupplyStaker is IResupplyStaker {
    uint256 public callCount;

    function safeExecute(address, bytes calldata) external pure returns (bytes memory) {
        return "";
    }

    function claimAndStake() external returns (uint256 amount) {
        callCount++;
        return 1_000;
    }
}

contract OperationalControlTest is Test {
    address internal operator = makeAddr("operator");
    address internal bot = makeAddr("bot");
    address internal guardian = makeAddr("guardian");
    address internal replacement = makeAddr("replacement");
    address internal keeper = makeAddr("keeper");

    address internal constant RESUPPLY_STAKER = 0xCCCCCccc94bFeCDd365b4Ee6B86108fC91848901;

    ConvexCore internal core;

    function setUp() public {
        address[] memory operators = new address[](1);
        operators[0] = operator;
        core = new ConvexCore(operators);
    }

    function test_coreOperatorCanClearAndRecoverRegistryMisconfiguration() public {
        VotingRegistry registry = new VotingRegistry(address(core));

        vm.startPrank(operator);
        core.execute(
            address(registry),
            abi.encodeWithSelector(
                VotingRegistry.setVotingContract.selector, "CURVE", registry.VOTE_DAO(), address(0xBEEF)
            )
        );
        core.execute(
            address(registry),
            abi.encodeWithSelector(VotingRegistry.setVotingContract.selector, "CURVE", registry.VOTE_DAO(), address(0))
        );
        core.execute(
            address(registry),
            abi.encodeWithSelector(VotingRegistry.setVotingContract.selector, "CURVE", registry.VOTE_DAO(), replacement)
        );
        vm.stopPrank();

        assertEq(registry.getAddress("CURVE", registry.VOTE_DAO()), replacement);
    }

    function test_nonCoreCannotMutateCoreOwnedRegistry() public {
        VotingRegistry registry = new VotingRegistry(address(core));
        uint8 voteDao = registry.VOTE_DAO();

        vm.expectRevert();
        vm.prank(bot);
        registry.setVotingContract("CURVE", voteDao, replacement);

        assertEq(registry.getAddress("CURVE", voteDao), address(0));
    }

    function test_coreCanRotateGenericProposerOperatorsAndRevokedOperatorCannotPropose() public {
        OperationalMockDaoVotePlatform platform = new OperationalMockDaoVotePlatform();
        GenericDaoProposer proposer = new GenericDaoProposer(address(core), address(platform));

        vm.startPrank(operator);
        core.execute(address(proposer), abi.encodeWithSelector(GenericDaoProposer.setOperator.selector, bot, true));
        vm.stopPrank();

        vm.prank(bot);
        proposer.propose(42, uint8(IDaoVotePlatform.VoteType.Parameter));

        assertEq(platform.proposalCount(), 1);
        assertEq(platform.lastVoteId(), 42);
        assertEq(uint8(platform.lastVoteType()), uint8(IDaoVotePlatform.VoteType.Parameter));

        vm.prank(operator);
        core.execute(address(proposer), abi.encodeWithSelector(GenericDaoProposer.setOperator.selector, bot, false));

        vm.prank(bot);
        vm.expectRevert("Not operator");
        proposer.propose(43, uint8(IDaoVotePlatform.VoteType.Ownership));

        assertEq(platform.proposalCount(), 1);
    }

    function test_coreCanRotateExecutorGuardians() public {
        CurveVoteExecutor executor = new CurveVoteExecutor(address(core), address(0x1234), address(0x5678), 0);

        vm.startPrank(operator);
        core.execute(address(executor), abi.encodeWithSelector(CurveVoteExecutor.setGuardian.selector, guardian, true));
        core.execute(address(executor), abi.encodeWithSelector(CurveVoteExecutor.setGuardian.selector, guardian, false));
        vm.stopPrank();

        assertFalse(executor.guardians(guardian));
    }

    function test_resupplyClaimAndStakeIsPermissionlessForwarder() public {
        OperationalControlMockResupplyStaker staker = new OperationalControlMockResupplyStaker();
        vm.etch(RESUPPLY_STAKER, address(staker).code);

        ResupplyVoteExecutor executor = new ResupplyVoteExecutor(address(core), address(0x1234), 0);

        vm.prank(keeper);
        uint256 amount = executor.claimAndStake();

        assertEq(amount, 1_000);
        assertEq(OperationalControlMockResupplyStaker(RESUPPLY_STAKER).callCount(), 1);
    }
}
