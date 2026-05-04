// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ResupplyDaoProposer.sol";
import "../src/DaoVotePlatform.sol";
import "../src/Delegation.sol";
import "../src/SurrogateRegistry.sol";
import "./mocks/MockVlCVX.sol";

contract MockResupplyVoting is IResupplyVoting {
    struct Proposal {
        string description;
        uint256 epoch;
        uint256 createdAt;
        uint256 quorumWeight;
        uint256 weightYes;
        uint256 weightNo;
        bool processed;
        bool executable;
        bytes payload;
    }

    mapping(uint256 => Proposal) public proposals;

    function setProposal(uint256 _id, uint256 _createdAt, bool _processed) external {
        proposals[_id] = Proposal({
            description: "",
            epoch: 0,
            createdAt: _createdAt,
            quorumWeight: 0,
            weightYes: 0,
            weightNo: 0,
            processed: _processed,
            executable: false,
            payload: ""
        });
    }

    function getProposalData(uint256 id) external view returns (
        string memory description,
        uint256 epoch,
        uint256 createdAt,
        uint256 quorumWeight,
        uint256 weightYes,
        uint256 weightNo,
        bool processed,
        bool executable,
        bytes memory payload
    ) {
        Proposal memory p = proposals[id];
        return (p.description, p.epoch, p.createdAt, p.quorumWeight, p.weightYes, p.weightNo, p.processed, p.executable, p.payload);
    }
}

contract ResupplyDaoProposerTest is Test {
    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    DaoVotePlatform internal daoVotePlatform;
    ResupplyDaoProposer internal proposer;
    MockResupplyVoting internal mockVoting;

    address internal owner = address(this);
    address constant RESUPPLY_VOTING = 0x11111111063874cE8dC6232cb5C1C849359476E6;

    function setUp() public {
        vm.warp(1_000_000);

        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));
        surrogateRegistry = new SurrogateRegistry();

        daoVotePlatform = new DaoVotePlatform(
            owner,
            address(mockVlCVX),
            address(surrogateRegistry),
            address(delegation)
        );

        daoVotePlatform.setOperator(address(this), true);

        mockVoting = new MockResupplyVoting();
        vm.etch(RESUPPLY_VOTING, address(mockVoting).code);

        proposer = new ResupplyDaoProposer(owner, address(daoVotePlatform));
        daoVotePlatform.setOperator(address(proposer), true);
    }

    function test_proposeVote() public {
        uint256 createdAt = vm.getBlockTimestamp();
        bytes memory mockData = abi.encode("", uint256(0), createdAt, uint256(0), uint256(0), uint256(0), false, false, "");
        vm.mockCall(RESUPPLY_VOTING, abi.encodeWithSelector(IResupplyVoting.getProposalData.selector, 1), mockData);

        uint256 pid = daoVotePlatform.proposalCount();

        proposer.proposeVote(1);

        (uint256 s, uint256 e,, uint8 vt, uint256 vId) = daoVotePlatform.proposals(pid);
        assertEq(s, createdAt);
        assertEq(e, createdAt + 3 days);
        assertEq(vt, uint8(DaoVotePlatform.VoteType.Ownership));
        assertEq(vId, 1);
    }

    function test_cannotProposeSameVoteIdTwice() public {
        uint256 createdAt = vm.getBlockTimestamp();
        bytes memory mockData = abi.encode("", uint256(0), createdAt, uint256(0), uint256(0), uint256(0), false, false, "");
        vm.mockCall(RESUPPLY_VOTING, abi.encodeWithSelector(IResupplyVoting.getProposalData.selector, 1), mockData);

        proposer.proposeVote(1);

        vm.expectRevert("Vote already proposed");
        proposer.proposeVote(1);
    }

    function test_cannotProposeProcessedVote() public {
        uint256 createdAt = vm.getBlockTimestamp();
        bytes memory mockData = abi.encode("", uint256(0), createdAt, uint256(0), uint256(0), uint256(0), true, false, "");
        vm.mockCall(RESUPPLY_VOTING, abi.encodeWithSelector(IResupplyVoting.getProposalData.selector, 2), mockData);

        vm.expectRevert("Resupply vote already processed");
        proposer.proposeVote(2);
    }

    function test_cannotProposeAfter3Days() public {
        uint256 createdAt = vm.getBlockTimestamp() - 4 days;
        bytes memory mockData = abi.encode("", uint256(0), createdAt, uint256(0), uint256(0), uint256(0), false, false, "");
        vm.mockCall(RESUPPLY_VOTING, abi.encodeWithSelector(IResupplyVoting.getProposalData.selector, 3), mockData);

        vm.expectRevert("ProposeVote window expired");
        proposer.proposeVote(3);
    }

    function test_canProposeExactlyAt3Days() public {
        uint256 createdAt = vm.getBlockTimestamp() - 3 days + 1;
        bytes memory mockData = abi.encode("", uint256(0), createdAt, uint256(0), uint256(0), uint256(0), false, false, "");
        vm.mockCall(RESUPPLY_VOTING, abi.encodeWithSelector(IResupplyVoting.getProposalData.selector, 4), mockData);

        uint256 pid = daoVotePlatform.proposalCount();
        proposer.proposeVote(4);

        (uint256 s,,, uint8 vt,) = daoVotePlatform.proposals(pid);
        assertEq(s, createdAt);
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
}
