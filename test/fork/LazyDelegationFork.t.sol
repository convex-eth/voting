// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";
import {CurveGaugeRegistry} from "../../src/CurveGaugeRegistry.sol";
import {GaugeVotePlatform} from "../../src/GaugeVotePlatform.sol";
import {DaoVotePlatform} from "../../src/DaoVotePlatform.sol";
import {Delegation} from "../../src/Delegation.sol";
import {SurrogateRegistry} from "../../src/SurrogateRegistry.sol";

contract LazyDelegationForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function testFork_controlledDaoVoteUsesLiveHolderWeight() public {
        (address holder,, uint256 holderWeight) = liveVlCvxHolder();
        (,, DaoVotePlatform platform) = deployDaoPlatform();

        uint256 pid = createDaoProposal(platform, 1 days, 300_001);
        voteDaoAsHolder(platform, holder, 8000, 2000);

        assertEq(platform.voteTotals(pid), holderWeight);
        assertEq(platform.getYes(pid), holderWeight * 8000 / WEIGHT_BPS);
        assertEq(platform.getNo(pid), holderWeight - holderWeight * 8000 / WEIGHT_BPS);
    }

    function testFork_controlledGaugeVoteUsesLiveHolderWeight() public {
        (address holder,, uint256 holderWeight) = liveVlCvxHolder();
        address gauge = liveCurveGauge();
        CurveGaugeRegistry registry = new CurveGaugeRegistry(address(this), arr(gauge));
        (,, GaugeVotePlatform platform) = deployGaugePlatform(address(registry));

        uint256 pid = createGaugeProposal(platform, 1 days);
        voteGaugeAsHolder(platform, holder, arr(gauge), weights(WEIGHT_BPS));

        assertEq(platform.voteTotals(pid), holderWeight);
        assertEq(platform.gaugeTotal(pid, gauge), holderWeight);
    }

    function testFork_directGaugeVoteOverridesSurrogateVoteWithLiveWeight() public {
        (address holder,, uint256 holderWeight) = liveVlCvxHolder();
        address surrogate = makeAddr("surrogate");
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

        vm.prank(holder);
        surrogateRegistry.setSurrogate(surrogate);

        uint256 pid = createGaugeProposal(platform, 1 days);

        vm.prank(surrogate);
        platform.vote(holder, arr(g1), weights(WEIGHT_BPS));

        assertEq(platform.gaugeTotal(pid, g1), holderWeight);

        vm.prank(holder);
        platform.vote(holder, arr(g2), weights(WEIGHT_BPS));

        assertEq(platform.voteTotals(pid), holderWeight);
        assertEq(platform.gaugeTotal(pid, g1), 0);
        assertEq(platform.gaugeTotal(pid, g2), holderWeight);
    }
}
