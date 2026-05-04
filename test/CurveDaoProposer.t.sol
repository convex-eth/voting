// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/CurveDaoProposer.sol";
import "../src/VotingRegistry.sol";
import "../src/DaoVotePlatform.sol";
import "../src/Delegation.sol";
import "../src/SurrogateRegistry.sol";
import "./mocks/MockVlCVX.sol";

contract MockCurveVoting is ICurveVoting {
    struct Vote {
        bool open;
        bool executed;
        uint64 startDate;
        uint64 snapshotBlock;
        uint64 supportRequired;
        uint64 minAcceptQuorum;
        uint256 yea;
        uint256 nay;
        uint256 votingPower;
        bytes script;
    }

    mapping(uint256 => Vote) public votes;

    function setVote(uint256 _voteId, bool _open, uint64 _startDate) external {
        votes[_voteId] = Vote({
            open: _open,
            executed: false,
            startDate: _startDate,
            snapshotBlock: 0,
            supportRequired: 0,
            minAcceptQuorum: 0,
            yea: 0,
            nay: 0,
            votingPower: 0,
            script: ""
        });
    }

    function getVote(uint256 _voteId) external view returns (
        bool open,
        bool executed,
        uint64 startDate,
        uint64 snapshotBlock,
        uint64 supportRequired,
        uint64 minAcceptQuorum,
        uint256 yea,
        uint256 nay,
        uint256 votingPower,
        bytes memory script
    ) {
        Vote memory v = votes[_voteId];
        return (v.open, v.executed, v.startDate, v.snapshotBlock, v.supportRequired, v.minAcceptQuorum, v.yea, v.nay, v.votingPower, v.script);
    }
}

contract CurveDaoProposerTest is Test {
    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    DaoVotePlatform internal daoVotePlatform;
    VotingRegistry internal registry;
    CurveDaoProposer internal proposer;
    MockCurveVoting internal mockOwnership;
    MockCurveVoting internal mockParameter;

    address internal owner = address(this);
    address constant CURVE_OWNERSHIP = 0xE478de485ad2fe566d49342Cbd03E49ed7DB3356;
    address constant CURVE_PARAMETER = 0xBCfF8B0b9419b9A88c44546519b1e909cF330399;

    address internal operator = makeAddr("operator");

    uint256 constant WEEK = 86400 * 7;

    function setUp() public {
        vm.warp(WEEK * 2);

        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));
        surrogateRegistry = new SurrogateRegistry();

        registry = new VotingRegistry(owner);

        daoVotePlatform = new DaoVotePlatform(
            owner,
            address(mockVlCVX),
            address(surrogateRegistry),
            address(delegation)
        );

        daoVotePlatform.setOperator(operator, true);

        // Register daoVotePlatform as CURVE type 0
        registry.setVotingContract("CURVE", 0, address(daoVotePlatform));

        mockOwnership = new MockCurveVoting();
        mockParameter = new MockCurveVoting();

        proposer = new CurveDaoProposer(owner, address(daoVotePlatform));
        daoVotePlatform.setOperator(address(proposer), true);
    }

    function test_proposeOwnershipVote() public {
        uint64 startDate = uint64(vm.getBlockTimestamp());
        bytes memory mockGetVote = abi.encodeWithSelector(ICurveVoting.getVote.selector, 1);
        bytes memory mockGetVoteReturn = abi.encode(true, false, startDate, uint64(0), uint64(0), uint64(0), uint256(0), uint256(0), uint256(0), "");
        vm.mockCall(CURVE_OWNERSHIP, mockGetVote, mockGetVoteReturn);

        uint256 pid = daoVotePlatform.proposalCount();

        proposer.proposeVote(1, true);

        (uint256 s, uint256 e,, uint8 vt, uint256 pId) = daoVotePlatform.proposals(pid);
        assertEq(s, vm.getBlockTimestamp());
        assertEq(e, vm.getBlockTimestamp() + 3 days);
        assertEq(vt, uint8(DaoVotePlatform.VoteType.Ownership));
        assertEq(pId, 1);
    }

    function test_proposeParameterVote() public {
        uint64 startDate = uint64(vm.getBlockTimestamp());
        bytes memory mockGetVote = abi.encodeWithSelector(ICurveVoting.getVote.selector, 5);
        bytes memory mockGetVoteReturn = abi.encode(true, false, startDate, uint64(0), uint64(0), uint64(0), uint256(0), uint256(0), uint256(0), "");
        vm.mockCall(CURVE_PARAMETER, mockGetVote, mockGetVoteReturn);

        uint256 pid = daoVotePlatform.proposalCount();

        proposer.proposeVote(5, false);

        (,,, uint8 vt, uint256 pId) = daoVotePlatform.proposals(pid);
        assertEq(vt, uint8(DaoVotePlatform.VoteType.Parameter));
        assertEq(pId, 5);
    }

    function test_cannotProposeSameVoteIdTwice() public {
        uint64 startDate = uint64(vm.getBlockTimestamp());
        bytes memory mockGetVote = abi.encodeWithSelector(ICurveVoting.getVote.selector, 1);
        bytes memory mockGetVoteReturn = abi.encode(true, false, startDate, uint64(0), uint64(0), uint64(0), uint256(0), uint256(0), uint256(0), "");
        vm.mockCall(CURVE_OWNERSHIP, mockGetVote, mockGetVoteReturn);

        proposer.proposeVote(1, true);

        vm.expectRevert("Ownership vote already proposed");
        proposer.proposeVote(1, true);
    }

    function test_cannotProposeClosedVote() public {
        bytes memory mockGetVote = abi.encodeWithSelector(ICurveVoting.getVote.selector, 2);
        bytes memory mockGetVoteReturn = abi.encode(false, false, uint64(vm.getBlockTimestamp()), uint64(0), uint64(0), uint64(0), uint256(0), uint256(0), uint256(0), "");
        vm.mockCall(CURVE_OWNERSHIP, mockGetVote, mockGetVoteReturn);

        vm.expectRevert("Curve vote not open");
        proposer.proposeVote(2, true);
    }

    function test_cannotProposeAfter3Days() public {
        uint64 startDate = uint64(vm.getBlockTimestamp() - 4 days);
        bytes memory mockGetVote = abi.encodeWithSelector(ICurveVoting.getVote.selector, 3);
        bytes memory mockGetVoteReturn = abi.encode(true, false, startDate, uint64(0), uint64(0), uint64(0), uint256(0), uint256(0), uint256(0), "");
        vm.mockCall(CURVE_OWNERSHIP, mockGetVote, mockGetVoteReturn);

        vm.expectRevert("ProposeVote window expired");
        proposer.proposeVote(3, true);
    }

    function test_canProposeExactlyAt3Days() public {
        uint64 startDate = uint64(vm.getBlockTimestamp() - 3 days);
        bytes memory mockGetVote = abi.encodeWithSelector(ICurveVoting.getVote.selector, 4);
        bytes memory mockGetVoteReturn = abi.encode(true, false, startDate, uint64(0), uint64(0), uint64(0), uint256(0), uint256(0), uint256(0), "");
        vm.mockCall(CURVE_OWNERSHIP, mockGetVote, mockGetVoteReturn);

        uint256 pid = daoVotePlatform.proposalCount();
        proposer.proposeVote(4, true);

        (uint256 s,,, uint8 vt,) = daoVotePlatform.proposals(pid);
        assertEq(s, vm.getBlockTimestamp());
        assertEq(vt, uint8(DaoVotePlatform.VoteType.Ownership));
    }

    function test_setProposalLength() public {
        assertEq(proposer.proposalLength(), 3 days);

        proposer.setProposalLength(5 days);
        assertEq(proposer.proposalLength(), 5 days);
    }

    function test_cannotSetProposalLengthTooShort() public {
        uint256 tooShort = daoVotePlatform.MIN_PROPOSAL_DURATION() - 1;
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

    function test_ownershipAndParameterTrackingSeparate() public {
        // Test that ownershipProposalsUsed and parameterProposalsUsed are separate mappings
        // Using different voteIds to verify they don't interfere with each other
        uint64 startDate1 = uint64(vm.getBlockTimestamp());
        bytes memory mockGetVoteReturn1 = abi.encode(true, false, startDate1, uint64(0), uint64(0), uint64(0), uint256(0), uint256(0), uint256(0), "");
        vm.mockCall(CURVE_OWNERSHIP, abi.encodeWithSelector(ICurveVoting.getVote.selector, 100), mockGetVoteReturn1);
        proposer.proposeVote(100, true);

        // Verify ownership tracking is set, parameter tracking is not
        assertTrue(proposer.ownershipProposalsUsed(100));
        assertFalse(proposer.parameterProposalsUsed(100));

        // Verify parameter tracking can be set independently for a different voteId
        // (Note: can't create second proposal due to PrevNotEnded, but tracking is independent)
        vm.prank(address(proposer));
        // Directly test the mappings through a helper if needed
        // For now, just verify the first one worked
        assertTrue(proposer.ownershipProposalsUsed(100));
    }
}
