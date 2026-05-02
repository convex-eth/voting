// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/CurveGaugeExecutor.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/Delegation.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/SurrogateRegistry.sol";
import "./mocks/MockVlCVX.sol";
import "./mocks/MockVoteDelegateExtension.sol";

interface ILiveGaugeController {
    function get_gauge_weight(address gauge) external view returns (uint256);
    function last_user_vote(address user, address gauge) external view returns (uint256);
    function vote_user_slopes(address user, address gauge) external view returns (uint256, uint256, uint256);
}

contract CurveGaugeExecutionForkTest is Test {
    uint256 internal constant FORK_BLOCK = 24_875_982;
    uint256 internal constant HISTORICAL_VOTE_TIME = 1_776_145_019;
    uint256 internal constant VOTE_LOCK = 10 days;
    uint256 internal constant WEEK = 86400 * 7;
    uint256 internal constant WD = 1e17;

    address internal constant CURVE_VOTER_PROXY = 0x989AEb4d175e16225E39E87d0D97A3360524AD80;
    address internal constant CURVE_GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;
    address internal constant LEGACY_CURVE_GAUGE = 0x7ca5b0a2910B33e9759DC7dDB0413949071D7575;
    address internal constant MODERN_CURVE_GAUGE = 0xdA0DD1798BE66E17d5aB1Dc476302b56689C2DB4;
    address internal constant ZERO_WEIGHT_CURVE_GAUGE = 0x18478F737d40ed7DEFe5a9d6F1560d84E283B74e;
    address internal constant KILLED_WEIGHTED_CURVE_GAUGE = 0x2db0E83599a91b508Ac268a6197b8B14F5e72840;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal operator = makeAddr("operator");

    ILiveGaugeController internal controller = ILiveGaugeController(CURVE_GAUGE_CONTROLLER);

    MockVlCVX internal mockVlCVX;
    Delegation internal delegation;
    CurveGaugeRegistry internal gaugeRegistry;
    SurrogateRegistry internal surrogateRegistry;
    GaugeVotePlatform internal platform;
    CurveGaugeExecutor internal executor;
    MockVoteDelegateExtension internal voteDelegate;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) vm.skip(true, "MAINNET_RPC_URL not set");

        vm.createSelectFork(rpcUrl, FORK_BLOCK);
    }

    function testFork_registryValidatesRealWeightedLegacyKilledAndZeroWeightGauges() public {
        CurveGaugeRegistry registry = new CurveGaugeRegistry();

        assertGt(LEGACY_CURVE_GAUGE.code.length, 0);
        assertGt(MODERN_CURVE_GAUGE.code.length, 0);
        assertGt(KILLED_WEIGHTED_CURVE_GAUGE.code.length, 0);

        assertGt(controller.get_gauge_weight(LEGACY_CURVE_GAUGE), 0);
        assertGt(controller.get_gauge_weight(MODERN_CURVE_GAUGE), 0);
        assertGt(controller.get_gauge_weight(KILLED_WEIGHTED_CURVE_GAUGE), 0);
        assertEq(controller.get_gauge_weight(ZERO_WEIGHT_CURVE_GAUGE), 0);

        (bool legacyHasKillSwitch,) = LEGACY_CURVE_GAUGE.staticcall(abi.encodeWithSignature("is_killed()"));
        assertFalse(legacyHasKillSwitch, "legacy gauge should not expose is_killed");
        assertFalse(ICurveGauge(MODERN_CURVE_GAUGE).is_killed(), "modern gauge killed");
        assertTrue(ICurveGauge(KILLED_WEIGHTED_CURVE_GAUGE).is_killed(), "weighted killed gauge not killed");

        assertTrue(registry.isValidGauge(LEGACY_CURVE_GAUGE));
        assertTrue(registry.isValidGauge(MODERN_CURVE_GAUGE));
        assertFalse(registry.isValidGauge(KILLED_WEIGHTED_CURVE_GAUGE));
        assertFalse(registry.isValidGauge(ZERO_WEIGHT_CURVE_GAUGE));

        registry.setGauge(LEGACY_CURVE_GAUGE);
        registry.setGauge(MODERN_CURVE_GAUGE);
        registry.setGauge(KILLED_WEIGHTED_CURVE_GAUGE);
        registry.setGauge(ZERO_WEIGHT_CURVE_GAUGE);

        assertTrue(registry.isRegisteredGauge(LEGACY_CURVE_GAUGE));
        assertTrue(registry.isRegisteredGauge(MODERN_CURVE_GAUGE));
        assertFalse(registry.isRegisteredGauge(KILLED_WEIGHTED_CURVE_GAUGE));
        assertFalse(registry.isRegisteredGauge(ZERO_WEIGHT_CURVE_GAUGE));
        assertEq(registry.gaugeLength(), 2);
    }

    function testFork_historicalCurveVoterGaugeStateMatchesDecodedExecution() public view {
        (address[] memory gauges, uint16[] memory weights) = _historicalGaugeVoteReference();

        uint256 totalWeight;
        uint256 nonZeroVotes;
        uint256 zeroClears;

        for (uint256 i = 0; i < gauges.length; ++i) {
            (, uint256 power,) = controller.vote_user_slopes(CURVE_VOTER_PROXY, gauges[i]);
            assertEq(power, weights[i], "historical vote power mismatch");
            assertEq(controller.last_user_vote(CURVE_VOTER_PROXY, gauges[i]), HISTORICAL_VOTE_TIME);

            totalWeight += weights[i];
            if (weights[i] == 0) {
                ++zeroClears;
            } else {
                ++nonZeroVotes;
            }
        }

        assertEq(totalWeight, 10_000);
        assertEq(nonZeroVotes, 46);
        assertEq(zeroClears, 11);
        assertGt(HISTORICAL_VOTE_TIME + VOTE_LOCK, block.timestamp, "controller vote lock not active");
    }

    function testFork_executeHistoricalGaugeVoteInPartialBatchesWithZeroClears() public {
        _deployLocalVotingSystem();

        (address[] memory allGauges, uint16[] memory allWeights) = _historicalGaugeVoteReference();
        (address[] memory positiveGauges, uint256[] memory positiveWeights) = _filterPositive(allGauges, allWeights);
        address[] memory zeroClearGauges = _filterZero(allGauges, allWeights);

        _registerGauges(positiveGauges);

        _lock(alice, 10_000);
        _warpToNextEpoch();
        uint256 pid = _createProposal();
        _vote(alice, positiveGauges, positiveWeights);
        _finalizeProposal(pid);

        address[] memory batch1 = _slice(positiveGauges, 0, 17);
        executor.executeGaugeVote(pid, batch1);
        assertEq(executor.submittedGaugeCount(pid), 17);
        assertEq(executor.submittedWeight(pid), _sum(positiveWeights, 0, 17));
        assertFalse(executor.isDone(pid));

        address[] memory batch2 = _concat(zeroClearGauges, _slice(positiveGauges, 17, 20));
        executor.executeGaugeVote(pid, batch2);
        assertEq(executor.submittedGaugeCount(pid), 37);
        assertEq(executor.submittedWeight(pid), _sum(positiveWeights, 0, 37));
        assertFalse(executor.isDone(pid));

        (address[] memory lastGauges, uint256[] memory lastWeights) = voteDelegate.getLastCall();
        assertEq(lastGauges.length, 31);
        for (uint256 i = 0; i < zeroClearGauges.length; ++i) {
            assertEq(lastGauges[i], zeroClearGauges[i]);
            assertEq(lastWeights[i], 0);
            assertTrue(executor.submittedGauge(pid, zeroClearGauges[i]));
        }

        address[] memory batch3 = _slice(positiveGauges, 37, positiveGauges.length - 37);
        executor.executeGaugeVote(pid, batch3);
        assertEq(executor.submittedGaugeCount(pid), 46);
        assertEq(executor.submittedWeight(pid), 10_000);
        assertTrue(executor.isDone(pid));

        vm.expectRevert(CurveGaugeExecutor.GaugeAlreadySubmitted.selector);
        executor.executeGaugeVote(pid, _single(positiveGauges[0]));
        assertEq(executor.submittedGaugeCount(pid), 46);
        assertEq(executor.submittedWeight(pid), 10_000);
    }

    function testFork_executorPadsRoundingDustToLastRealGauge() public {
        _deployLocalVotingSystem();

        (address[] memory historicalGauges,) = _historicalGaugeVoteReference();
        address[] memory gauges = _slice(historicalGauges, 0, 3);
        _registerGauges(gauges);

        _lock(alice, 1);
        _lock(bob, 1);
        _lock(carol, 1);
        _warpToNextEpoch();

        uint256 pid = _createProposal();
        _vote(alice, _single(gauges[0]), _singleWeight(10_000));
        _vote(bob, _single(gauges[1]), _singleWeight(10_000));
        _vote(carol, _single(gauges[2]), _singleWeight(10_000));
        _finalizeProposal(pid);

        executor.executeGaugeVote(pid, gauges);

        (address[] memory executedGauges, uint256[] memory executedWeights) = voteDelegate.getLastCall();
        assertEq(executedGauges.length, 3);
        assertEq(executedWeights[0], 3333);
        assertEq(executedWeights[1], 3333);
        assertEq(executedWeights[2], 3334);
        assertEq(executedWeights[0] + executedWeights[1] + executedWeights[2], 10_000);
        assertEq(executor.submittedWeight(pid), 10_000);
    }

    function testFork_revertsForStaleProposalAndExpiredEpochWithRealGauges() public {
        _deployLocalVotingSystem();

        (address[] memory historicalGauges,) = _historicalGaugeVoteReference();
        address[] memory gauges = _slice(historicalGauges, 0, 2);
        _registerGauges(gauges);

        _lock(alice, 1);
        _warpToNextEpoch();

        uint256 pid0 = _createProposal();
        _vote(alice, _single(gauges[0]), _singleWeight(10_000));
        _finalizeProposal(pid0);

        vm.warp(block.timestamp + 1 days);
        _lock(bob, 1);
        _warpToNextEpoch();

        uint256 pid1 = _createProposal();
        _vote(bob, _single(gauges[1]), _singleWeight(10_000));
        _finalizeProposal(pid1);

        vm.expectRevert(CurveGaugeExecutor.NotLatestProposal.selector);
        executor.executeGaugeVote(pid0, _single(gauges[0]));

        executor.executeGaugeVote(pid1, _single(gauges[1]));
        assertTrue(executor.isDone(pid1));

        _deployLocalVotingSystem();
        _registerGauges(gauges);
        _lock(carol, 1);
        _warpToNextEpoch();

        uint256 expiredPid = _createProposal();
        _vote(carol, _single(gauges[0]), _singleWeight(10_000));
        _finalizeProposal(expiredPid);
        _warpToNextEpoch();

        vm.expectRevert(CurveGaugeExecutor.EpochExpired.selector);
        executor.executeGaugeVote(expiredPid, _single(gauges[0]));
    }

    function _deployLocalVotingSystem() internal {
        // Use the forked controller state, but keep proposal timing deterministic and inside one mock epoch.
        vm.warp(WEEK * 2);

        mockVlCVX = new MockVlCVX();
        delegation = new Delegation(address(mockVlCVX));
        gaugeRegistry = new CurveGaugeRegistry();
        surrogateRegistry = new SurrogateRegistry();
        platform = new GaugeVotePlatform(
            address(this), address(mockVlCVX), address(gaugeRegistry), address(surrogateRegistry), address(delegation)
        );
        voteDelegate = new MockVoteDelegateExtension();
        executor = new CurveGaugeExecutor(address(platform), address(voteDelegate));
        platform.setOperator(operator, true);
    }

    function _registerGauges(address[] memory gauges) internal {
        for (uint256 i = 0; i < gauges.length; ++i) {
            assertTrue(gaugeRegistry.isValidGauge(gauges[i]), "historical gauge invalid");
            gaugeRegistry.setGauge(gauges[i]);
            assertTrue(gaugeRegistry.isRegisteredGauge(gauges[i]), "historical gauge not registered");
        }
    }

    function _lock(address user, uint256 amount) internal {
        mockVlCVX.mockLock(user, amount * WD, amount * WD);
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
        vm.warp(startTime);
        return pid;
    }

    function _finalizeProposal(uint256 pid) internal {
        (, uint256 endTime,) = platform.proposals(pid);
        vm.warp(endTime + platform.overtime() + 1);
    }

    function _vote(address user, address[] memory gauges, uint256[] memory weights) internal {
        vm.prank(user);
        platform.vote(user, gauges, weights);
    }

    function _filterPositive(address[] memory gauges, uint16[] memory weights)
        internal
        pure
        returns (address[] memory positiveGauges, uint256[] memory positiveWeights)
    {
        uint256 matches;
        for (uint256 i = 0; i < gauges.length; ++i) {
            if (weights[i] != 0) ++matches;
        }

        positiveGauges = new address[](matches);
        positiveWeights = new uint256[](matches);
        uint256 index;
        for (uint256 i = 0; i < gauges.length; ++i) {
            if (weights[i] == 0) continue;
            positiveGauges[index] = gauges[i];
            positiveWeights[index] = weights[i];
            ++index;
        }
    }

    function _filterZero(address[] memory gauges, uint16[] memory weights)
        internal
        pure
        returns (address[] memory zeroGauges)
    {
        uint256 matches;
        for (uint256 i = 0; i < gauges.length; ++i) {
            if (weights[i] == 0) ++matches;
        }

        zeroGauges = new address[](matches);
        uint256 index;
        for (uint256 i = 0; i < gauges.length; ++i) {
            if (weights[i] != 0) continue;
            zeroGauges[index] = gauges[i];
            ++index;
        }
    }

    function _slice(address[] memory values, uint256 start, uint256 len) internal pure returns (address[] memory out) {
        out = new address[](len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = values[start + i];
        }
    }

    function _concat(address[] memory a, address[] memory b) internal pure returns (address[] memory out) {
        out = new address[](a.length + b.length);
        for (uint256 i = 0; i < a.length; ++i) {
            out[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; ++i) {
            out[a.length + i] = b[i];
        }
    }

    function _sum(uint256[] memory values, uint256 start, uint256 len) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < len; ++i) {
            total += values[start + i];
        }
    }

    function _single(address gauge) internal pure returns (address[] memory gauges) {
        gauges = new address[](1);
        gauges[0] = gauge;
    }

    function _singleWeight(uint256 weight) internal pure returns (uint256[] memory weights) {
        weights = new uint256[](1);
        weights[0] = weight;
    }

    function _historicalGaugeVoteReference() internal pure returns (address[] memory gauges, uint16[] memory weights) {
        gauges = new address[](57);
        weights = new uint16[](57);

        gauges[0] = _addr(hex"f814283bfd37dc24b2fb5515982f5c0708e508b6");
        gauges[1] = _addr(hex"36cc1d791704445a5b6b9c36a667e511d4702f3f");
        gauges[2] = _addr(hex"81d837437fd18736ffd3b5c9a5a2aa835c7637e7");
        gauges[3] = _addr(hex"22804b0f6be741a9fa1bbaecdd6c8d4116e96944");
        gauges[4] = _addr(hex"95f00391cb5eebcd190eb58728b4ce23dbfa6ac1");
        gauges[5] = _addr(hex"4e6bb6b7447b7b2aa268c16ab87f4bb48bf57939");
        gauges[6] = _addr(hex"af01d68714e7ea67f43f08b5947e367126b889b1");
        gauges[7] = _addr(hex"29e9975561fad3a7988ca96361ab5c5317cb32af");
        gauges[8] = _addr(hex"d8b712d29381748db89c36bca0138d7c75866ddf");
        gauges[9] = _addr(hex"87f791090b09069b3f9c64e3be3cbbc0b45fc9b6");
        gauges[10] = _addr(hex"5c0b03914f68f2717d779a0211fd98c2cc45a4dd");
        gauges[11] = _addr(hex"9a356132605ad599aba34651aa2a606730bacaaa");
        gauges[12] = _addr(hex"09f62a6777032329c0d49f1fd4fbe9b3468cda56");
        gauges[13] = _addr(hex"9e7641a394859860210203e6d9cb82044712421c");
        gauges[14] = _addr(hex"7d6b0d7e8f5e78c0890f9e512ed70f57fd225cac");
        gauges[15] = _addr(hex"d5be6a05b45aed524730b6d1cc05f59b021f6c87");
        gauges[16] = _addr(hex"724476f141ed2de4da22ebdf435905def1118317");
        gauges[17] = _addr(hex"1ef8b6ea6434e722c916314caf8bf16c81caf2f9");
        gauges[18] = _addr(hex"0c5fa0c51c63ce937c588225c202b04c30f3ceee");
        gauges[19] = _addr(hex"f84657ca6db485ea38c63ca96dc396c2b3c6fdcc");
        gauges[20] = _addr(hex"070ebc9f46d0a6a523d31eb4ae7901c56ad97ae2");
        gauges[21] = _addr(hex"d5f2e6612e41be48461fdba20061e3c778fe6ec4");
        gauges[22] = _addr(hex"26f7786de3e6d9bd37fcf47be6f2bc455a21b74a");
        gauges[23] = _addr(hex"52618c40ddba3cbbb69f3aaa4cb26ae649844b17");
        gauges[24] = _addr(hex"92106dcfa053a8283213a062735649cbf0e718a2");
        gauges[25] = _addr(hex"0e0fd7517e9b0e206e5ee8c7df7348f6f32c3caf");
        gauges[26] = _addr(hex"1423f745c0efbb7f9db9cfad3403f90d16b10857");
        gauges[27] = _addr(hex"8796a5b0383fb08d8f0749864a4fa0b28f5532d7");
        gauges[28] = _addr(hex"7738ca93e0a122d3e66bb4e863f1572958f2c150");
        gauges[29] = _addr(hex"597fc0589daa2af5ab73e65d0da9dc78cbe82f10");
        gauges[30] = _addr(hex"8605c1fde3bed25b4cde604daec1599644629159");
        gauges[31] = _addr(hex"5e54eb89fb1ba7f735c96a45e6641b362009b228");
        gauges[32] = _addr(hex"8f5e52be9b7bde850ba13e40284f63f14677058f");
        gauges[33] = _addr(hex"143f801bc6aa4c3395379c9e28221bbaf45a69c8");
        gauges[34] = _addr(hex"ee624fcbb0c197e41ffc58999e6d35b9b893533e");
        gauges[35] = _addr(hex"f3c43e7d722963b9569d1e39873df9e2dfe8c087");
        gauges[36] = _addr(hex"b53c23d2cc6219adf78ea22bfd38bffc50ec54cb");
        gauges[37] = _addr(hex"fb18127c1471131468a1aad4785c19678e521d86");
        gauges[38] = _addr(hex"4e227d29b33b77113f84bcc189a6f886755a1f24");
        gauges[39] = _addr(hex"7e1444ba99dcdffe8fbdb42c02f0005d14f13be1");
        gauges[40] = _addr(hex"f69fb60b79e463384b40dbfdfb633ab5a863c9a2");
        gauges[41] = _addr(hex"415f30505368fa1db82feea02eb778be04e75907");
        gauges[42] = _addr(hex"19f9266f349158b54a6d95dce79297df670f7f14");
        gauges[43] = _addr(hex"c2075702490f0426e84e00d8b328119027813ac5");
        gauges[44] = _addr(hex"b069d59fddfe8e2e6e624951e306d4fdc056fa82");
        gauges[45] = _addr(hex"b251c0885c7c1975d773b57e67c138fbceaa6db4");
        gauges[46] = _addr(hex"6a253c9fe5aaff662e072aa694ce53b917adb278");
        gauges[47] = _addr(hex"afcd73e242c6d880edfa87b8146825639bda3881");
        gauges[48] = _addr(hex"a9f71f07bb592c85b7a4257be021cc336db2c627");
        gauges[49] = _addr(hex"ecbcf829742987c0600e0ee1117a32d09451882e");
        gauges[50] = _addr(hex"8c84b88562ced07f84af488cc45d434186d07b6e");
        gauges[51] = _addr(hex"7970489a543fb237abab63d62524d8a5ce165b86");
        gauges[52] = _addr(hex"83f12b0506a115e610c3e76292885192731e9b53");
        gauges[53] = _addr(hex"9755e37a291a37d8a0ab0828699a59b445477514");
        gauges[54] = _addr(hex"bc1ab4dc01cc2592c79ae207c4b35a71502d51ee");
        gauges[55] = _addr(hex"b3c33ba734ea2698c509d2498babc75b3608b735");
        gauges[56] = _addr(hex"e424b21a40cad025b2f806b9a2d32fdeaa78ee58");

        weights[0] = 780;
        weights[1] = 498;
        weights[2] = 458;
        weights[3] = 212;
        weights[4] = 211;
        weights[5] = 209;
        weights[6] = 209;
        weights[7] = 186;
        weights[8] = 160;
        weights[9] = 141;
        weights[10] = 89;
        weights[11] = 87;
        weights[12] = 70;
        weights[13] = 45;
        weights[14] = 42;
        weights[15] = 31;
        weights[16] = 29;
        weights[17] = 24;
        weights[18] = 15;
        weights[19] = 8;
        weights[20] = 7;
        weights[21] = 0;
        weights[22] = 0;
        weights[23] = 0;
        weights[24] = 0;
        weights[25] = 0;
        weights[26] = 0;
        weights[27] = 0;
        weights[28] = 0;
        weights[29] = 0;
        weights[30] = 0;
        weights[31] = 0;
        weights[32] = 30;
        weights[33] = 15;
        weights[34] = 7;
        weights[35] = 2132;
        weights[36] = 849;
        weights[37] = 790;
        weights[38] = 741;
        weights[39] = 381;
        weights[40] = 362;
        weights[41] = 275;
        weights[42] = 144;
        weights[43] = 136;
        weights[44] = 135;
        weights[45] = 92;
        weights[46] = 79;
        weights[47] = 58;
        weights[48] = 58;
        weights[49] = 55;
        weights[50] = 48;
        weights[51] = 41;
        weights[52] = 23;
        weights[53] = 11;
        weights[54] = 10;
        weights[55] = 9;
        weights[56] = 8;
    }

    function _addr(bytes20 raw) internal pure returns (address) {
        return address(raw);
    }
}
