// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ProposalMetadata.sol";

contract ProposalMetadataTest is Test {
    ProposalMetadata internal proposalMetadata;

    address internal owner = address(this);
    address internal operator = makeAddr("operator");
    address internal notOperator = makeAddr("notOperator");

    function setUp() public {
        proposalMetadata = new ProposalMetadata("Proposal Metadata", owner);
    }

    function test_ownerCanSetOperator() public {
        assertFalse(proposalMetadata.operators(operator));

        proposalMetadata.setOperator(operator, true);
        assertTrue(proposalMetadata.operators(operator));

        proposalMetadata.setOperator(operator, false);
        assertFalse(proposalMetadata.operators(operator));
    }

    function test_onlyOwnerCanSetOperator() public {
        vm.prank(notOperator);
        vm.expectRevert();
        proposalMetadata.setOperator(operator, true);
    }

    function test_operatorCanSetMetadata() public {
        proposalMetadata.setOperator(operator, true);

        vm.prank(operator);
        proposalMetadata.setMetadata(42, "Proposal description", "https://example.com/proposals/42");

        (string memory description, string memory referenceUrl) = proposalMetadata.metadata(42);
        assertEq(description, "Proposal description");
        assertEq(referenceUrl, "https://example.com/proposals/42");
    }

    function test_operatorCanUpdateMetadata() public {
        proposalMetadata.setOperator(operator, true);

        vm.startPrank(operator);
        proposalMetadata.setMetadata(42, "Proposal description", "https://example.com/proposals/42");
        proposalMetadata.setMetadata(42, "Updated description", "https://example.com/proposals/42-updated");
        vm.stopPrank();

        (string memory description, string memory referenceUrl) = proposalMetadata.metadata(42);
        assertEq(description, "Updated description");
        assertEq(referenceUrl, "https://example.com/proposals/42-updated");
    }

    function test_nonOperatorCannotSetMetadata() public {
        vm.prank(notOperator);
        vm.expectRevert("Not operator");
        proposalMetadata.setMetadata(42, "Proposal description", "https://example.com/proposals/42");
    }
}
