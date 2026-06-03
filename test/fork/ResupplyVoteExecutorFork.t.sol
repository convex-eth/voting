// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup, IResupplyRegistry} from "./Setup.sol";
import {ResupplyVoteExecutor} from "../../src/ResupplyVoteExecutor.sol";
import {DaoVotePlatform} from "../../src/DaoVotePlatform.sol";

contract ResupplyVoteExecutorForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function _votedDaoProposal() internal returns (DaoVotePlatform platform, uint256 pid) {
        (address holder,,) = liveVlCvxHolder();
        (,, platform) = deployDaoPlatform();
        pid = createDaoProposal(platform, 1 days, 200_001);
        voteDaoAsHolder(platform, pid, holder, 6500, 3500);
    }

    function testFork_liveResupplyExecutorDependenciesHaveExpectedShape() public view {
        assertHasCode(RESUPPLY_REGISTRY, "Resupply registry");
        assertHasCode(RESUPPLY_PERMA_STAKER, "Resupply perma-staker");
        assertHasCode(RESUPPLY_VOTER, "Resupply voter");

        address liveVoter = IResupplyRegistry(RESUPPLY_REGISTRY).getAddress("VOTER");
        address governanceStaker = IResupplyRegistry(RESUPPLY_REGISTRY).getAddress("STAKER");

        assertEq(liveVoter, RESUPPLY_VOTER);
        assertHasCode(governanceStaker, "Resupply governance staker");
        assertTrue(governanceStaker != RESUPPLY_PERMA_STAKER);
    }

    function testFork_resupplyDaoExecutorRequiresFinalizationForNonGuardian() public {
        (DaoVotePlatform platform, uint256 pid) = _votedDaoProposal();
        (, uint48 endTime,,,) = platform.proposals(pid);
        vm.warp(uint256(endTime) + TIME_BUFFER);

        ResupplyVoteExecutor executor = new ResupplyVoteExecutor("Resupply Vote Executor", address(this), address(platform), 0);

        vm.expectRevert(ResupplyVoteExecutor.NotFinished.selector);
        executor.executeDaoVote(pid);
    }

    function testFork_liveResupplySafeExecuteRevertRollsBackLocalState() public {
        (DaoVotePlatform platform, uint256 pid) = _votedDaoProposal();
        finalizeDaoProposal(platform, pid);

        ResupplyVoteExecutor executor = new ResupplyVoteExecutor("Resupply Vote Executor", address(this), address(platform), 0);

        vm.expectRevert();
        executor.executeDaoVote(pid);

        assertFalse(executor.isDone(pid));
    }
}
