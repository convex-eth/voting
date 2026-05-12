// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup, IResupplyRegistry} from "./Setup.sol";
import {ResupplyDaoProposer, IResupplyVoting} from "../../src/ResupplyDaoProposer.sol";
import {DaoVotePlatform} from "../../src/DaoVotePlatform.sol";

contract ResupplyDaoProposerForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function _proposalDataReturn(uint256 createdAt, bool processed) internal pure returns (bytes memory) {
        return abi.encode(
            string("controlled proposal"),
            uint256(0),
            createdAt,
            uint256(0),
            uint256(0),
            uint256(0),
            processed,
            false,
            bytes("")
        );
    }

    function _deployProposer() internal returns (DaoVotePlatform platform, ResupplyDaoProposer proposer) {
        (,, platform) = deployDaoPlatform();
        proposer = new ResupplyDaoProposer(address(this), address(platform));
        platform.setOperator(address(proposer), true);
    }

    function testFork_resupplyRegistryVoterMatchesLocalConstant() public view {
        assertHasCode(RESUPPLY_REGISTRY, "Resupply registry");
        assertHasCode(RESUPPLY_VOTER, "Resupply voter");

        address liveVoter = IResupplyRegistry(RESUPPLY_REGISTRY).getAddress("VOTER");
        assertEq(liveVoter, RESUPPLY_VOTER);
    }

    function testFork_liveResupplyVoterRespondsToProposalDataSelector() public view {
        (bool ok,) = RESUPPLY_VOTER.staticcall(abi.encodeWithSelector(IResupplyVoting.getProposalData.selector, 0));
        assertTrue(ok, "getProposalData staticcall");
    }

    function testFork_controlledResupplyVoteCanBeMirrored() public {
        (DaoVotePlatform platform, ResupplyDaoProposer proposer) = _deployProposer();
        uint256 resupplyVoteId = 50_001;
        uint256 createdAt = block.timestamp;

        vm.mockCall(
            RESUPPLY_VOTER,
            abi.encodeWithSelector(IResupplyVoting.getProposalData.selector, resupplyVoteId),
            _proposalDataReturn(createdAt, false)
        );

        proposer.proposeVote(resupplyVoteId);

        uint256 pid = platform.proposalCount() - 1;
        (uint48 startTime, uint48 endTime,, uint8 voteType, uint104 externalId) = platform.proposals(pid);
        assertEq(startTime, uint48(block.timestamp));
        assertEq(endTime, uint48(block.timestamp + proposer.proposalLength()));
        assertEq(voteType, uint8(DaoVotePlatform.VoteType.Ownership));
        assertEq(externalId, resupplyVoteId);
    }

    function testFork_lateResupplyVoteWindowStillValid() public {
        (DaoVotePlatform platform, ResupplyDaoProposer proposer) = _deployProposer();
        uint256 resupplyVoteId = 60_001;
        uint256 createdAt = block.timestamp - 3 days + 1;

        vm.mockCall(
            RESUPPLY_VOTER,
            abi.encodeWithSelector(IResupplyVoting.getProposalData.selector, resupplyVoteId),
            _proposalDataReturn(createdAt, false)
        );

        proposer.proposeVote(resupplyVoteId);

        uint256 pid = platform.proposalCount() - 1;
        (uint48 startTime, uint48 endTime,,,) = platform.proposals(pid);
        assertEq(startTime, uint48(block.timestamp));
        assertEq(endTime, uint48(block.timestamp + proposer.proposalLength()));
    }

    function testFork_processedResupplyVoteIsRejectedFromControlledFixture() public {
        (, ResupplyDaoProposer proposer) = _deployProposer();
        uint256 resupplyVoteId = 70_001;

        vm.mockCall(
            RESUPPLY_VOTER,
            abi.encodeWithSelector(IResupplyVoting.getProposalData.selector, resupplyVoteId),
            _proposalDataReturn(block.timestamp, true)
        );

        vm.expectRevert("Resupply vote already processed");
        proposer.proposeVote(resupplyVoteId);
    }

    function testFork_staleResupplyVoteIsRejectedFromControlledFixture() public {
        (, ResupplyDaoProposer proposer) = _deployProposer();
        uint256 resupplyVoteId = 80_001;

        vm.mockCall(
            RESUPPLY_VOTER,
            abi.encodeWithSelector(IResupplyVoting.getProposalData.selector, resupplyVoteId),
            _proposalDataReturn(block.timestamp - 3 days - 1, false)
        );

        vm.expectRevert("ProposeVote window expired");
        proposer.proposeVote(resupplyVoteId);
    }
}
