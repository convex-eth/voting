// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/GaugeProposer.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/Delegation.sol";
import "../src/SurrogateRegistry.sol";
import "../src/CurveGaugeRegistry.sol";
import "./mocks/MockVlCVX.sol";

contract GaugeProposerTest is Test {
    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    CurveGaugeRegistry internal gaugeRegistry;
    GaugeVotePlatform internal gaugeVotePlatform;
    GaugeProposer internal proposer;

    address internal owner = address(this);
    address internal operator = makeAddr("operator");

    uint256 constant WEEK = 86400 * 7;

    function setUp() public {
        vm.warp(WEEK * 2);

        mockVlCVX = new MockVlCVX();

        delegation = new Delegation(address(mockVlCVX));
        surrogateRegistry = new SurrogateRegistry();
        gaugeRegistry = new CurveGaugeRegistry();

        gaugeVotePlatform = new GaugeVotePlatform(
            owner,
            address(mockVlCVX),
            address(gaugeRegistry),
            address(surrogateRegistry),
            address(delegation)
        );

        gaugeVotePlatform.setOperator(operator, true);

        proposer = new GaugeProposer(owner, address(mockVlCVX), address(gaugeVotePlatform));
        gaugeVotePlatform.setOperator(address(proposer), true);
    }

    function test_proposeVote() public {
        vm.warp(block.timestamp + WEEK * 2);

        uint256 pid = gaugeVotePlatform.proposalCount();

        proposer.proposeVote();

        uint256 currentEpoch = mockVlCVX.epochCount() - 2;
        (, uint32 epochStart) = mockVlCVX.epochs(currentEpoch);

        (uint256 s, uint256 e,) = gaugeVotePlatform.proposals(pid);
        assertEq(s, uint256(epochStart));
        assertEq(e, uint256(epochStart) + 5 days);

        assertLe(s, block.timestamp, "startTime should be at or before now");
        assertGe(s, block.timestamp - WEEK, "startTime should be less than a week ago");
    }

    function test_lastEpochUsedUpdated() public {
        vm.warp(block.timestamp + WEEK * 2);

        proposer.proposeVote();

        assertEq(proposer.lastEpochUsed(), mockVlCVX.epochCount());
    }

    function test_cannotProposeTwiceSameEpoch() public {
        vm.warp(block.timestamp + WEEK * 2);

        proposer.proposeVote();

        vm.expectRevert("Epoch already used");
        proposer.proposeVote();
    }

    function test_cannotProposeOnOddEpoch() public {
        vm.warp(block.timestamp + WEEK);
        mockVlCVX.checkpointEpoch();

        assertEq(mockVlCVX.epochCount() % 2, 1);

        vm.expectRevert("Must be even epoch (bi-weekly)");
        proposer.proposeVote();
    }

    function test_canProposeOnNextEvenEpoch() public {
        vm.warp(block.timestamp + WEEK * 2);
        proposer.proposeVote();

        vm.warp(block.timestamp + WEEK * 2);

        uint256 pid = gaugeVotePlatform.proposalCount();

        proposer.proposeVote();

        uint256 currentEpoch = mockVlCVX.epochCount() - 2;
        (, uint32 epochStart) = mockVlCVX.epochs(currentEpoch);

        (uint256 s, uint256 e,) = gaugeVotePlatform.proposals(pid);
        assertEq(s, uint256(epochStart));
        assertEq(e, uint256(epochStart) + 5 days);

        assertLe(s, block.timestamp, "startTime should be at or before now");
        assertGe(s, block.timestamp - WEEK, "startTime should be less than a week ago");
    }

    function test_setProposalLength() public {
        assertEq(proposer.proposalLength(), 5 days);

        proposer.setProposalLength(6 days);
        assertEq(proposer.proposalLength(), 6 days);
    }

    function test_cannotSetProposalLengthTooShort() public {
        vm.expectRevert("Bad proposal length");
        proposer.setProposalLength(3 days - 1);
    }

    function test_cannotSetProposalLengthTooLong() public {
        vm.expectRevert("Bad proposal length");
        proposer.setProposalLength(6 days + 1);
    }

    function test_onlyOwnerCanSetProposalLength() public {
        vm.expectRevert();
        vm.prank(makeAddr("notOwner"));
        proposer.setProposalLength(6 days);
    }

    function test_initialLastEpochUsed() public {
        assertEq(proposer.lastEpochUsed(), 2);
    }
}
