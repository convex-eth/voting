// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";
import {CurveGaugeRegistry} from "../../src/CurveGaugeRegistry.sol";
import {GaugeVotePlatform} from "../../src/GaugeVotePlatform.sol";
import {GaugeVoteHelper} from "../../src/GaugeVoteHelper.sol";
import {Delegation} from "../../src/Delegation.sol";
import {SurrogateRegistry} from "../../src/SurrogateRegistry.sol";
import {IvlCVX} from "../../src/interface/IvlCVX.sol";

contract GaugeVoteHelperForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function testFork_helperReportsLiveDelegatedContributionUntilDirectVote() public {
        (address holder,,) = liveVlCvxHolder();
        address delegate = makeAddr("delegate");
        (address g1, address g2) = twoLiveCurveGauges();
        CurveGaugeRegistry registry = new CurveGaugeRegistry(address(this), arr(g1, g2));
        Delegation delegation = new Delegation(VLCVX);
        SurrogateRegistry surrogateRegistry = new SurrogateRegistry();
        GaugeVotePlatform platform = new GaugeVotePlatform(
            address(this),
            VLCVX,
            address(registry),
            address(surrogateRegistry),
            address(delegation)
        );
        GaugeVoteHelper helper = new GaugeVoteHelper(address(delegation), address(platform));

        vm.prank(holder);
        delegation.setDelegate(delegate);
        uint256 delegatedEpoch = IvlCVX(VLCVX).epochCount() - 1;

        vm.warp(currentVlCvxEpochStart() + WEEK + TIME_BUFFER);
        uint256 pid = createGaugeProposal(platform, 1 days);
        (,, uint48 proposalEpoch) = platform.proposals(pid);
        assertEq(uint256(proposalEpoch), delegatedEpoch);

        vm.prank(delegate);
        platform.vote(delegate, arr(g1), weights(WEIGHT_BPS));

        address[] memory users = arr(holder);
        uint256[] memory contributions = helper.getContributingWeights(pid, delegate, users);
        uint256 expected = delegation.userWeightAtEpochOf(delegatedEpoch, holder);
        assertGt(expected, 0);
        assertEq(contributions[0], expected);

        vm.prank(holder);
        platform.vote(holder, arr(g2), weights(WEIGHT_BPS));

        contributions = helper.getContributingWeights(pid, delegate, users);
        assertEq(contributions[0], 0);
    }
}
