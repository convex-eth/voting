// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ConvexCore.sol";

contract ConvexCoreTest is Test {
    ConvexCore core;
    address operatorA = makeAddr("operatorA");
    address operatorB = makeAddr("operatorB");
    address operatorC = makeAddr("operatorC");
    address nonOperator = makeAddr("nonOperator");

    function setUp() public {
        address[] memory initial = new address[](2);
        initial[0] = operatorA;
        initial[1] = operatorB;
        core = new ConvexCore(initial);
    }

    function test_initialOperators() public {
        assertTrue(core.operators(operatorA));
        assertTrue(core.operators(operatorB));
        assertFalse(core.operators(operatorC));
        assertEq(core.operatorCount(), 2);
        assertEq(core.operatorList(0), operatorA);
        assertEq(core.operatorList(1), operatorB);
    }

    function test_addOperator() public {
        vm.prank(operatorA);
        core.setOperator(operatorC, true);

        assertTrue(core.operators(operatorC));
        assertEq(core.operatorCount(), 3);
        assertEq(core.operatorList(2), operatorC);
    }

    function test_addExistingOperatorNoop() public {
        vm.prank(operatorA);
        core.setOperator(operatorA, true);

        assertEq(core.operatorCount(), 2);
    }

    function test_removeOperator() public {
        vm.prank(operatorA);
        core.setOperator(operatorB, false);

        assertFalse(core.operators(operatorB));
        assertEq(core.operatorCount(), 1);
        assertEq(core.operatorList(0), operatorA);
    }

    function test_removeOperatorSwapAndPop() public {
        vm.prank(operatorA);
        core.setOperator(operatorC, true);

        assertEq(core.operatorCount(), 3);

        vm.prank(operatorA);
        core.setOperator(operatorA, false);

        assertFalse(core.operators(operatorA));
        assertEq(core.operatorCount(), 2);
        assertEq(core.operatorList(0), operatorC);
        assertEq(core.operatorList(1), operatorB);
    }

    function test_removeNonOperatorNoop() public {
        vm.prank(operatorA);
        core.setOperator(operatorC, false);

        assertFalse(core.operators(operatorC));
        assertEq(core.operatorCount(), 2);
    }

    function test_revertRemoveLastOperator() public {
        vm.prank(operatorA);
        core.setOperator(operatorB, false);

        vm.prank(operatorA);
        vm.expectRevert("Cannot remove last operator");
        core.setOperator(operatorA, false);
    }

    function test_nonOperatorCannotSetOperator() public {
        vm.prank(nonOperator);
        vm.expectRevert("Not operator");
        core.setOperator(operatorC, true);
    }

    function test_nonOperatorCannotExecute() public {
        vm.expectRevert("Not operator");
        core.execute(address(0), "");
    }

    function test_executeSuccess() public {
        address target = address(new MockTarget());
        bytes memory data = abi.encodeWithSelector(MockTarget.returnBytes.selector, "hello");

        vm.prank(operatorA);
        bytes memory result = core.execute(target, data);

        assertEq(abi.decode(result, (string)), "hello");
    }

    function test_executeFailure() public {
        address target = address(new MockTarget());
        bytes memory data = abi.encodeWithSelector(MockTarget.revertWithMessage.selector);

        vm.prank(operatorA);
        vm.expectRevert("it broke");
        core.execute(target, data);
    }

    function test_executeCallFailure() public {
        address target = address(new MockTarget());
        bytes memory data = hex"deadbeef";

        vm.prank(operatorA);
        vm.expectRevert("Call failed");
        core.execute(target, data);
    }

    function test_operatorListMatchesOperators() public {
        vm.prank(operatorA);
        core.setOperator(operatorC, true);

        vm.prank(operatorA);
        core.setOperator(operatorB, false);

        assertEq(core.operatorCount(), 2);
        assertTrue(core.operators(core.operatorList(0)));
        assertTrue(core.operators(core.operatorList(1)));
    }
}

contract MockTarget {
    function returnBytes(string memory s) external pure returns (string memory) {
        return s;
    }

    function revertWithMessage() external pure {
        revert("it broke");
    }
}
