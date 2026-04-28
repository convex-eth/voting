// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/VotingRegistry.sol";

contract VotingRegistryTest is Test {
    VotingRegistry internal registry;
    address internal owner = address(this);
    address internal nonOwner = makeAddr("nonOwner");

    address internal daoAddr = makeAddr("dao");
    address internal gaugeAddr = makeAddr("gauge");

    function setUp() public {
        vm.prank(owner);
        registry = new VotingRegistry(owner);
    }

    function test_setVotingContract() public {
        vm.prank(owner);
        registry.setVotingContract("Convex", registry.VOTE_DAO(), daoAddr);

        assertEq(registry.getAddress("Convex", registry.VOTE_DAO()), daoAddr);
    }

    function test_multiplePlatforms() public {
        vm.startPrank(owner);
        registry.setVotingContract("Convex", registry.VOTE_DAO(), daoAddr);
        registry.setVotingContract("Convex", registry.VOTE_GAUGE(), gaugeAddr);
        registry.setVotingContract("Curve", registry.VOTE_DAO(), makeAddr("curveDao"));
        vm.stopPrank();

        assertEq(registry.getAddress("Convex", registry.VOTE_DAO()), daoAddr);
        assertEq(registry.getAddress("Convex", registry.VOTE_GAUGE()), gaugeAddr);
        assertEq(registry.getAddress("Curve", registry.VOTE_DAO()), makeAddr("curveDao"));
        assertEq(registry.getAddress("Curve", registry.VOTE_GAUGE()), address(0));
    }

    function test_onlyOwnerCanSet() public {
        uint8 dao = registry.VOTE_DAO();
        vm.expectRevert();
        vm.prank(nonOwner);
        registry.setVotingContract("Convex", dao, daoAddr);
    }

    function test_overwriteExisting() public {
        address newDao = makeAddr("newDao");

        vm.startPrank(owner);
        registry.setVotingContract("Convex", registry.VOTE_DAO(), daoAddr);
        registry.setVotingContract("Convex", registry.VOTE_DAO(), newDao);
        vm.stopPrank();

        assertEq(registry.getAddress("Convex", registry.VOTE_DAO()), newDao);
    }

    function test_customVoteType() public {
        address custom = makeAddr("custom");

        vm.prank(owner);
        registry.setVotingContract("Convex", 3, custom);

        assertEq(registry.getAddress("Convex", 3), custom);
    }

    function test_unsetReturnsZero() public view {
        assertEq(registry.getAddress("NonExistent", registry.VOTE_DAO()), address(0));
    }

    function test_eventEmitted() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, false);
        emit VotingRegistry.VotingContractSet("Convex", 0, daoAddr);
        registry.setVotingContract("Convex", registry.VOTE_DAO(), daoAddr);
    }

    function test_allPlatforms() public {
        address[5] memory daos = [makeAddr("cDao"), makeAddr("cuDao"), makeAddr("fDao"), makeAddr("fxDao"), makeAddr("rDao")];
        string[5] memory platforms = ["Convex", "Curve", "Frax", "F(x)", "Resupply"];

        vm.startPrank(owner);
        for (uint256 i = 0; i < 5; i++) {
            registry.setVotingContract(platforms[i], registry.VOTE_DAO(), daos[i]);
        }
        vm.stopPrank();

        for (uint256 i = 0; i < 5; i++) {
            assertEq(registry.getAddress(platforms[i], registry.VOTE_DAO()), daos[i]);
        }
    }
}
