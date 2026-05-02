// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ConvexCore.sol";
import "../src/CurveVoteExecutor.sol";
import "../src/GenericDaoProposer.sol";
import "../src/VotingRegistry.sol";

contract ConvexCoreTarget {
    error CustomFailure(uint256 value);

    uint256 public value;

    function setValue(uint256 value_) external returns (bytes32) {
        value = value_;
        return keccak256(abi.encode(value_));
    }

    function revertWithReason() external pure {
        revert("target failed");
    }

    function revertWithCustomError() external pure {
        revert CustomFailure(42);
    }

    function revertWithoutData() external pure {
        assembly {
            revert(0, 0)
        }
    }
}

contract ConvexCoreTest is Test {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal bot = makeAddr("bot");
    address internal guardian = makeAddr("guardian");

    function test_constructorInitializesUniqueNonZeroOperators() public {
        address[] memory operators = new address[](3);
        operators[0] = alice;
        operators[1] = bob;
        operators[2] = alice;

        vm.expectEmit(true, false, false, true);
        emit ConvexCore.OperatorSet(alice, true);
        vm.expectEmit(true, false, false, true);
        emit ConvexCore.OperatorSet(bob, true);
        vm.expectEmit(true, false, false, true);
        emit ConvexCore.OperatorSet(alice, true);
        ConvexCore core = new ConvexCore(operators);

        assertTrue(core.operators(alice));
        assertTrue(core.operators(bob));
        assertEq(core.operatorCount(), 2);
    }

    function test_constructorRejectsEmptyOperatorSet() public {
        address[] memory operators = new address[](0);

        vm.expectRevert(ConvexCore.NoOperators.selector);
        new ConvexCore(operators);
    }

    function test_constructorRejectsZeroOperator() public {
        address[] memory operators = new address[](1);
        operators[0] = address(0);

        vm.expectRevert(ConvexCore.InvalidOperator.selector);
        new ConvexCore(operators);
    }

    function test_operatorCanAddAndRemoveOperatorsWithoutLockout() public {
        ConvexCore core = _newCore(alice, bob);

        vm.prank(alice);
        core.setOperator(carol, true);
        assertTrue(core.operators(carol));
        assertEq(core.operatorCount(), 3);

        vm.prank(alice);
        core.setOperator(alice, false);
        assertFalse(core.operators(alice));
        assertEq(core.operatorCount(), 2);

        vm.prank(carol);
        core.setOperator(alice, true);
        assertTrue(core.operators(alice));
        assertEq(core.operatorCount(), 3);
    }

    function test_cannotRemoveLastOperator() public {
        ConvexCore core = _newCore(alice);

        vm.prank(alice);
        vm.expectRevert(ConvexCore.LastOperator.selector);
        core.setOperator(alice, false);

        assertTrue(core.operators(alice));
        assertEq(core.operatorCount(), 1);
    }

    function test_cannotSetZeroOperator() public {
        ConvexCore core = _newCore(alice);

        vm.prank(alice);
        vm.expectRevert(ConvexCore.InvalidOperator.selector);
        core.setOperator(address(0), true);
    }

    function test_nonOperatorCannotExecuteOrMutateOperators() public {
        ConvexCore core = _newCore(alice);
        ConvexCoreTarget target = new ConvexCoreTarget();

        vm.prank(bob);
        vm.expectRevert("Not operator");
        core.execute(address(target), abi.encodeWithSelector(ConvexCoreTarget.setValue.selector, 1));

        vm.prank(bob);
        vm.expectRevert("Not operator");
        core.setOperator(bob, true);
    }

    function test_executeReturnsDataAndEmitsObservableSuccessEvent() public {
        ConvexCore core = _newCore(alice);
        ConvexCoreTarget target = new ConvexCoreTarget();
        bytes memory data = abi.encodeWithSelector(ConvexCoreTarget.setValue.selector, 123);
        bytes memory expectedReturn = abi.encode(keccak256(abi.encode(uint256(123))));

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit ConvexCore.Executed(address(target), data, true, expectedReturn);
        bytes memory returnData = core.execute(address(target), data);

        assertEq(returnData, expectedReturn);
        assertEq(target.value(), 123);
    }

    function test_executeBubblesRevertReason() public {
        ConvexCore core = _newCore(alice);
        ConvexCoreTarget target = new ConvexCoreTarget();

        vm.prank(alice);
        vm.expectRevert("target failed");
        core.execute(address(target), abi.encodeWithSelector(ConvexCoreTarget.revertWithReason.selector));
    }

    function test_executeBubblesCustomError() public {
        ConvexCore core = _newCore(alice);
        ConvexCoreTarget target = new ConvexCoreTarget();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ConvexCoreTarget.CustomFailure.selector, 42));
        core.execute(address(target), abi.encodeWithSelector(ConvexCoreTarget.revertWithCustomError.selector));
    }

    function test_executeRevertsWithFallbackMessageWhenNoReturnData() public {
        ConvexCore core = _newCore(alice);
        ConvexCoreTarget target = new ConvexCoreTarget();

        vm.prank(alice);
        vm.expectRevert("Call failed");
        core.execute(address(target), abi.encodeWithSelector(ConvexCoreTarget.revertWithoutData.selector));
    }

    function test_coreCanChainProductionAdminActions() public {
        ConvexCore core = _newCore(alice);
        VotingRegistry registry = new VotingRegistry(address(core));
        GenericDaoProposer proposer = new GenericDaoProposer(address(core), address(0x1234));
        CurveVoteExecutor executor = new CurveVoteExecutor(address(core), address(0x5678), address(0x9abc), 0);

        vm.startPrank(alice);
        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", registry.VOTE_DAO(), address(1))
        );
        core.execute(address(proposer), abi.encodeWithSignature("setOperator(address,bool)", bot, true));
        core.execute(address(executor), abi.encodeWithSignature("setGuardian(address,bool)", guardian, true));
        vm.stopPrank();

        assertEq(registry.getAddress("CURVE", registry.VOTE_DAO()), address(1));
        assertTrue(proposer.operators(bot));
        assertTrue(executor.guardians(guardian));
    }

    function _newCore(address operator) internal returns (ConvexCore) {
        address[] memory operators = new address[](1);
        operators[0] = operator;
        return new ConvexCore(operators);
    }

    function _newCore(address operatorA, address operatorB) internal returns (ConvexCore) {
        address[] memory operators = new address[](2);
        operators[0] = operatorA;
        operators[1] = operatorB;
        return new ConvexCore(operators);
    }
}
