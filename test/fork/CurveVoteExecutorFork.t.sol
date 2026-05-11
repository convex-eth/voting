// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";
import {CurveVoteExecutor} from "../../src/CurveVoteExecutor.sol";
import {DaoVotePlatform} from "../../src/DaoVotePlatform.sol";

contract CurveVoteExecutorForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function _votedDaoProposal() internal returns (DaoVotePlatform platform, uint256 pid) {
        (address holder,,) = liveVlCvxHolder();
        (,, platform) = deployDaoPlatform();
        pid = createDaoProposal(platform, 1 days, 100_001);
        voteDaoAsHolder(platform, holder, 7000, 3000);
    }

    function testFork_liveVoteDelegateExtensionHasCode() public view {
        assertHasCode(VOTE_DELEGATE_EXTENSION, "VoteDelegateExtension");
    }

    function testFork_curveDaoExecutorRequiresFinalizationForNonGuardian() public {
        (DaoVotePlatform platform, uint256 pid) = _votedDaoProposal();
        (, uint48 endTime,,,) = platform.proposals(pid);
        vm.warp(uint256(endTime) + TIME_BUFFER);

        CurveVoteExecutor executor = new CurveVoteExecutor(
            address(this),
            address(platform),
            VOTE_DELEGATE_EXTENSION,
            0
        );

        vm.expectRevert(CurveVoteExecutor.NotFinished.selector);
        executor.executeDaoVote(pid);
    }

    function testFork_liveCurveDaoAdapterRevertRollsBackLocalState() public {
        (DaoVotePlatform platform, uint256 pid) = _votedDaoProposal();
        finalizeDaoProposal(platform, pid);

        CurveVoteExecutor executor = new CurveVoteExecutor(
            address(this),
            address(platform),
            VOTE_DELEGATE_EXTENSION,
            0
        );

        vm.expectRevert();
        executor.executeDaoVote(pid);

        assertFalse(executor.isDone(pid));
    }
}
