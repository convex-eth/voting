// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup, IResupplyRegistry} from "./Setup.sol";
import {CurveDaoProposer} from "../../src/CurveDaoProposer.sol";
import {CurveGaugeRegistry} from "../../src/CurveGaugeRegistry.sol";
import {CurveGaugeExecutor} from "../../src/CurveGaugeExecutor.sol";
import {FxGaugeRegistry} from "../../src/FxGaugeRegistry.sol";
import {FxGaugeExecutor} from "../../src/FxGaugeExecutor.sol";
import {ResupplyDaoProposer} from "../../src/ResupplyDaoProposer.sol";
import {ResupplyVoteExecutor} from "../../src/ResupplyVoteExecutor.sol";
import {DaoVotePlatform} from "../../src/DaoVotePlatform.sol";

contract DeployAddressForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function testFork_head_liveDeploymentConstantsHaveCode() public view {
        assertHasCode(VLCVX, "vlCVX");
        assertHasCode(VOTE_DELEGATE_EXTENSION, "VoteDelegateExtension");
        assertHasCode(CURVE_GAUGE_CONTROLLER, "Curve GaugeController");
        assertHasCode(CURVE_OWNERSHIP_VOTING, "Curve ownership voting");
        assertHasCode(CURVE_PARAMETER_VOTING, "Curve parameter voting");
        assertHasCode(FX_GAUGE_CONTROLLER, "F(x) GaugeController");
        assertHasCode(FX_GAUGE_VOTER, "F(x) gauge voter");
        assertHasCode(RESUPPLY_REGISTRY, "Resupply registry");
        assertHasCode(RESUPPLY_VOTER, "Resupply voter");
        assertHasCode(RESUPPLY_PERMA_STAKER, "Resupply perma-staker");
    }

    function testFork_resupplyConstantsMatchLiveRegistry() public view {
        assertEq(IResupplyRegistry(RESUPPLY_REGISTRY).getAddress("VOTER"), RESUPPLY_VOTER);
        assertTrue(IResupplyRegistry(RESUPPLY_REGISTRY).getAddress("STAKER") != RESUPPLY_PERMA_STAKER);
    }

    function testFork_localProtocolConstantsMatchForkConstants() public {
        CurveGaugeRegistry curveRegistry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), new address[](0));
        FxGaugeRegistry fxRegistry = new FxGaugeRegistry("Fx Gauge Registry", address(this), new address[](0));
        CurveGaugeExecutor curveGaugeExecutor = new CurveGaugeExecutor("Curve Gauge Executor", address(0x1234), VOTE_DELEGATE_EXTENSION);
        FxGaugeExecutor fxGaugeExecutor = new FxGaugeExecutor("Fx Gauge Executor", address(0x1234));
        (,, DaoVotePlatform daoPlatform) = deployDaoPlatform();
        CurveDaoProposer curveDaoProposer = new CurveDaoProposer("Curve Dao Proposer", address(this), address(daoPlatform));
        ResupplyDaoProposer resupplyDaoProposer = new ResupplyDaoProposer("Resupply Dao Proposer", address(this), address(daoPlatform));
        ResupplyVoteExecutor resupplyVoteExecutor = new ResupplyVoteExecutor("Resupply Vote Executor", address(this), address(daoPlatform), 0);

        assertEq(curveRegistry.gaugeController(), CURVE_GAUGE_CONTROLLER);
        assertEq(fxRegistry.gaugeController(), FX_GAUGE_CONTROLLER);
        assertEq(address(curveGaugeExecutor.voteDelegate()), VOTE_DELEGATE_EXTENSION);
        assertEq(fxGaugeExecutor.gaugeController(), FX_GAUGE_CONTROLLER);
        assertEq(fxGaugeExecutor.gaugeVoter(), FX_GAUGE_VOTER);
        assertEq(curveDaoProposer.CURVE_OWNERSHIP(), CURVE_OWNERSHIP_VOTING);
        assertEq(curveDaoProposer.CURVE_PARAMETER(), CURVE_PARAMETER_VOTING);
        assertEq(resupplyDaoProposer.RESUPPLY_VOTING(), RESUPPLY_VOTER);
        assertEq(resupplyVoteExecutor.RESUPPLY_STAKER(), RESUPPLY_PERMA_STAKER);
        assertEq(resupplyVoteExecutor.RESUPPLY_VOTER(), RESUPPLY_VOTER);
    }
}
