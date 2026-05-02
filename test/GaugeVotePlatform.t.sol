// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/SurrogateRegistry.sol";
import "../src/Delegation.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "./mocks/MockVlCVX.sol";
import "./mocks/MockGauges.sol";

contract GaugeVotePlatformTest is Test {
    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;
    CurveGaugeRegistry internal gaugeRegistry;
    SurrogateRegistry internal surrogateRegistry;
    GaugeVotePlatform internal platform;

    MockCurveGauge internal gauge1;
    MockCurveGauge internal gauge2;
    MockCurveGauge internal gauge3;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve");
    address internal operator = makeAddr("operator");
    address internal surrogate = makeAddr("surrogate");

    uint256 constant WEEK = 86400 * 7;
    uint256 constant WD = 1e17;

    uint256 internal proposalEpoch;

    function setUp() public {
        vm.warp(WEEK * 2);

        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));

        address gaugeController = address(new MockGaugeController());
        vm.etch(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB, address(gaugeController).code);

        gaugeRegistry = new CurveGaugeRegistry();
        surrogateRegistry = new SurrogateRegistry();

        platform = new GaugeVotePlatform(
            address(this),
            address(mockVlCVX),
            address(gaugeRegistry),
            address(surrogateRegistry),
            address(delegation)
        );

        gauge1 = new MockCurveGauge();
        gauge2 = new MockCurveGauge();
        gauge3 = new MockCurveGauge();

        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge1), 1000);
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge2), 2000);
        MockGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB).setGaugeWeight(address(gauge3), 500);

        gaugeRegistry.setGauge(address(gauge1));
        gaugeRegistry.setGauge(address(gauge2));
        gaugeRegistry.setGauge(address(gauge3));

        platform.setOperator(operator, true);
    }

    function _lockAndDelegate(address user, uint256 amount, address delegateAddr) internal {
        mockVlCVX.mockLock(user, amount * WD, amount * WD);
        if (delegateAddr != address(0)) {
            vm.prank(user);
            delegation.setDelegate(delegateAddr);
        }
    }

    function _warpToNextEpoch() internal {
        uint256 currentEpoch = (block.timestamp / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);
    }

    function _createProposal() internal returns (uint256) {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        platform.createProposal(startTime, endTime);
        uint256 pid = platform.proposalCount() - 1;
        (,, proposalEpoch) = platform.proposals(pid);
        vm.warp(startTime);
        return pid;
    }

    function _vote(address user, address[] memory gauges, uint256[] memory weights) internal {
        vm.prank(user);
        platform.vote(user, gauges, weights);
    }

    function _getGauges(address g1) internal pure returns (address[] memory) {
        address[] memory gauges = new address[](1);
        gauges[0] = g1;
        return gauges;
    }

    function _getWeights(uint256 w1) internal pure returns (uint256[] memory) {
        uint256[] memory weights = new uint256[](1);
        weights[0] = w1;
        return weights;
    }

    function _getGauges2(address g1, address g2) internal pure returns (address[] memory) {
        address[] memory gauges = new address[](2);
        gauges[0] = g1;
        gauges[1] = g2;
        return gauges;
    }

    function _getWeights2(uint256 w1, uint256 w2) internal pure returns (uint256[] memory) {
        uint256[] memory weights = new uint256[](2);
        weights[0] = w1;
        weights[1] = w2;
        return weights;
    }

    // ========== Proposal Tests ==========

    function test_createProposal() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        platform.createProposal(startTime, endTime);

        (uint256 s, uint256 e, uint256 ep) = platform.proposals(0);
        assertEq(s, startTime);
        assertEq(e, endTime);
    }

    function test_cannotCreateProposalTooShort() public {
        uint256 startTime = block.timestamp + 1 days;
        vm.prank(operator);
        vm.expectRevert(GaugeVotePlatform.BadTime.selector);
        platform.createProposal(startTime, startTime + 2 days);
    }

    function test_cannotCreateProposalTooLong() public {
        uint256 startTime = block.timestamp + 1 days;
        vm.prank(operator);
        vm.expectRevert(GaugeVotePlatform.BadTime.selector);
        platform.createProposal(startTime, startTime + 7 days);
    }

    function test_cannotCreateBeforePreviousEnds() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        platform.createProposal(startTime, endTime);

        vm.warp(startTime);
        vm.prank(operator);
        vm.expectRevert(GaugeVotePlatform.PrevNotEnded.selector);
        platform.createProposal(startTime + 5 days, startTime + 9 days);
    }

    function test_forceEndProposal() public {
        uint256 pid = _createProposal();
        vm.prank(operator);
        platform.forceEndProposal();

        (uint256 s, uint256 e, uint256 ep) = platform.proposals(pid);
        assertEq(s, 0);
        assertEq(e, 0);
        assertEq(ep, 0);
    }

    function test_forceEndProposalBeforeStart() public {
        _warpToNextEpoch();
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        platform.createProposal(startTime, endTime);

        vm.prank(operator);
        platform.forceEndProposal();

        (uint256 s, uint256 e, uint256 ep) = platform.proposals(0);
        assertEq(s, 0);
        assertEq(e, 0);
        assertEq(ep, 0);
    }

    // ========== Basic Voting ==========

    function test_simpleVote() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        assertGt(platform.gaugeTotal(pid, address(gauge1)), 0);
    }

    function test_cannotVoteWithoutWeight() public {
        uint256 pid = _createProposal();

        address[] memory gauges = _getGauges(address(gauge1));
        uint256[] memory weights = _getWeights(10000);
        vm.prank(alice);
        vm.expectRevert(GaugeVotePlatform.NoWeight.selector);
        platform.vote(alice, gauges, weights);
    }

    function test_cannotVoteBeforeStart() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();

        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        platform.createProposal(startTime, endTime);

        address[] memory gauges = _getGauges(address(gauge1));
        uint256[] memory weights = _getWeights(10000);
        vm.prank(alice);
        vm.expectRevert(GaugeVotePlatform.NotStarted.selector);
        platform.vote(alice, gauges, weights);
    }

    function test_cannotVoteAfterEnd() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        (, uint256 endTime,) = platform.proposals(pid);
        vm.warp(endTime + 1);

        address[] memory gauges = _getGauges(address(gauge1));
        uint256[] memory weights = _getWeights(10000);
        vm.prank(alice);
        vm.expectRevert(GaugeVotePlatform.Ended.selector);
        platform.vote(alice, gauges, weights);
    }

    function test_equalizerCanVoteDuringOvertime() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        platform.setOvertimeAccount(alice, true);

        (, uint256 endTime6,) = platform.proposals(pid);
        vm.warp(endTime6 + 5 minutes);

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        (, uint256[] memory w, bool voted,,) = platform.getVote(pid, alice);
        assertTrue(voted);
        assertEq(w[0], 10000);
    }

    function test_nonEqualizerCannotVoteDuringOvertime() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        (, uint256 endTime7,) = platform.proposals(pid);
        vm.warp(endTime7 + 5 minutes);

        address[] memory gauges = _getGauges(address(gauge1));
        uint256[] memory weights = _getWeights(10000);
        vm.prank(alice);
        vm.expectRevert(GaugeVotePlatform.Ended.selector);
        platform.vote(alice, gauges, weights);
    }

    function test_gaugeValidation() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        address fakeGauge = makeAddr("fakeGauge");
        address[] memory gauges = _getGauges(fakeGauge);
        uint256[] memory weights = _getWeights(10000);
        vm.prank(alice);
        vm.expectRevert(GaugeVotePlatform.NotGauge.selector);
        platform.vote(alice, gauges, weights);
    }

    function test_weightLimitExceeded() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        address[] memory gauges = _getGauges2(address(gauge1), address(gauge2));
        uint256[] memory weights = _getWeights2(6000, 5000);
        vm.prank(alice);
        vm.expectRevert(GaugeVotePlatform.MaxWeight.selector);
        platform.vote(alice, gauges, weights);
    }

    // ========== Scenario 1: Delegate with two delegatees ==========

    function test_scenario1_delegateWithTwoDelegatees() public {
        _lockAndDelegate(alice, 1000, carol);
        _lockAndDelegate(bob, 500, carol);
        _lockAndDelegate(carol, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        uint256 carolBal = mockVlCVX.balanceAtEpochOf(proposalEpoch, carol);
        uint256 carolDelBal = delegation.balanceAtEpochOf(proposalEpoch, carol);

        _vote(carol, _getGauges(address(gauge1)), _getWeights(10000));

        (,,,, int256 carolAdj) = platform.getVote(pid, carol);
        uint256 carolTotal = platform.gaugeTotal(pid, address(gauge1));

        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        (,,,, int256 carolAdjAfter) = platform.getVote(pid, carol);
        uint256 carolNewTotal = platform.gaugeTotal(pid, address(gauge1));
        assertLt(carolNewTotal, carolTotal);

        (,,,, int256 aliceAdj) = platform.getVote(pid, alice);
        assertEq(aliceAdj, 0);

        _vote(bob, _getGauges(address(gauge3)), _getWeights(10000));

        uint256 g1Total = platform.gaugeTotal(pid, address(gauge1));
        uint256 g2Total = platform.gaugeTotal(pid, address(gauge2));
        uint256 g3Total = platform.gaugeTotal(pid, address(gauge3));
        assertGt(g1Total, 0);
        assertGt(g2Total, 0);
        assertGt(g3Total, 0);
    }

    // ========== Scenario 2: Delegatee votes before delegate ==========

    function test_scenario2_delegateeVotesFirst() public {
        _lockAndDelegate(alice, 500, bob);
        _lockAndDelegate(bob, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        (,,,, int256 aliceAdj) = platform.getVote(pid, alice);
        assertEq(aliceAdj, 0);

        (,,,, int256 bobAdj) = platform.getVote(pid, bob);
        assertLt(bobAdj, 0);

        _vote(bob, _getGauges(address(gauge2)), _getWeights(10000));

        (,,,, int256 bobAdjAfter) = platform.getVote(pid, bob);
        assertEq(bobAdjAfter, 0);

        uint256 aliceWeight = mockVlCVX.balanceAtEpochOf(proposalEpoch, alice);
        uint256 bobWeight = mockVlCVX.balanceAtEpochOf(proposalEpoch, bob);
        assertGt(platform.gaugeTotal(pid, address(gauge1)), 0);
        assertGt(platform.gaugeTotal(pid, address(gauge2)), 0);
    }

    // ========== Scenario 3: Chain delegation (A->B->C) ==========

    function test_scenario3_chainDelegation() public {
        _lockAndDelegate(alice, 500, bob);
        _lockAndDelegate(bob, 1000, carol);
        _lockAndDelegate(carol, 3000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        (,,,, int256 bobAdj) = platform.getVote(pid, bob);
        assertLt(bobAdj, 0);

        _vote(bob, _getGauges(address(gauge2)), _getWeights(10000));

        (,,,, int256 bobAdjAfter) = platform.getVote(pid, bob);
        assertEq(bobAdjAfter, 0);

        (,,,, int256 carolAdj) = platform.getVote(pid, carol);
        assertLt(carolAdj, 0);

        _vote(carol, _getGauges(address(gauge3)), _getWeights(10000));

        uint256 totalVoteWeight = platform.voteTotals(pid);
        uint256 expectedTotal = 500 * WD + 1000 * WD + 3000 * WD;
        assertApproxEqAbs(totalVoteWeight, expectedTotal, 3 * WD);
    }

    // ========== Scenario 4: Self-delegating user ==========

    function test_scenario4_selfDelegating() public {
        _lockAndDelegate(alice, 3000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        (uint256 bw, int256 adj,,, address del, ) = platform.userInfo(pid, alice);
        assertEq(bw, 3000 * WD);
        assertEq(adj, 0);
        assertEq(del, alice);
    }

    // ========== Scenario 5: Pure delegate (zero baseWeight) ==========

    function test_scenario5_pureDelegate() public {
        _lockAndDelegate(alice, 1000, dave);
        _lockAndDelegate(bob, 500, dave);
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        uint256 daveDelBal = delegation.balanceAtEpochOf(proposalEpoch, dave);

        _vote(dave, _getGauges(address(gauge1)), _getWeights(10000));

        (uint256 daveBw, int256 daveAdj,,, address daveDel, ) = platform.userInfo(pid, dave);
        assertEq(daveBw, 0);
        assertGt(daveAdj, 0);
        assertEq(daveDel, dave);

        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        (,,,, int256 daveAdjAfter) = platform.getVote(pid, dave);
        assertLt(daveAdjAfter, daveAdj);
    }

    // ========== Scenario 7: Re-voting with weight change ==========

    function test_scenario7_revoteWithWeightChange() public {
        _lockAndDelegate(alice, 500, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        uint256 g1Total = platform.gaugeTotal(pid, address(gauge1));
        assertGt(g1Total, 0);

        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        assertEq(platform.gaugeTotal(pid, address(gauge1)), 0);
        uint256 g2Total = platform.gaugeTotal(pid, address(gauge2));
        assertApproxEqAbs(g2Total, g1Total, WD);
    }

    // ========== Re-voting (change allocation) ==========

    function test_revoteChangeAllocation() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        uint256 g1Before = platform.gaugeTotal(pid, address(gauge1));
        assertGt(g1Before, 0);
        assertEq(platform.gaugeTotal(pid, address(gauge2)), 0);

        _vote(alice, _getGauges2(address(gauge1), address(gauge2)), _getWeights2(5000, 5000));

        uint256 g1After = platform.gaugeTotal(pid, address(gauge1));
        uint256 g2After = platform.gaugeTotal(pid, address(gauge2));
        assertGt(g2After, 0);
    }

    // ========== Surrogate voting ==========

    function test_surrogateVote() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        vm.prank(alice);
        surrogateRegistry.setSurrogate(surrogate);

        vm.prank(surrogate);
        platform.vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        (,,, uint8 vs,, ) = platform.userInfo(pid, alice);
        assertEq(vs, uint8(1));
    }

    function test_userCanOverrideSurrogateVote() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        vm.prank(alice);
        surrogateRegistry.setSurrogate(surrogate);

        vm.prank(surrogate);
        platform.vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        vm.prank(alice);
        platform.vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        (,,, uint8 vs,, ) = platform.userInfo(pid, alice);
        assertEq(vs, uint8(2));
    }

    function test_surrogateCannotOverrideUserVote() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        vm.prank(alice);
        surrogateRegistry.setSurrogate(surrogate);

        vm.prank(alice);
        platform.vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        vm.prank(surrogate);
        vm.expectRevert(GaugeVotePlatform.NotVoteAuth.selector);
        platform.vote(alice, _getGauges(address(gauge2)), _getWeights(10000));
    }

    // ========== Signer auth ==========

    function test_randomAddressCannotVoteForOthers() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        _createProposal();

        address randomAddr = makeAddr("random");
        address[] memory gauges = _getGauges(address(gauge1));
        uint256[] memory weights = _getWeights(10000);
        vm.prank(randomAddr);
        vm.expectRevert(GaugeVotePlatform.NotSigner.selector);
        platform.vote(alice, gauges, weights);
    }

    // ========== Delegatee votes, then delegate re-votes ==========

    function test_delegateeVotesThenDelegateRevotes() public {
        _lockAndDelegate(alice, 1000, carol);
        _lockAndDelegate(carol, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(carol, _getGauges(address(gauge1)), _getWeights(10000));

        uint256 carolWeight = 2000 * WD + delegation.balanceAtEpochOf(proposalEpoch, carol);
        uint256 g1AfterCarol = platform.gaugeTotal(pid, address(gauge1));

        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        uint256 g1AfterAlice = platform.gaugeTotal(pid, address(gauge1));
        assertLt(g1AfterAlice, g1AfterCarol);

        _vote(carol, _getGauges(address(gauge3)), _getWeights(10000));

        (,,,, int256 carolAdj) = platform.getVote(pid, carol);
        assertEq(carolAdj, 0);
    }

    // ========== Ownership ==========

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        platform.transferOwnership(newOwner);

        vm.prank(newOwner);
        platform.acceptOwnership();

        assertEq(platform.owner(), newOwner);
    }

    function test_onlyOwnerCanTransfer() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("notOwner")));
        platform.transferOwnership(makeAddr("newOwner"));
    }

    function test_onlyOperatorCanCreateProposal() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(makeAddr("notOp"));
        vm.expectRevert(GaugeVotePlatform.NotOperator.selector);
        platform.createProposal(startTime, endTime);
    }

    // ========== voteTotals tracking ==========

    function test_voteTotalsAccumulates() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _vote(bob, _getGauges(address(gauge2)), _getWeights(10000));

        uint256 total = platform.voteTotals(pid);
        uint256 aliceBal = mockVlCVX.balanceAtEpochOf(proposalEpoch, alice);
        uint256 bobBal = mockVlCVX.balanceAtEpochOf(proposalEpoch, bob);
        assertApproxEqAbs(total, aliceBal + bobBal, 2 * WD);
    }

    // ========== Multiple proposals ==========

    function test_multipleProposals() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid1 = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        assertGt(platform.gaugeTotal(pid1, address(gauge1)), 0);

        (, uint256 endTime1,) = platform.proposals(pid1);
        vm.warp(endTime1 + 10 minutes + 1);

        uint256 startTime2 = block.timestamp + 1 days;
        uint256 endTime2 = startTime2 + 4 days;
        vm.prank(operator);
        platform.createProposal(startTime2, endTime2);
        vm.warp(startTime2);

        uint256 pid2 = platform.proposalCount() - 1;

        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        assertEq(platform.gaugeTotal(pid2, address(gauge1)), 0);
        assertGt(platform.gaugeTotal(pid2, address(gauge2)), 0);
    }

    // ========== Force end disables voting ==========

    function test_forceEndDisablesVoting() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        (uint256 startTime, uint256 endTime,) = platform.proposals(pid);
        vm.warp(startTime + 1 days);

        vm.prank(operator);
        platform.forceEndProposal();

        address[] memory gauges = _getGauges(address(gauge1));
        uint256[] memory weights = _getWeights(10000);
        vm.prank(alice);
        vm.expectRevert(GaugeVotePlatform.Ended.selector);
        platform.vote(alice, gauges, weights);
    }

    // ========== getVoterCount ==========

    function test_getVoterCount() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        assertEq(platform.getVoterCount(pid), 0);

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        assertEq(platform.getVoterCount(pid), 1);

        _vote(bob, _getGauges(address(gauge2)), _getWeights(10000));
        assertEq(platform.getVoterCount(pid), 2);
    }

    // ========== proposalCount ==========

    function test_proposalCount() public {
        assertEq(platform.proposalCount(), 0);
        _createProposal();
        assertEq(platform.proposalCount(), 1);
    }

    // ==========.selfDelegateGetsNoAdjustedWeight ==========

    function test_selfDelegatingNoAdjustedWeight() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        (uint256 bw, int256 adj,,, address del, ) = platform.userInfo(pid, alice);
        assertEq(bw, 1000 * WD);
        assertEq(adj, 0);
        assertEq(del, alice);
    }

    // ========== Gauge Entry Enumeration ==========

    function test_gaugeTotalReturnsZeroForUnvoted() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        _createProposal();

        assertEq(platform.gaugeTotal(0, address(gauge1)), 0);
    }

    function test_gaugeCountAndEntries() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        assertEq(platform.getGaugeCount(pid), 0);

        address[] memory g = new address[](3);
        g[0] = address(gauge1);
        g[1] = address(gauge2);
        g[2] = address(gauge3);
        uint256[] memory w = new uint256[](3);
        w[0] = 3333;
        w[1] = 3333;
        w[2] = 3334;
        _vote(alice, g, w);

        assertEq(platform.getGaugeCount(pid), 3);

        uint256 total;
        for (uint256 i = 0; i < platform.getGaugeCount(pid); i++) {
            (address gauge, uint256 weight) = platform.getGaugeEntry(pid, i);
            assertGt(weight, 0);
            total += weight;
        }
        assertApproxEqAbs(total, 1000 * WD, WD);
    }

    function test_gaugeEntryRemovedWhenTotalHitsZero() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        address[] memory g3 = new address[](3);
        g3[0] = address(gauge1);
        g3[1] = address(gauge2);
        g3[2] = address(gauge3);
        uint256[] memory w3 = new uint256[](3);
        w3[0] = 3333;
        w3[1] = 3333;
        w3[2] = 3334;
        _vote(alice, g3, w3);
        assertEq(platform.getGaugeCount(pid), 3);

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        assertEq(platform.getGaugeCount(pid), 1);
        (address g,) = platform.getGaugeEntry(pid, 0);
        assertEq(g, address(gauge1));
        assertEq(platform.gaugeTotal(pid, address(gauge2)), 0);
        assertEq(platform.gaugeTotal(pid, address(gauge3)), 0);
    }

    function test_gaugeTotalAcrossProposals() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid1 = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        assertEq(platform.getGaugeCount(pid1), 1);
        assertGt(platform.gaugeTotal(pid1, address(gauge1)), 0);

        (, uint256 endTime1,) = platform.proposals(pid1);
        vm.warp(endTime1 + 10 minutes + 1);

        uint256 startTime2 = block.timestamp + 1 days;
        vm.prank(operator);
        platform.createProposal(startTime2, startTime2 + 4 days);
        vm.warp(startTime2);

        uint256 pid2 = platform.proposalCount() - 1;
        assertEq(platform.getGaugeCount(pid2), 0);
        assertEq(platform.gaugeTotal(pid2, address(gauge1)), 0);
    }

    // ========== isFinalized ==========

    function test_isFinalized() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        assertFalse(platform.isFinalized(pid));

        (, uint256 endTime,) = platform.proposals(pid);

        vm.warp(endTime + 5 minutes);
        assertFalse(platform.isFinalized(pid));

        vm.warp(endTime + 10 minutes + 1);
        assertTrue(platform.isFinalized(pid));
    }

    function test_isFinalized_forceEnded() public {
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        assertFalse(platform.isFinalized(pid));

        vm.prank(operator);
        platform.forceEndProposal();

        assertFalse(platform.isFinalized(pid));
    }

    // ========== Invariant: voteTotals == sum of all voted users' effective weights ==========

    function _sumAllEffectiveWeights(uint256 pid) internal view returns (uint256 total) {
        uint256 count = platform.getVoterCount(pid);
        for (uint256 i = 0; i < count; i++) {
            address voter = platform.getVoterAtIndex(pid, i);
            (,,,, int256 adjusted) = platform.getVote(pid, voter);
            (uint256 base,,,,,) = platform.userInfo(pid, voter);
            int256 effective = int256(base) + adjusted;
            if (effective > 0) total += uint256(effective);
        }
    }

    function test_invariant_voteTotalsMatchesEffectiveWeights() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 2000, address(0));
        _lockAndDelegate(carol, 500, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _vote(bob, _getGauges(address(gauge2)), _getWeights(10000));
        _vote(carol, _getGauges(address(gauge3)), _getWeights(10000));

        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }

    function test_invariant_delegationChainTotals() public {
        _lockAndDelegate(alice, 1000, carol);
        _lockAndDelegate(bob, 500, carol);
        _lockAndDelegate(carol, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _vote(bob, _getGauges(address(gauge2)), _getWeights(10000));
        _vote(carol, _getGauges(address(gauge3)), _getWeights(10000));

        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }

    function test_invariant_revotePreservesTotals() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 500, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _vote(bob, _getGauges(address(gauge2)), _getWeights(10000));
        uint256 totalsBefore = platform.voteTotals(pid);
        assertEq(totalsBefore, _sumAllEffectiveWeights(pid));

        _vote(alice, _getGauges(address(gauge3)), _getWeights(10000));

        uint256 totalsAfter = platform.voteTotals(pid);
        assertEq(totalsAfter, _sumAllEffectiveWeights(pid));
        assertEq(totalsBefore, totalsAfter);
    }

    function test_invariant_delegateeVotesAfterDelegate() public {
        _lockAndDelegate(carol, 2000, address(0));
        _lockAndDelegate(alice, 1000, carol);
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(carol, _getGauges(address(gauge1)), _getWeights(10000));
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }

    function test_invariant_pureDelegate() public {
        _lockAndDelegate(alice, 1000, dave);
        _lockAndDelegate(bob, 500, dave);
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(dave, _getGauges(address(gauge1)), _getWeights(10000));
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));
        _vote(bob, _getGauges(address(gauge3)), _getWeights(10000));

        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }

    function test_invariant_gaugeTotalsEqualVoteTotals() public {
        _lockAndDelegate(alice, 1000, address(0));
        _lockAndDelegate(bob, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));
        _vote(bob, _getGauges(address(gauge2)), _getWeights(10000));

        uint256 gaugeSum;
        uint256 count = platform.getGaugeCount(pid);
        for (uint256 i = 0; i < count; i++) {
            (, uint256 weight) = platform.getGaugeEntry(pid, i);
            gaugeSum += weight;
        }

        uint256 tolerance = count * WD;
        assertApproxEqAbs(gaugeSum, platform.voteTotals(pid), tolerance);
    }

    // ========== Timestamp Branching: delegate voted BEFORE sync ==========

    function test_timestampDelegateVotedBeforeSync() public {
        _lockAndDelegate(alice, 1000, bob);
        _lockAndDelegate(bob, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        // Bob votes first with alice's weight included
        _vote(bob, _getGauges(address(gauge1)), _getWeights(10000));

        uint256 g1TotalAfterBob = platform.gaugeTotal(pid, address(gauge1));
        uint256 expectedBobTotal = mockVlCVX.balanceAtEpochOf(proposalEpoch, bob)
            + mockVlCVX.balanceAtEpochOf(proposalEpoch, alice);
        assertApproxEqAbs(g1TotalAfterBob, expectedBobTotal, WD);

        // Alice syncs mid-proposal
        delegation.sync(alice);

        // Alice votes — should trigger timestamp comparison
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        // Bob's adjustedWeight should be 0 after Alice claims
        (,,,, int256 bobAdj) = platform.getVote(pid, bob);
        assertEq(bobAdj, 0);

        // Gauge1 should now reflect only Bob's own weight
        uint256 g1TotalAfterAlice = platform.gaugeTotal(pid, address(gauge1));
        uint256 expectedBobOwn = mockVlCVX.balanceAtEpochOf(proposalEpoch, bob);
        assertApproxEqAbs(g1TotalAfterAlice, expectedBobOwn, WD);

        // Totals should be correct
        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }

    // ========== Timestamp Branching: delegate voted AFTER sync ==========

    function test_timestampDelegateVotedAfterSync() public {
        _lockAndDelegate(alice, 1000, bob);
        _lockAndDelegate(bob, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        // Alice syncs first
        delegation.sync(alice);

        // Bob votes after sync
        _vote(bob, _getGauges(address(gauge1)), _getWeights(10000));

        // Alice votes — delegate voted AFTER sync, so weightToRemove = currentDelWeight
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        // Bob's adjustedWeight should be 0 after Alice claims
        (,,,, int256 bobAdj) = platform.getVote(pid, bob);
        assertEq(bobAdj, 0);

        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }

    // ========== Pending Weight Accumulation and Processing ==========

    function test_pendingAccumulationFromMultipleDelegatees() public {
        _lockAndDelegate(alice, 1000, dave);
        _lockAndDelegate(bob, 500, dave);
        _lockAndDelegate(carol, 300, dave);
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        // Dave votes first with all delegatees' weight
        _vote(dave, _getGauges(address(gauge1)), _getWeights(10000));

        // All delegatees vote — each should push pending to Dave
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));
        _vote(bob, _getGauges(address(gauge3)), _getWeights(10000));
        _vote(carol, _getGauges(address(gauge1)), _getWeights(10000));

        // Dave's adjustedWeight should be 0 after all delegatees claimed
        (,,,, int256 daveAdj) = platform.getVote(pid, dave);
        assertEq(daveAdj, 0);

        // Totals should be correct
        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }

    function test_delegateRevoteProcessesPending() public {
        _lockAndDelegate(alice, 1000, dave);
        _lockAndDelegate(dave, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        // Dave votes
        _vote(dave, _getGauges(address(gauge1)), _getWeights(10000));

        // Alice votes, pushing pending to Dave
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        (,,,, int256 daveAdjBefore) = platform.getVote(pid, dave);

        // Dave re-votes — should process pending
        _vote(dave, _getGauges(address(gauge3)), _getWeights(10000));

        (,,,, int256 daveAdjAfter) = platform.getVote(pid, dave);
        // After processing pending, Dave's adjustedWeight should be 0 (no more delegatees)
        assertEq(daveAdjAfter, 0);

        // Totals preserved
        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }

    // ========== userBaseDiff: Relock Mid-Proposal ==========

    function test_userBaseDiff_relockMidProposal() public {
        _lockAndDelegate(alice, 1000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        uint256 aliceBalBefore = mockVlCVX.balanceAtEpochOf(proposalEpoch, alice);

        // Alice votes
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        uint256 g1TotalBefore = platform.gaugeTotal(pid, address(gauge1));
        assertGt(g1TotalBefore, 0);

        // Alice relocks mid-proposal (replaces boosted with higher value)
        mockVlCVX.mockRelock(alice, 0, 1500 * WD);

        uint256 aliceBalAfter = mockVlCVX.balanceAtEpochOf(proposalEpoch, alice);
        assertGt(aliceBalAfter, aliceBalBefore);

        // Alice re-votes
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        uint256 g1TotalAfter = platform.gaugeTotal(pid, address(gauge1));
        assertGt(g1TotalAfter, g1TotalBefore);

        // Verify totals match
        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }

    function test_userBaseDiff_relockWithDelegate() public {
        _lockAndDelegate(alice, 1000, bob);
        _lockAndDelegate(bob, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        // Bob votes first
        _vote(bob, _getGauges(address(gauge1)), _getWeights(10000));

        // Alice votes
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        uint256 aliceBalBefore = mockVlCVX.balanceAtEpochOf(proposalEpoch, alice);

        // Alice relocks mid-proposal (replaces boosted with higher value)
        mockVlCVX.mockRelock(alice, 0, 1500 * WD);

        uint256 aliceBalAfter = mockVlCVX.balanceAtEpochOf(proposalEpoch, alice);
        assertGt(aliceBalAfter, aliceBalBefore);

        // Alice re-votes — this triggers userBaseDiff > 0 with delegate
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        // Bob's pending should have been reduced by Alice's growth
        int256 bobPending = platform.pendingWeightAdjustment(pid, bob);
        assertLt(bobPending, 0);

        // Bob re-votes to pick up pending
        _vote(bob, _getGauges(address(gauge1)), _getWeights(10000));

        // Totals should be correct
        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }

    // ========== userBaseDiff: relock with delegate who hasn't voted yet ==========

    function test_userBaseDiff_relockDelegateNotVoted() public {
        _lockAndDelegate(alice, 1000, bob);
        _lockAndDelegate(bob, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        // Alice votes first — initBaseInfo subtracts bob's adjustedWeight by alice's delegation weight
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        uint256 aliceBalBefore = mockVlCVX.balanceAtEpochOf(proposalEpoch, alice);

        // Alice relocks mid-proposal
        mockVlCVX.mockRelock(alice, 0, 1500 * WD);

        uint256 aliceBalAfter = mockVlCVX.balanceAtEpochOf(proposalEpoch, alice);
        assertGt(aliceBalAfter, aliceBalBefore);

        // Alice re-votes — triggers userBaseDiff > 0
        // Bob hasn't voted (voteStatus == 0), so growth goes directly to bob.adjustedWeight
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));

        // Bob's pending should be 0 (direct subtraction, not pending)
        int256 bobPending = platform.pendingWeightAdjustment(pid, bob);
        assertEq(bobPending, 0);

        // Bob votes — his adjustedWeight already reflects alice's growth subtraction
        _vote(bob, _getGauges(address(gauge1)), _getWeights(10000));

        // Totals should be correct
        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }

    // ========== No double-counting: total weight never exceeds sum of all vlCVX ==========

    function test_noDoubleCounting_complexChain() public {
        _lockAndDelegate(alice, 1000, carol);
        _lockAndDelegate(bob, 500, carol);
        _lockAndDelegate(carol, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        uint256 expectedTotal = mockVlCVX.balanceAtEpochOf(proposalEpoch, alice)
            + mockVlCVX.balanceAtEpochOf(proposalEpoch, bob)
            + mockVlCVX.balanceAtEpochOf(proposalEpoch, carol);

        _vote(carol, _getGauges(address(gauge1)), _getWeights(10000));
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));
        _vote(bob, _getGauges(address(gauge3)), _getWeights(10000));

        uint256 actualTotal = platform.voteTotals(pid);
        uint256 tolerance = 3 * WD;
        assertApproxEqAbs(actualTotal, expectedTotal, tolerance);
        assertLe(actualTotal, expectedTotal + tolerance);
    }

    function test_noDoubleCounting_pureDelegateMultiple() public {
        _lockAndDelegate(alice, 1000, dave);
        _lockAndDelegate(bob, 500, dave);
        _lockAndDelegate(carol, 300, dave);
        _lockAndDelegate(dave, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        uint256 expectedTotal = mockVlCVX.balanceAtEpochOf(proposalEpoch, alice)
            + mockVlCVX.balanceAtEpochOf(proposalEpoch, bob)
            + mockVlCVX.balanceAtEpochOf(proposalEpoch, carol)
            + mockVlCVX.balanceAtEpochOf(proposalEpoch, dave);

        _vote(dave, _getGauges(address(gauge1)), _getWeights(10000));
        _vote(alice, _getGauges(address(gauge2)), _getWeights(10000));
        _vote(bob, _getGauges(address(gauge3)), _getWeights(10000));
        _vote(carol, _getGauges(address(gauge1)), _getWeights(10000));

        uint256 actualTotal = platform.voteTotals(pid);
        uint256 tolerance = 4 * WD;
        assertApproxEqAbs(actualTotal, expectedTotal, tolerance);
        assertLe(actualTotal, expectedTotal + tolerance);
    }

    // ========== Delegation change takes effect next epoch, not current ==========

    function test_delegateChangeMidProposalDoesNotAffectCurrent() public {
        _lockAndDelegate(alice, 1000, bob);
        _lockAndDelegate(bob, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        // Alice votes with Bob as delegate
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        // Alice changes delegate mid-proposal (takes effect next epoch)
        vm.prank(alice);
        delegation.setDelegate(carol);

        // Alice re-votes — should still use Bob as delegate for this proposal's epoch
        _vote(alice, _getGauges(address(gauge1)), _getWeights(10000));

        (,,,, address aliceDel, ) = platform.userInfo(pid, alice);
        assertEq(aliceDel, bob); // Still Bob, not Carol
    }

    // ========== Re-vote after delegation balance change ==========

    function test_revoteAfterNewDelegateeJoins() public {
        _lockAndDelegate(alice, 1000, dave);
        _lockAndDelegate(dave, 2000, address(0));
        _warpToNextEpoch();
        uint256 pid = _createProposal();

        _vote(dave, _getGauges(address(gauge1)), _getWeights(10000));

        // Bob locks (but does NOT delegate yet)
        mockVlCVX.mockLock(bob, 500 * WD, 500 * WD);

        // Dave re-votes — delDelta should still reflect Alice's delegation
        _vote(dave, _getGauges(address(gauge1)), _getWeights(10000));

        assertEq(platform.voteTotals(pid), _sumAllEffectiveWeights(pid));
    }
}