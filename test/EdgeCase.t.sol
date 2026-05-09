// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/DaoVotePlatform.sol";
import "../src/SurrogateRegistry.sol";
import "../src/Delegation.sol";
import "./mocks/MockVlCVX.sol";

contract EdgeCaseTest is Test {
    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;
    SurrogateRegistry internal surrogateRegistry;
    DaoVotePlatform internal dao;

    address internal alice = makeAddr("alice");
    address internal delegate1 = makeAddr("delegate1");
    address internal operator = makeAddr("operator");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WD = 1e17;

    function setUp() public {
        vm.warp(WEEK * 2);

        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));
        surrogateRegistry = new SurrogateRegistry();

        dao = new DaoVotePlatform(
            address(this),
            address(mockVlCVX),
            address(surrogateRegistry),
            address(delegation)
        );

        dao.setOperator(operator, true);
    }

    function test_syncRelockVoteEdgeCase() public {
        // A delegates to D
        vm.prank(alice);
        delegation.setDelegate(delegate1);

        // A locks vlcvx (1000) but does NOT sync
        mockVlCVX.mockLock(alice, 1000 * WD, 1000 * WD);

        // D also locks so they have base weight
        mockVlCVX.mockLock(delegate1, 500 * WD, 500 * WD);

        // next epoch
        uint256 currentEpoch = (vm.getBlockTimestamp() / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);

        // start dao proposal
        uint256 startTime = vm.getBlockTimestamp() + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Parameter, 1);
        uint256 pid = dao.proposalCount() - 1;
        vm.warp(startTime);

        // D votes (using base weight only, delegation weight for A is 0 since A never synced)
        console.log("About to vote D");
        (,, uint48 propEpoch,,) = dao.proposals(pid);
        console.log("proposal epoch:", propEpoch);
        console.log("D balanceAtEpoch:", mockVlCVX.balanceAtEpochOf(propEpoch, delegate1));
        console.log("D delegation weight:", delegation.userWeightAtEpochOf(propEpoch, delegate1));
        vm.prank(delegate1);
        dao.vote(delegate1, 10000, 0);
        console.log("D voted ok");

        // A syncs (will create snapshot for change of 0 to 1000)
        delegation.sync(alice);
        console.log("A synced");

        // A relocks
        mockVlCVX.mockRelock(alice, 0, 1500 * WD);
        console.log("A relocked");

        console.log("About to vote A");
        console.log("A balanceAtEpoch:", mockVlCVX.balanceAtEpochOf(propEpoch, alice));
        console.log("A delegation weight:", delegation.userWeightAtEpochOf(propEpoch, alice));
        (uint96 aBase,,,,,,,) = dao.userInfo(pid, alice);
        console.log("A userInfo baseWeight:", uint256(aBase));

        // A votes
        vm.prank(alice);
        dao.vote(alice, 10000, 0);
        console.log("A voted ok");

        // check vote totals vs sum of voter effective weights
        uint256 voteTotals = dao.voteTotals(pid);
        uint256 yes = dao.getYes(pid);
        uint256 no = dao.getNo(pid);

        uint256 sumEffective;
        uint256 voterCount = dao.getVoterCount(pid);
        for (uint256 i = 0; i < voterCount; i++) {
            address voter = dao.getVoterAtIndex(pid, i);
            (,,, uint256 baseWeight, int256 adjustedWeight) = dao.getVote(pid, voter);
            int256 effective = int256(baseWeight) + adjustedWeight;
            if (effective > 0) sumEffective += uint256(effective);
        }

        console.log("voteTotals:", voteTotals);
        console.log("yes + no:", yes + no);
        console.log("sumEffective:", sumEffective);

        assertEq(voteTotals, sumEffective, "vote totals mismatch");
    }
}
