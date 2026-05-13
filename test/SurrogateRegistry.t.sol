// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/SurrogateRegistry.sol";

contract SurrogateRegistryTest is Test {
    SurrogateRegistry internal registry;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        registry = new SurrogateRegistry("Convex Surrogate Registry");
    }

    function test_setSurrogate() public {
        vm.prank(alice);
        registry.setSurrogate(bob);

        (address surrogate, uint32 ts) = registry.surrogateInfo(alice);
        assertEq(surrogate, bob);
        assertEq(ts, uint32(block.timestamp));
    }

    function test_isSurrogateTrue() public {
        vm.prank(alice);
        registry.setSurrogate(bob);

        assertTrue(registry.isSurrogate(bob, alice));
    }

    function test_isSurrogateFalse() public {
        assertFalse(registry.isSurrogate(bob, alice));
    }

    function test_isSurrogateFalseAfterChange() public {
        vm.prank(alice);
        registry.setSurrogate(bob);

        assertTrue(registry.isSurrogate(bob, alice));

        vm.prank(alice);
        registry.setSurrogate(carol);

        assertFalse(registry.isSurrogate(bob, alice));
        assertTrue(registry.isSurrogate(carol, alice));
    }

    function test_removeSurrogate() public {
        vm.prank(alice);
        registry.setSurrogate(bob);

        vm.prank(alice);
        registry.setSurrogate(address(0));

        assertFalse(registry.isSurrogate(bob, alice));

        (address surrogate, uint32 ts) = registry.surrogateInfo(alice);
        assertEq(surrogate, address(0));
        assertGt(ts, 0);
    }

    function test_timestampUpdates() public {
        vm.prank(alice);
        registry.setSurrogate(bob);

        (, uint32 ts1) = registry.surrogateInfo(alice);

        vm.warp(block.timestamp + 1000);

        vm.prank(alice);
        registry.setSurrogate(carol);

        (, uint32 ts2) = registry.surrogateInfo(alice);
        assertGt(ts2, ts1);
    }

    function test_differentUsersIndependent() public {
        vm.prank(alice);
        registry.setSurrogate(bob);

        vm.prank(carol);
        registry.setSurrogate(bob);

        assertTrue(registry.isSurrogate(bob, alice));
        assertTrue(registry.isSurrogate(bob, carol));

        vm.prank(alice);
        registry.setSurrogate(address(0));

        assertFalse(registry.isSurrogate(bob, alice));
        assertTrue(registry.isSurrogate(bob, carol));
    }

    function test_emitSurrogateSet() public {
        vm.expectEmit(true, true, false, false);
        emit SurrogateRegistry.SurrogateSet(alice, bob);

        vm.prank(alice);
        registry.setSurrogate(bob);
    }

    function test_noSurrogateByDefault() public view {
        (address surrogate,) = registry.surrogateInfo(alice);
        assertEq(surrogate, address(0));
    }
}
