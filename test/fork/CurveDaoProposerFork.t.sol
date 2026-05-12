// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ForkSetup} from "./Setup.sol";
import {CurveDaoProposer, ICurveVoting} from "../../src/CurveDaoProposer.sol";
import {DaoVotePlatform} from "../../src/DaoVotePlatform.sol";

contract CurveDaoProposerForkTest is ForkSetup {
    function setUp() public {
        forkHead();
    }

    function _openCurveVoteReturn(uint256 startDate) internal view returns (bytes memory) {
        return abi.encode(
            true,
            false,
            uint64(startDate),
            uint64(block.number),
            uint64(0),
            uint64(0),
            uint256(0),
            uint256(0),
            uint256(0),
            bytes("")
        );
    }

    function _deployProposer() internal returns (DaoVotePlatform platform, CurveDaoProposer proposer) {
        (,, platform) = deployDaoPlatform();
        proposer = new CurveDaoProposer(address(this), address(platform));
        platform.setOperator(address(proposer), true);
    }

    function testFork_liveCurveVotingAppsExposeExpectedGetVoteShape() public view {
        assertHasCode(CURVE_OWNERSHIP_VOTING, "ownership voting app");
        assertHasCode(CURVE_PARAMETER_VOTING, "parameter voting app");

        ICurveVoting(CURVE_OWNERSHIP_VOTING).getVote(0);
        ICurveVoting(CURVE_PARAMETER_VOTING).getVote(0);
    }

    function testFork_controlledOwnershipVoteCanBeMirrored() public {
        (DaoVotePlatform platform, CurveDaoProposer proposer) = _deployProposer();
        uint256 curveVoteId = 10_001;

        vm.mockCall(
            CURVE_OWNERSHIP_VOTING,
            abi.encodeWithSelector(ICurveVoting.getVote.selector, curveVoteId),
            _openCurveVoteReturn(block.timestamp)
        );

        proposer.proposeVote(curveVoteId, true);

        uint256 pid = platform.proposalCount() - 1;
        (uint48 startTime, uint48 endTime,, uint8 voteType, uint104 externalId) = platform.proposals(pid);
        assertEq(startTime, uint48(block.timestamp));
        assertEq(endTime, uint48(block.timestamp + proposer.proposalLength()));
        assertEq(voteType, uint8(DaoVotePlatform.VoteType.Ownership));
        assertEq(externalId, curveVoteId);
    }

    function testFork_controlledParameterVoteCanBeMirrored() public {
        (DaoVotePlatform platform, CurveDaoProposer proposer) = _deployProposer();
        uint256 curveVoteId = 20_001;

        vm.mockCall(
            CURVE_PARAMETER_VOTING,
            abi.encodeWithSelector(ICurveVoting.getVote.selector, curveVoteId),
            _openCurveVoteReturn(block.timestamp)
        );

        proposer.proposeVote(curveVoteId, false);

        uint256 pid = platform.proposalCount() - 1;
        (,,, uint8 voteType, uint104 externalId) = platform.proposals(pid);
        assertEq(voteType, uint8(DaoVotePlatform.VoteType.Parameter));
        assertEq(externalId, curveVoteId);
    }

    function testFork_closedCurveVoteIsRejectedFromControlledFixture() public {
        (, CurveDaoProposer proposer) = _deployProposer();
        uint256 curveVoteId = 30_001;

        vm.mockCall(
            CURVE_OWNERSHIP_VOTING,
            abi.encodeWithSelector(ICurveVoting.getVote.selector, curveVoteId),
            abi.encode(
                false,
                false,
                uint64(block.timestamp),
                uint64(block.number),
                uint64(0),
                uint64(0),
                uint256(0),
                uint256(0),
                uint256(0),
                bytes("")
            )
        );

        vm.expectRevert("Curve vote not open");
        proposer.proposeVote(curveVoteId, true);
    }

    function testFork_staleCurveVoteIsRejectedFromControlledFixture() public {
        (, CurveDaoProposer proposer) = _deployProposer();
        uint256 curveVoteId = 40_001;

        vm.mockCall(
            CURVE_OWNERSHIP_VOTING,
            abi.encodeWithSelector(ICurveVoting.getVote.selector, curveVoteId),
            _openCurveVoteReturn(block.timestamp - 3 days - 1)
        );

        vm.expectRevert("ProposeVote window expired");
        proposer.proposeVote(curveVoteId, true);
    }
}
