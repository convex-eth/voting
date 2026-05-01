// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/DaoVotePlatform.sol";
import "../src/Delegation.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/SurrogateRegistry.sol";
import "./mocks/MockGauges.sol";
import "./mocks/MockVlCVX.sol";

contract VotingActor {
    function setSurrogate(SurrogateRegistry registry, address surrogate) external {
        registry.setSurrogate(surrogate);
    }

    function setDelegate(Delegation delegation, address delegate) external {
        delegation.setDelegate(delegate);
    }

    function daoVote(DaoVotePlatform dao, address account, uint256 yesWeight, uint256 noWeight) external {
        dao.vote(account, yesWeight, noWeight);
    }

    function gaugeVote(GaugeVotePlatform platform, address account, address[] memory gauges, uint256[] memory weights)
        external
    {
        platform.vote(account, gauges, weights);
    }
}

contract LazyDelegationHandler is Test {
    uint256 internal constant ACTOR_COUNT = 5;
    uint256 internal constant DELEGATOR_COUNT = 3;
    uint256 internal constant GAUGE_COUNT = 3;
    uint256 internal constant MAX_PROPOSALS = 8;
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant WD = 1e17;
    address internal constant CURVE_GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;

    MockVlCVX public mockVlCVX;
    Delegation public delegation;
    SurrogateRegistry public surrogateRegistry;
    CurveGaugeRegistry public gaugeRegistry;
    DaoVotePlatform public dao;
    GaugeVotePlatform public gaugePlatform;

    address[ACTOR_COUNT] public actors;
    address[ACTOR_COUNT] public surrogates;
    VotingActor[ACTOR_COUNT] internal actorProxies;
    VotingActor[ACTOR_COUNT] internal surrogateProxies;
    address[GAUGE_COUNT] public gauges;
    uint256[ACTOR_COUNT] internal boostedWeights;
    mapping(uint256 => uint256) public daoSupplyCap;
    mapping(uint256 => uint256) public gaugeSupplyCap;

    address public operator = address(0xAA01);
    uint256 public currentDaoPid;
    uint256 public currentGaugePid;
    uint256 public proposalNonce;

    bool public futureDelegationBroken;
    bool public daoPendingClearBroken;
    bool public gaugePendingClearBroken;
    bool public daoSurrogateOverrideBroken;
    bool public gaugeSurrogateOverrideBroken;

    constructor() {
        vm.warp(WEEK * 2);

        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));
        surrogateRegistry = new SurrogateRegistry();

        address gaugeController = address(new MockGaugeController());
        vm.etch(CURVE_GAUGE_CONTROLLER, gaugeController.code);

        gaugeRegistry = new CurveGaugeRegistry();
        dao = new DaoVotePlatform(address(this), address(mockVlCVX), address(surrogateRegistry), address(delegation));
        gaugePlatform = new GaugeVotePlatform(
            address(this), address(mockVlCVX), address(gaugeRegistry), address(surrogateRegistry), address(delegation)
        );
        dao.setOperator(operator, true);
        gaugePlatform.setOperator(operator, true);

        _seedGauges();
        _seedLocksAndDelegates();
        _createProposals();
    }

    function setDelegate(uint256 userSeed, uint256 delegateSeed) external {
        uint256 index = bound(userSeed, 0, DELEGATOR_COUNT - 1);
        address user = actors[index];
        address delegate = _delegateTarget(delegateSeed);

        mockVlCVX.checkpointEpoch();
        uint256 currentEpoch = mockVlCVX.epochCount() - 2;
        address beforeDelegate = delegation.getDelegateAtEpoch(user, currentEpoch);

        actorProxies[index].setDelegate(delegation, delegate);

        if (delegation.getDelegateAtEpoch(user, currentEpoch) != beforeDelegate) {
            futureDelegationBroken = true;
        }
        _tick();
    }

    function sync(uint256 userSeed) external {
        delegation.sync(actors[_actorIndex(userSeed)]);
        _tick();
    }

    function relock(uint256 userSeed, uint256 amountSeed) external {
        uint256 index = _actorIndex(userSeed);
        uint256 delta = bound(amountSeed, 1, 500) * WD;
        boostedWeights[index] += delta;
        mockVlCVX.mockRelock(actors[index], 0, boostedWeights[index]);
        _refreshSupplyCaps();
        _tick();
    }

    function daoVote(uint256 userSeed, uint256 yesSeed) external {
        uint256 index = _actorIndex(userSeed);
        address user = actors[index];
        uint256 yesWeight = bound(yesSeed, 0, dao.max_weight());

        actorProxies[index].daoVote(dao, user, yesWeight, dao.max_weight() - yesWeight);

        _checkDaoPendingCleared(user);
        _tick();
    }

    function daoSurrogateVote(uint256 userSeed, uint256 yesSeed) external {
        uint256 index = _actorIndex(userSeed);
        address user = actors[index];
        bool directBefore = _daoVoteStatus(user) == uint8(DaoVotePlatform.VoteStatus.Voted);
        uint256 yesWeight = bound(yesSeed, 0, dao.max_weight());

        try surrogateProxies[index].daoVote(dao, user, yesWeight, dao.max_weight() - yesWeight) {
            if (directBefore) daoSurrogateOverrideBroken = true;
            _checkDaoPendingCleared(user);
        } catch {}
        _tick();
    }

    function gaugeVote(uint256 userSeed, uint256 patternSeed) external {
        uint256 index = _actorIndex(userSeed);
        address user = actors[index];
        (address[] memory voteGauges, uint256[] memory weights) = _gaugeVoteParams(patternSeed);

        actorProxies[index].gaugeVote(gaugePlatform, user, voteGauges, weights);

        _checkGaugePendingCleared(user);
        _tick();
    }

    function gaugeSurrogateVote(uint256 userSeed, uint256 patternSeed) external {
        uint256 index = _actorIndex(userSeed);
        address user = actors[index];
        bool directBefore = _gaugeVoteStatus(user) == uint8(GaugeVotePlatform.VoteStatus.Voted);
        (address[] memory voteGauges, uint256[] memory weights) = _gaugeVoteParams(patternSeed);

        try surrogateProxies[index].gaugeVote(gaugePlatform, user, voteGauges, weights) {
            if (directBefore) gaugeSurrogateOverrideBroken = true;
            _checkGaugePendingCleared(user);
        } catch {}
        _tick();
    }

    function advanceProposal(uint256 warpSeed) external {
        if (dao.proposalCount() >= MAX_PROPOSALS) return;

        (, uint256 daoEnd,,,) = dao.proposals(currentDaoPid);
        (, uint256 gaugeEnd,) = gaugePlatform.proposals(currentGaugePid);

        uint256 nextTime = daoEnd + dao.finalizationTime() + 1;
        uint256 gaugeReady = gaugeEnd + gaugePlatform.overtime() + 1;
        if (gaugeReady > nextTime) nextTime = gaugeReady;

        vm.warp(nextTime + bound(warpSeed, 0, 2 days));
        _createProposals();
        _tick();
    }

    function daoVoteTotalsMatchEffectiveWeights() external view returns (bool) {
        uint256 count = dao.proposalCount();
        for (uint256 pid = 0; pid < count;) {
            if (dao.voteTotals(pid) != _sumDaoEffectiveWeights(pid)) return false;
            if (dao.getYes(pid) + dao.getNo(pid) != dao.voteTotals(pid)) return false;
            unchecked {
                ++pid;
            }
        }
        return true;
    }

    function gaugeVoteTotalsMatchEffectiveWeights() external view returns (bool) {
        uint256 count = gaugePlatform.proposalCount();
        for (uint256 pid = 0; pid < count;) {
            if (gaugePlatform.voteTotals(pid) != _sumGaugeEffectiveWeights(pid)) return false;
            unchecked {
                ++pid;
            }
        }
        return true;
    }

    function gaugeEntriesReconcileToVoteTotals() external view returns (bool) {
        uint256 count = gaugePlatform.proposalCount();
        for (uint256 pid = 0; pid < count;) {
            uint256 gaugeSum;
            uint256 gaugeCount = gaugePlatform.getGaugeCount(pid);
            for (uint256 i = 0; i < gaugeCount;) {
                (address gauge, uint256 totalWeight) = gaugePlatform.getGaugeEntry(pid, i);
                if (gaugePlatform.gaugeTotal(pid, gauge) != totalWeight) return false;
                gaugeSum += totalWeight;
                unchecked {
                    ++i;
                }
            }

            uint256 tolerance = gaugeCount * WD;
            if (_absDiff(gaugeSum, gaugePlatform.voteTotals(pid)) > tolerance) return false;
            unchecked {
                ++pid;
            }
        }
        return true;
    }

    function voteTotalsNeverExceedKnownSupply() external view returns (bool) {
        uint256 daoCount = dao.proposalCount();
        for (uint256 pid = 0; pid < daoCount;) {
            (,, uint256 epoch,,) = dao.proposals(pid);
            uint256 supplyCap = _max(daoSupplyCap[pid], _knownSupplyAtEpoch(epoch));
            if (dao.voteTotals(pid) > supplyCap + ACTOR_COUNT * WD) return false;
            unchecked {
                ++pid;
            }
        }

        uint256 gaugeCount = gaugePlatform.proposalCount();
        for (uint256 pid = 0; pid < gaugeCount;) {
            (,, uint256 epoch) = gaugePlatform.proposals(pid);
            uint256 supplyCap = _max(gaugeSupplyCap[pid], _knownSupplyAtEpoch(epoch));
            if (gaugePlatform.voteTotals(pid) > supplyCap + ACTOR_COUNT * WD) return false;
            unchecked {
                ++pid;
            }
        }

        return true;
    }

    function _seedGauges() internal {
        for (uint256 i = 0; i < GAUGE_COUNT;) {
            MockCurveGauge gauge = new MockCurveGauge();
            gauges[i] = address(gauge);
            MockGaugeController(CURVE_GAUGE_CONTROLLER).setGaugeWeight(address(gauge), (i + 1) * 1000);
            gaugeRegistry.setGauge(address(gauge));
            unchecked {
                ++i;
            }
        }
    }

    function _seedLocksAndDelegates() internal {
        uint256[ACTOR_COUNT] memory initialWeights =
            [uint256(1000 * WD), uint256(800 * WD), uint256(600 * WD), uint256(400 * WD), uint256(200 * WD)];

        for (uint256 i = 0; i < ACTOR_COUNT;) {
            actorProxies[i] = new VotingActor();
            surrogateProxies[i] = new VotingActor();
            actors[i] = address(actorProxies[i]);
            surrogates[i] = address(surrogateProxies[i]);

            boostedWeights[i] = initialWeights[i];
            mockVlCVX.mockLock(actors[i], initialWeights[i], initialWeights[i]);

            actorProxies[i].setSurrogate(surrogateRegistry, surrogates[i]);

            unchecked {
                ++i;
            }
        }

        actorProxies[0].setDelegate(delegation, actors[3]);
        actorProxies[1].setDelegate(delegation, actors[3]);
        actorProxies[2].setDelegate(delegation, actors[4]);

        uint256 currentEpoch = (block.timestamp / WEEK) * WEEK;
        vm.warp(currentEpoch + WEEK + 1);
    }

    function _createProposals() internal {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 4 days;

        dao.createProposal(startTime, endTime, DaoVotePlatform.VoteType.Parameter, ++proposalNonce);
        currentDaoPid = dao.proposalCount() - 1;
        (,, uint256 daoEpoch,,) = dao.proposals(currentDaoPid);
        daoSupplyCap[currentDaoPid] = _knownSupplyAtEpoch(daoEpoch);

        gaugePlatform.createProposal(startTime, endTime);
        currentGaugePid = gaugePlatform.proposalCount() - 1;
        (,, uint256 gaugeEpoch) = gaugePlatform.proposals(currentGaugePid);
        gaugeSupplyCap[currentGaugePid] = _knownSupplyAtEpoch(gaugeEpoch);

        vm.warp(startTime);
    }

    function _refreshSupplyCaps() internal {
        uint256 daoCount = dao.proposalCount();
        for (uint256 pid = 0; pid < daoCount;) {
            (,, uint256 epoch,,) = dao.proposals(pid);
            uint256 supply = _knownSupplyAtEpoch(epoch);
            if (supply > daoSupplyCap[pid]) daoSupplyCap[pid] = supply;
            unchecked {
                ++pid;
            }
        }

        uint256 gaugeCount = gaugePlatform.proposalCount();
        for (uint256 pid = 0; pid < gaugeCount;) {
            (,, uint256 epoch) = gaugePlatform.proposals(pid);
            uint256 supply = _knownSupplyAtEpoch(epoch);
            if (supply > gaugeSupplyCap[pid]) gaugeSupplyCap[pid] = supply;
            unchecked {
                ++pid;
            }
        }
    }

    function _checkDaoPendingCleared(address user) internal {
        if (dao.pendingWeightAdjustment(currentDaoPid, user) != 0) {
            daoPendingClearBroken = true;
        }
    }

    function _checkGaugePendingCleared(address user) internal {
        if (gaugePlatform.pendingWeightAdjustment(currentGaugePid, user) != 0) {
            gaugePendingClearBroken = true;
        }
    }

    function _tick() internal {
        vm.warp(block.timestamp + 1);
    }

    function _sumDaoEffectiveWeights(uint256 pid) internal view returns (uint256 total) {
        uint256 voterCount = dao.getVoterCount(pid);
        for (uint256 i = 0; i < voterCount;) {
            address voter = dao.getVoterAtIndex(pid, i);
            (,,, uint256 baseWeight, int256 adjustedWeight) = dao.getVote(pid, voter);
            int256 effectiveWeight = int256(baseWeight) + adjustedWeight;
            if (effectiveWeight > 0) total += uint256(effectiveWeight);
            unchecked {
                ++i;
            }
        }
    }

    function _sumGaugeEffectiveWeights(uint256 pid) internal view returns (uint256 total) {
        uint256 voterCount = gaugePlatform.getVoterCount(pid);
        for (uint256 i = 0; i < voterCount;) {
            address voter = gaugePlatform.getVoterAtIndex(pid, i);
            (uint256 baseWeight, int256 adjustedWeight,,,,) = gaugePlatform.userInfo(pid, voter);
            int256 effectiveWeight = int256(baseWeight) + adjustedWeight;
            if (effectiveWeight > 0) total += uint256(effectiveWeight);
            unchecked {
                ++i;
            }
        }
    }

    function _knownSupplyAtEpoch(uint256 epoch) internal view returns (uint256 total) {
        for (uint256 i = 0; i < ACTOR_COUNT;) {
            total += mockVlCVX.balanceAtEpochOf(epoch, actors[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _daoVoted(address user) internal view returns (bool voted) {
        (voted,,,,) = dao.getVote(currentDaoPid, user);
    }

    function _gaugeVoted(address user) internal view returns (bool voted) {
        (,, voted,,) = gaugePlatform.getVote(currentGaugePid, user);
    }

    function _daoVoteStatus(address user) internal view returns (uint8 status) {
        (,,,,, status,,) = dao.userInfo(currentDaoPid, user);
    }

    function _gaugeVoteStatus(address user) internal view returns (uint8 status) {
        (,,, status,,) = gaugePlatform.userInfo(currentGaugePid, user);
    }

    function _gaugeVoteParams(uint256 patternSeed)
        internal
        view
        returns (address[] memory voteGauges, uint256[] memory weights)
    {
        uint256 pattern = patternSeed % 5;
        if (pattern < 3) {
            voteGauges = new address[](1);
            weights = new uint256[](1);
            voteGauges[0] = gauges[pattern];
            weights[0] = gaugePlatform.max_weight();
        } else if (pattern == 3) {
            voteGauges = new address[](2);
            weights = new uint256[](2);
            voteGauges[0] = gauges[0];
            voteGauges[1] = gauges[1];
            weights[0] = 7000;
            weights[1] = 3000;
        } else {
            voteGauges = new address[](3);
            weights = new uint256[](3);
            voteGauges[0] = gauges[0];
            voteGauges[1] = gauges[1];
            voteGauges[2] = gauges[2];
            weights[0] = 5000;
            weights[1] = 3000;
            weights[2] = 2000;
        }
    }

    function _delegateTarget(uint256 seed) internal view returns (address) {
        uint256 choice = seed % 3;
        if (choice == 0) return address(0);
        if (choice == 1) return actors[3];
        return actors[4];
    }

    function _actorIndex(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 0, ACTOR_COUNT - 1);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}

contract LazyDelegationInvariantTest is Test {
    LazyDelegationHandler internal handler;

    function setUp() public {
        handler = new LazyDelegationHandler();

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = LazyDelegationHandler.setDelegate.selector;
        selectors[1] = LazyDelegationHandler.sync.selector;
        selectors[2] = LazyDelegationHandler.relock.selector;
        selectors[3] = LazyDelegationHandler.daoVote.selector;
        selectors[4] = LazyDelegationHandler.daoSurrogateVote.selector;
        selectors[5] = LazyDelegationHandler.gaugeVote.selector;
        selectors[6] = LazyDelegationHandler.gaugeSurrogateVote.selector;
        selectors[7] = LazyDelegationHandler.advanceProposal.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_daoVoteTotalsMatchEffectiveWeights() public view {
        assertTrue(handler.daoVoteTotalsMatchEffectiveWeights());
    }

    function invariant_gaugeVoteTotalsMatchEffectiveWeights() public view {
        assertTrue(handler.gaugeVoteTotalsMatchEffectiveWeights());
    }

    function invariant_gaugeEntriesReconcileToVoteTotals() public view {
        assertTrue(handler.gaugeEntriesReconcileToVoteTotals());
    }

    function invariant_voteTotalsNeverExceedKnownSupply() public view {
        assertTrue(handler.voteTotalsNeverExceedKnownSupply());
    }

    function invariant_pendingAdjustmentsClearForSuccessfulVoters() public view {
        assertFalse(handler.daoPendingClearBroken());
        assertFalse(handler.gaugePendingClearBroken());
    }

    function invariant_delegationChangesAreFutureEpochOnly() public view {
        assertFalse(handler.futureDelegationBroken());
    }

    function invariant_surrogatesCannotOverrideDirectVotes() public view {
        assertFalse(handler.daoSurrogateOverrideBroken());
        assertFalse(handler.gaugeSurrogateOverrideBroken());
    }
}
