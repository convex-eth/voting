// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";
import {GaugeProposer} from "../../src/GaugeProposer.sol";
import {CurveGaugeRegistry} from "../../src/CurveGaugeRegistry.sol";
import {GaugeVotePlatform} from "../../src/GaugeVotePlatform.sol";
import {IvlCVX} from "../../src/interface/IvlCVX.sol";

contract GaugeProposerForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function _deployProposer() internal returns (GaugeVotePlatform platform, GaugeProposer proposer) {
        CurveGaugeRegistry registry = new CurveGaugeRegistry(address(this), new address[](0));
        (,, platform) = deployGaugePlatform(address(registry));
        proposer = new GaugeProposer(address(this), VLCVX, address(platform));
        platform.setOperator(address(proposer), true);
    }

    function testFork_oddVlCvxEpochCannotProposeGaugeVote() public {
        (, GaugeProposer proposer) = _deployProposer();

        vm.warp(currentVlCvxEpochStart() + WEEK + TIME_BUFFER);

        vm.expectRevert("Must be even epoch (bi-weekly)");
        proposer.proposeVote();
    }

    function testFork_evenVlCvxEpochCanProposeGaugeVoteOnce() public {
        (GaugeVotePlatform platform, GaugeProposer proposer) = _deployProposer();

        vm.warp(currentVlCvxEpochStart() + 2 * WEEK + TIME_BUFFER);
        proposer.proposeVote();

        uint256 pid = platform.proposalCount() - 1;
        (uint48 startTime, uint48 endTime, uint48 epoch) = platform.proposals(pid);
        uint256 epochCount = IvlCVX(VLCVX).epochCount();
        (, uint32 expectedStart) = IvlCVX(VLCVX).epochs(epochCount - 2);

        assertEq(epoch, uint48(epochCount - 2));
        assertEq(startTime, uint48(expectedStart));
        assertEq(endTime, uint48(uint256(expectedStart) + proposer.proposalLength()));

        vm.expectRevert("Epoch already used");
        proposer.proposeVote();
    }
}
