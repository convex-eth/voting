// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/DaoVotePlatform.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/Delegation.sol";
import "../src/SurrogateRegistry.sol";
import "../src/interface/IvlCVX.sol";
import "./mocks/simpleVlCvx.sol";
import "./mocks/MockGauges.sol";

contract VotingActor {
    function setSurrogate(SurrogateRegistry registry, address surrogate) external {
        registry.setSurrogate(surrogate);
    }

    function setDelegate(Delegation delegation, address delegate) external {
        delegation.setDelegate(delegate);
    }

    function daoVote(DaoVotePlatform dao, address account, uint256 yesWeight, uint256 noWeight) external {
        dao.vote(dao.proposalCount() - 1, account, yesWeight, noWeight);
    }

    function gaugeVote(
        GaugeVotePlatform platform,
        address account,
        address[] calldata gauges,
        uint256[] calldata weights
    ) external {
        platform.vote(account, gauges, weights);
    }
}

// Exact reproduction of invariant_daoVoteTotalsMatchEffectiveWeights failure.
//
// The bug: cross-platform delegation sync creates a mismatch.
// When A votes on gauge, _initBaseInfo syncs A's packed weight in Delegation.
// When A later votes DAO, _initBaseInfo sees the new (higher) packed weight
// and removes MORE from D's DAO adjustedWeight than D was originally credited.
//
// Fuzz-found values for proposal 7:
//   D (delegate): 20e18 base, credited 160e18 delegation income
//   A (delegator): starts 60e18, relocked to 100 then 134.4 then 165.3 (all e18)
//   B (delegator): 60e18
contract DelegateNegativeWeightTest is Test {
    uint256 constant WD = 1e17;
    uint256 constant WEEK = 7 days;
    uint256 constant BPS_TO_PLATFORM_WEIGHT = 100;
    address constant CURVE_GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;

    IvlCVX vlcvx;
    Delegation delegation;
    SurrogateRegistry surrogateRegistry;
    CurveGaugeRegistry gaugeRegistry;
    DaoVotePlatform dao;
    GaugeVotePlatform gaugePlatform;

    VotingActor actorA;
    VotingActor actorB;
    VotingActor delegateD;
    VotingActor surrogateA;
    VotingActor surrogateB;
    VotingActor surrogateD;

    address[3] actorAddrs;
    string[3] actorNames;
    address delegateDAddr;
    address[] gauges;

    address operator = address(0xAA01);

    function setUp() public {
        vm.warp(1700000000);

        simpleVlCvx impl = new simpleVlCvx();
        vlcvx = IvlCVX(address(impl));
        delegation = new Delegation("Convex Delegation", address(this), address(vlcvx));
        surrogateRegistry = new SurrogateRegistry("Convex Surrogate Registry");

        address gaugeController = address(new MockGaugeController());
        vm.etch(CURVE_GAUGE_CONTROLLER, gaugeController.code);
        gaugeRegistry = new CurveGaugeRegistry("Curve Gauge Registry", address(this), new uint256[](0));

        dao = new DaoVotePlatform(
            "Convex Dao Voting", address(this), address(vlcvx), address(surrogateRegistry), address(delegation)
        );
        gaugePlatform = new GaugeVotePlatform(
            "Convex Gauge Voting",
            address(this),
            address(vlcvx),
            address(gaugeRegistry),
            address(surrogateRegistry),
            address(delegation)
        );
        dao.setOperator(operator, true);
        gaugePlatform.setOperator(operator, true);

        actorA = new VotingActor();
        actorB = new VotingActor();
        delegateD = new VotingActor();
        surrogateA = new VotingActor();
        surrogateB = new VotingActor();
        surrogateD = new VotingActor();

        actorAddrs[0] = address(actorA);
        actorAddrs[1] = address(actorB);
        actorAddrs[2] = address(delegateD);
        actorNames[0] = "A";
        actorNames[1] = "B";
        actorNames[2] = "D";
        delegateDAddr = address(delegateD);

        vlcvx.lock(actorAddrs[0], 600 * WD, 0);
        vlcvx.lock(actorAddrs[1], 600 * WD, 0);
        vlcvx.lock(actorAddrs[2], 200 * WD, 0);

        actorA.setSurrogate(surrogateRegistry, address(surrogateA));
        actorB.setSurrogate(surrogateRegistry, address(surrogateB));
        delegateD.setSurrogate(surrogateRegistry, address(surrogateD));

        actorA.setDelegate(delegation, delegateDAddr);
        actorB.setDelegate(delegation, delegateDAddr);

        MockCurveGauge gauge1 = new MockCurveGauge();
        MockCurveGauge gauge2 = new MockCurveGauge();
        MockCurveGauge gauge3 = new MockCurveGauge();
        gauges = new address[](3);
        gauges[0] = address(gauge1);
        gauges[1] = address(gauge2);
        gauges[2] = address(gauge3);
        MockGaugeController(CURVE_GAUGE_CONTROLLER).setGauge(0, gauges[0]);
        MockGaugeController(CURVE_GAUGE_CONTROLLER).setGauge(1, gauges[1]);
        MockGaugeController(CURVE_GAUGE_CONTROLLER).setGauge(2, gauges[2]);
        MockGaugeController(CURVE_GAUGE_CONTROLLER).setGaugeWeight(gauges[0], 1000);
        MockGaugeController(CURVE_GAUGE_CONTROLLER).setGaugeWeight(gauges[1], 2000);
        MockGaugeController(CURVE_GAUGE_CONTROLLER).setGaugeWeight(gauges[2], 3000);
        gaugeRegistry.setGauge(0);
        gaugeRegistry.setGauge(1);
        gaugeRegistry.setGauge(2);

        uint256 currentEpoch = (block.timestamp / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);
    }

    function _createProposal() internal returns (uint256 daoPid, uint256 gaugePid) {
        uint256 startTime = vm.getBlockTimestamp() + 1 days;
        uint256 endTime = startTime + 4 days;
        vm.prank(operator);
        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Parameter, 1);
        vm.prank(operator);
        gaugePlatform.createProposal(startTime, endTime);
        vm.warp(startTime);
        daoPid = dao.proposalCount() - 1;
        gaugePid = gaugePlatform.proposalCount() - 1;
    }

    function _dumpState(string memory label, uint256 daoPid) internal {
        (,, uint48 epoch,,) = dao.proposals(daoPid);
        uint256 epochCount = vlcvx.epochCount();

        emit log_string("");
        emit log_string("========================================================");
        emit log_named_string("STATE", label);
        emit log_named_uint("  block.timestamp", vm.getBlockTimestamp());
        emit log_named_uint("  epochCount", epochCount);
        emit log_named_uint("  proposal epoch", epoch);

        emit log_string("");
        emit log_string("--- vlCVX Balances ---");
        for (uint256 i = 0; i < 3; i++) {
            emit log_named_string("  User", actorNames[i]);
            for (uint256 e = 0; e < epochCount; e++) {
                uint256 bal = vlcvx.balanceAtEpochOf(e, actorAddrs[i]);
                if (bal > 0) {
                    emit log_named_uint("    epoch", e);
                    emit log_named_uint("      balance", bal);
                }
            }
        }

        emit log_string("");
        emit log_string("--- Delegation ---");
        for (uint256 i = 0; i < 3; i++) {
            address user = actorAddrs[i];
            emit log_named_string("  User", actorNames[i]);
            emit log_named_address("    addr", user);
            emit log_named_uint("    syncedUserEpoch", delegation.syncedUserEpoch(user));

            uint256 histLen;
            while (true) {
                try delegation.delegateHistory(user, histLen) returns (address, uint32) {
                    histLen++;
                } catch {
                    break;
                }
            }
            emit log_named_uint("    delegateHistory len", histLen);
            for (uint256 h = 0; h < histLen; h++) {
                (address del, uint32 startEpoch) = delegation.delegateHistory(user, h);
                emit log_named_uint("      record", h);
                emit log_named_address("        delegate", del);
                emit log_named_uint("        startingEpoch", startEpoch);
            }

            for (uint256 e = 0; e < epochCount; e++) {
                uint256 userW = delegation.userWeightAtEpochOf(e, user);
                uint256 delBal = delegation.balanceAtEpochOf(e, user);
                address delAt = delegation.getDelegateAtEpoch(user, e);
                (uint256 snapPre, uint256 snapNonce) = delegation.getSyncSnapshot(user, e);
                if (userW > 0 || delBal > 0 || snapNonce > 0 || delAt != address(0)) {
                    emit log_named_uint("    epoch", e);
                    emit log_named_uint("      userWeight (packed*WD)", userW);
                    emit log_named_uint("      balanceAtEpochOf (del total)", delBal);
                    emit log_named_address("      delegate", delAt);
                    if (snapNonce > 0) {
                        emit log_named_uint("      snapshot.preSyncWeight", snapPre);
                        emit log_named_uint("      snapshot.syncNonce", snapNonce);
                    } else {
                        emit log_string("      snapshot: none");
                    }
                }
            }
        }

        emit log_string("");
        emit log_string("--- DaoVotePlatform ---");
        emit log_named_uint("  proposalCount", dao.proposalCount());
        emit log_named_uint("  voteTotals(pid)", dao.voteTotals(daoPid));
        emit log_named_uint("  yes(pid)", dao.getYes(daoPid));
        emit log_named_uint("  no(pid)", dao.getNo(daoPid));
        emit log_named_uint("  voterCount(pid)", dao.getVoterCount(daoPid));

        for (uint256 v = 0; v < dao.getVoterCount(daoPid); v++) {
            address voter = dao.getVoterAtIndex(daoPid, v);
            (bool voted, uint256 yesW, uint256 noW, uint256 baseW, int256 adjW) = dao.getVote(daoPid, voter);
            string memory name = _nameOf(voter);
            emit log_named_string("    voter", name);
            emit log_named_uint("      yesWeight", yesW);
            emit log_named_uint("      noWeight", noW);
            emit log_named_uint("      baseWeight", baseW);
            emit log_named_int("      adjustedWeight", adjW);
            emit log_named_int("      EFFECTIVE", int256(baseW) + adjW);
            if (voted) emit log_string("      voted: true");
            else emit log_string("      voted: false");

            (
                uint96 uiBase,
                int96 uiAdj,
                uint48 uiLastVote,
                uint16 uiYes,
                uint16 uiNo,
                uint8 uiStatus,
                address uiDelegate,
                uint96 uiTotalDel
            ) = dao.userInfo(daoPid, voter);
            emit log_named_uint("      lastVoteSyncNonce", uiLastVote);
            emit log_named_uint("      voteStatus", uiStatus);
            emit log_named_address("      delegate", uiDelegate);
            emit log_named_uint("      totalDelegationWeight", uiTotalDel);
            emit log_named_int("      pendingWeightAdjustment", dao.pendingWeightAdjustment(daoPid, voter));
        }

        emit log_string("========================================================");
        emit log_string("");
    }

    function _nameOf(address a) internal view returns (string memory) {
        for (uint256 i = 0; i < 3; i++) {
            if (a == actorAddrs[i]) return actorNames[i];
        }
        return "unknown";
    }

    function _sumEffectiveWeights(uint256 pid) internal view returns (uint256 total) {
        uint256 voterCount = dao.getVoterCount(pid);
        for (uint256 i = 0; i < voterCount; i++) {
            address voter = dao.getVoterAtIndex(pid, i);
            (,,, uint256 baseWeight, int256 adjustedWeight) = dao.getVote(pid, voter);
            int256 effective = int256(baseWeight) + adjustedWeight;
            if (effective > 0) total += uint256(effective);
        }
    }

    function test_crossPlatformSyncMismatch() public {
        (uint256 daoPid, uint256 gaugePid) = _createProposal();
        _dumpState("After createProposal (A=60e18, B=60e18, D=20e18)", daoPid);

        // Step 1: D votes DAO first
        // Delegation income = A(60e18) + B(60e18) = 120e18
        delegateD.daoVote(dao, delegateDAddr, 4443, 5557);
        _dumpState("After D votes DAO (adj should be +120e18)", daoPid);

        // Step 2: A votes GAUGE (no relock, same epoch - just a normal vote)
        address[] memory g = new address[](3);
        uint256[] memory w = new uint256[](3);
        g[0] = gauges[0];
        g[1] = gauges[1];
        g[2] = gauges[2];
        w[0] = 5000 * BPS_TO_PLATFORM_WEIGHT;
        w[1] = 3000 * BPS_TO_PLATFORM_WEIGHT;
        w[2] = 2000 * BPS_TO_PLATFORM_WEIGHT;
        actorA.gaugeVote(gaugePlatform, actorAddrs[0], g, w);
        _dumpState("After A votes GAUGE", daoPid);

        // Step 3: B votes DAO
        actorB.daoVote(dao, actorAddrs[1], 2799, 7201);
        _dumpState("After B votes DAO", daoPid);

        // Step 4: A votes DAO
        actorA.daoVote(dao, actorAddrs[0], 3291, 6709);
        _dumpState("After A votes DAO", daoPid);

        uint256 voteTotal = dao.voteTotals(daoPid);
        uint256 sumEffective = _sumEffectiveWeights(daoPid);
        emit log_named_uint("voteTotals", voteTotal);
        emit log_named_uint("sumEffective", sumEffective);
        assertEq(voteTotal, sumEffective, "voteTotals != sum of positive effective weights");
    }
}
