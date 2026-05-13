// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/GenericDaoProposer.sol";
import "../src/DaoVotePlatform.sol";
import "../src/Delegation.sol";
import "../src/SurrogateRegistry.sol";
import "../src/interface/IvlCVX.sol";
import "./mocks/simpleVlCvx.sol";

contract GenericDaoProposerTest is Test {
    IvlCVX internal vlcvx;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    DaoVotePlatform internal daoVotePlatform;
    GenericDaoProposer internal proposer;

    address internal owner = address(this);
    address internal whitelisted = makeAddr("whitelisted");
    address internal notWhitelisted = makeAddr("notWhitelisted");

    function setUp() public {
        vm.warp(1700000000);

        simpleVlCvx impl = new simpleVlCvx();
        vlcvx = IvlCVX(address(impl));
        delegation = new Delegation("Convex Delegation", address(vlcvx));
        surrogateRegistry = new SurrogateRegistry("Convex Surrogate Registry");

        daoVotePlatform = new DaoVotePlatform("Convex Dao Voting", 
            owner,
            address(vlcvx),
            address(surrogateRegistry),
            address(delegation)
        );

        daoVotePlatform.setOperator(address(this), true);

        proposer = new GenericDaoProposer("Generic Dao Proposer", owner, address(daoVotePlatform));
        daoVotePlatform.setOperator(address(proposer), true);
    }

    function test_propose() public {
        proposer.setOperator(whitelisted, true);

        uint256 pid = daoVotePlatform.proposalCount();

        vm.prank(whitelisted);
        proposer.propose(1, 0);

        (uint256 s, uint256 e,, uint8 vt, uint256 vId) = daoVotePlatform.proposals(pid);
        assertEq(s, vm.getBlockTimestamp());
        assertEq(e, vm.getBlockTimestamp() + 3 days);
        assertEq(vt, uint8(DaoVotePlatform.VoteType.Ownership));
        assertEq(vId, 1);
    }

    function test_proposeParameter() public {
        proposer.setOperator(whitelisted, true);

        uint256 pid = daoVotePlatform.proposalCount();

        vm.prank(whitelisted);
        proposer.propose(42, 1);

        (,,, uint8 vt, uint256 vId) = daoVotePlatform.proposals(pid);
        assertEq(vt, uint8(DaoVotePlatform.VoteType.Parameter));
        assertEq(vId, 42);
    }

    function test_notOperatorReverts() public {
        vm.prank(notWhitelisted);
        vm.expectRevert("Not operator");
        proposer.propose(1, 0);
    }

    function test_ownerCanSetOperator() public {
        assertFalse(proposer.operators(whitelisted));

        proposer.setOperator(whitelisted, true);
        assertTrue(proposer.operators(whitelisted));

        proposer.setOperator(whitelisted, false);
        assertFalse(proposer.operators(whitelisted));
    }

    function test_onlyOwnerCanSetOperator() public {
        vm.prank(notWhitelisted);
        vm.expectRevert();
        proposer.setOperator(whitelisted, true);
    }

    function test_setProposalLength() public {
        assertEq(proposer.proposalLength(), 3 days);

        proposer.setProposalLength(5 days);
        assertEq(proposer.proposalLength(), 5 days);
    }

    function test_cannotSetProposalLengthTooShort() public {
        uint256 tooShort = daoVotePlatform.MIN_PROPOSAL_DURATION() - 1;
        vm.expectRevert("Below minimum");
        proposer.setProposalLength(tooShort);
    }

    function test_cannotSetProposalLengthTooLong() public {
        vm.expectRevert("Above maximum");
        proposer.setProposalLength(6 days + 1);
    }

    function test_onlyOwnerCanSetProposalLength() public {
        vm.prank(notWhitelisted);
        vm.expectRevert();
        proposer.setProposalLength(5 days);
    }
}
