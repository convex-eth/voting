// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/GaugeProposer.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/Delegation.sol";
import "../src/SurrogateRegistry.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/interface/IvlCVX.sol";
import "./mocks/simpleVlCvx.sol";

contract GaugeProposerTest is Test {
    IvlCVX internal vlcvx;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    CurveGaugeRegistry internal gaugeRegistry;
    GaugeVotePlatform internal gaugeVotePlatform;
    GaugeProposer internal proposer;

    address internal owner = address(this);
    address internal operator = makeAddr("operator");

    uint256 constant WEEK = 86400 * 7;

    function setUp() public {
        vm.warp(1700697600);

        simpleVlCvx impl = new simpleVlCvx();
        vlcvx = IvlCVX(address(impl));

        delegation = new Delegation("Convex Delegation", address(vlcvx));
        surrogateRegistry = new SurrogateRegistry("Convex Surrogate Registry");
        gaugeRegistry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), new address[](0));

        gaugeVotePlatform = new GaugeVotePlatform("Convex Gauge Voting", 
            owner,
            address(vlcvx),
            address(gaugeRegistry),
            address(surrogateRegistry),
            address(delegation)
        );

        gaugeVotePlatform.setOperator(operator, true);

        proposer = new GaugeProposer("Convex Gauge Proposer", owner, address(vlcvx), address(gaugeVotePlatform));
        gaugeVotePlatform.setOperator(address(proposer), true);
    }

    function test_proposeVote() public {
        vm.warp(block.timestamp + WEEK * 2);

        uint256 pid = gaugeVotePlatform.proposalCount();

        proposer.proposeVote();

        uint256 currentEpoch = vlcvx.epochCount() - 2;
        (, uint32 epochStart) = vlcvx.epochs(currentEpoch);

        (uint256 s, uint256 e,) = gaugeVotePlatform.proposals(pid);
        assertEq(s, uint256(epochStart));
        assertEq(e, uint256(epochStart) + 5 days);

        assertLe(s, block.timestamp, "startTime should be at or before now");
        assertGe(s, block.timestamp - WEEK, "startTime should be less than a week ago");
    }

    function test_lastEpochUsedUpdated() public {
        vm.warp(block.timestamp + WEEK * 2);

        proposer.proposeVote();

        assertEq(proposer.lastEpochUsed(), vlcvx.epochCount());
    }

    function test_cannotProposeTwiceSameEpoch() public {
        vm.warp(block.timestamp + WEEK * 2);

        proposer.proposeVote();

        vm.expectRevert("Epoch already used");
        proposer.proposeVote();
    }

    function test_cannotProposeOnOddEpoch() public {
        vm.warp(block.timestamp + WEEK);
        vlcvx.checkpointEpoch();

        assertEq(vlcvx.epochCount() % 2, 1);

        vm.expectRevert("Must be even epoch (bi-weekly)");
        proposer.proposeVote();
    }

    function test_canProposeOnNextEvenEpoch() public {
        vm.warp(block.timestamp + WEEK * 2);
        proposer.proposeVote();

        vm.warp(block.timestamp + WEEK * 2);

        uint256 pid = gaugeVotePlatform.proposalCount();

        proposer.proposeVote();

        uint256 currentEpoch = vlcvx.epochCount() - 2;
        (, uint32 epochStart) = vlcvx.epochs(currentEpoch);

        (uint256 s, uint256 e,) = gaugeVotePlatform.proposals(pid);
        assertEq(s, uint256(epochStart));
        assertEq(e, uint256(epochStart) + 5 days);

        assertLe(s, block.timestamp, "startTime should be at or before now");
        assertGe(s, block.timestamp - WEEK, "startTime should be less than a week ago");
    }

    function test_setProposalLength() public {
        assertEq(proposer.proposalLength(), 5 days);

        proposer.setProposalLength(5 days);
        assertEq(proposer.proposalLength(), 5 days);
    }

    function test_cannotSetProposalLengthTooShort() public {
        uint256 tooShort = gaugeVotePlatform.MIN_PROPOSAL_DURATION() - 1;
        vm.expectRevert("Below minimum");
        proposer.setProposalLength(tooShort);
    }

    function test_cannotSetProposalLengthTooLong() public {
        vm.expectRevert("Above maximum");
        proposer.setProposalLength(6 days + 1);
    }

    function test_onlyOwnerCanSetProposalLength() public {
        vm.expectRevert();
        vm.prank(makeAddr("notOwner"));
        proposer.setProposalLength(5 days);
    }

    function test_initialLastEpochUsed() public {
        assertEq(proposer.lastEpochUsed(), 2);
    }
}
