// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ConvexCore.sol";

contract OperationalControlFuzzTarget {
    uint256 public value;

    function setValue(uint256 value_) external returns (uint256) {
        value = value_;
        return value_;
    }
}

contract OperationalControlFuzzTest is Test {
    address[4] internal actors =
        [makeAddr("operatorA"), makeAddr("operatorB"), makeAddr("operatorC"), makeAddr("operatorD")];

    ConvexCore internal core;
    OperationalControlFuzzTarget internal target;
    bool[4] internal expectedOperators;
    uint256 internal expectedOperatorCount;

    function setUp() public {
        address[] memory initialOperators = new address[](2);
        initialOperators[0] = actors[0];
        initialOperators[1] = actors[1];

        core = new ConvexCore(initialOperators);
        target = new OperationalControlFuzzTarget();

        expectedOperators[0] = true;
        expectedOperators[1] = true;
        expectedOperatorCount = 2;
    }

    function testFuzz_operatorSetMaintainsAccessAndCannotLockOut(uint256 seed) public {
        for (uint256 i = 0; i < 64; ++i) {
            uint256 op = uint256(keccak256(abi.encode(seed, i)));
            uint8 callerIndex = uint8(op);
            uint8 targetIndex = uint8(op >> 8);
            bool active = ((op >> 16) & 1) == 1;

            _setOperator(callerIndex, targetIndex, active);
            _assertOperatorState();
        }
    }

    function testFuzz_nonOperatorsCannotExecute(uint8 callerIndex, uint256 value) public {
        address caller = actors[bound(callerIndex, 2, 3)];

        vm.prank(caller);
        vm.expectRevert("Not operator");
        core.execute(address(target), abi.encodeWithSelector(OperationalControlFuzzTarget.setValue.selector, value));

        assertEq(target.value(), 0);
        _assertOperatorState();
    }

    function _setOperator(uint8 callerIndexSeed, uint8 targetIndexSeed, bool active) internal {
        uint256 callerIndex = bound(callerIndexSeed, 0, actors.length - 1);
        uint256 targetIndex = bound(targetIndexSeed, 0, actors.length - 1);
        address caller = actors[callerIndex];
        address targetOperator = actors[targetIndex];

        bool callerIsOperator = expectedOperators[callerIndex];
        bool targetIsOperator = expectedOperators[targetIndex];

        vm.prank(caller);
        if (!callerIsOperator) {
            vm.expectRevert("Not operator");
            core.setOperator(targetOperator, active);
            return;
        }

        if (!active && targetIsOperator && expectedOperatorCount == 1) {
            vm.expectRevert("Cannot remove last operator");
            core.setOperator(targetOperator, false);
            return;
        }

        core.setOperator(targetOperator, active);

        if (active && !targetIsOperator) {
            expectedOperators[targetIndex] = true;
            expectedOperatorCount++;
        } else if (!active && targetIsOperator) {
            expectedOperators[targetIndex] = false;
            expectedOperatorCount--;
        }
    }

    function _assertOperatorState() internal view {
        assertGt(expectedOperatorCount, 0);
        assertEq(core.operatorCount(), expectedOperatorCount);

        uint256 counted;
        for (uint256 i = 0; i < actors.length; ++i) {
            assertEq(core.operators(actors[i]), expectedOperators[i]);
            if (expectedOperators[i]) counted++;
        }
        assertEq(counted, expectedOperatorCount);
    }
}
