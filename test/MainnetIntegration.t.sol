// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/CurveDaoProposer.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/FxGaugeExecutor.sol";
import "../src/FxGaugeRegistry.sol";
import "../src/ResupplyDaoProposer.sol";
import "../src/ResupplyVoteExecutor.sol";
import "../src/interface/ICurveGauge.sol";
import "../src/interface/IFxGauge.sol";
import "../src/interface/IFxGaugeController.sol";
import "../src/interface/IFxGaugeVoter.sol";
import "../src/interface/IGaugeController.sol";
import "../src/interface/IVoteDelegateExtension.sol";
import "../src/interface/IVoteDelegationExtension.sol";
import "../src/interface/IvlCVX.sol";

interface ICurveVotingLength {
    function votesLength() external view returns (uint256);
}

contract MainnetIntegrationTest is Test {
    uint256 internal constant FORK_BLOCK = 25002097;

    address internal constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address internal constant VOTE_DELEGATE = 0x5349ffba494aC3c888ffa16fD438F44B8c67fB07;
    address internal constant CURVE_OWNERSHIP = 0xE478de485ad2fe566d49342Cbd03E49ed7DB3356;
    address internal constant CURVE_PARAMETER = 0xBCfF8B0b9419b9A88c44546519b1e909cF330399;
    address internal constant CURVE_GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;
    address internal constant LEGACY_CURVE_GAUGE = 0x7ca5b0a2910B33e9759DC7dDB0413949071D7575;
    address internal constant MODERN_CURVE_GAUGE = 0xdA0DD1798BE66E17d5aB1Dc476302b56689C2DB4;

    address internal constant FX_GAUGE_CONTROLLER = 0xe60eB8098B34eD775ac44B1ddE864e098C6d7f37;
    address internal constant FX_GAUGE_VOTER = 0xAffe966B27ba3E4Ebb8A0eC124C7b7019CC762f8;
    address internal constant ACTIVE_FX_GAUGE = 0xA5250C540914E012E22e623275E290c4dC993D11;
    address internal constant INACTIVE_FX_GAUGE = 0xfa4761512aaf899b010438a10C60D01EBdc0eFcA;

    address internal constant RESUPPLY_VOTING = 0x11111111063874cE8dC6232cb5C1C849359476E6;
    address internal constant RESUPPLY_STAKER = 0xCCCCCccc94bFeCDd365b4Ee6B86108fC91848901;

    bytes4 internal constant ERROR_SELECTOR = bytes4(keccak256("Error(string)"));

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) vm.skip(true, "MAINNET_RPC_URL not set");

        vm.createSelectFork(rpcUrl, FORK_BLOCK);
    }

    function test_vlCvxEpochInterfaceAtPinnedMainnetBlock() public view {
        assertGt(VLCVX.code.length, 0);

        IvlCVX vlCVX = IvlCVX(VLCVX);
        assertEq(vlCVX.symbol(), "vlCVX");

        uint256 epochCount = vlCVX.epochCount();
        assertEq(epochCount, 219);

        uint256 currentEpoch = epochCount - 2;
        (uint224 supply, uint32 date) = vlCVX.epochs(currentEpoch);

        assertGt(supply, 0);
        assertEq(date, 1777507200);
        assertGt(vlCVX.totalSupplyAtEpoch(currentEpoch), 0);
    }

    function test_curveAdapterAddressesAndInterfacesAtPinnedMainnetBlock() public {
        assertGt(CURVE_OWNERSHIP.code.length, 0);
        assertGt(CURVE_PARAMETER.code.length, 0);
        assertGt(CURVE_GAUGE_CONTROLLER.code.length, 0);
        assertGt(VOTE_DELEGATE.code.length, 0);

        CurveDaoProposer proposer = new CurveDaoProposer(address(this), address(1));
        assertEq(proposer.CURVE_OWNERSHIP(), CURVE_OWNERSHIP);
        assertEq(proposer.CURVE_PARAMETER(), CURVE_PARAMETER);

        uint256 ownershipVoteCount = ICurveVotingLength(CURVE_OWNERSHIP).votesLength();
        uint256 parameterVoteCount = ICurveVotingLength(CURVE_PARAMETER).votesLength();
        assertEq(ownershipVoteCount, 1402);
        assertEq(parameterVoteCount, 102);

        (bool ownershipOpen,, uint64 ownershipStartDate,,,,,,,) =
            ICurveVoting(CURVE_OWNERSHIP).getVote(ownershipVoteCount - 1);
        (bool parameterOpen,, uint64 parameterStartDate,,,,,,,) =
            ICurveVoting(CURVE_PARAMETER).getVote(parameterVoteCount - 1);
        assertTrue(ownershipOpen);
        assertFalse(parameterOpen);
        assertGt(ownershipStartDate, 0);
        assertGt(parameterStartDate, 0);

        CurveGaugeRegistry registry = new CurveGaugeRegistry();
        assertEq(registry.gaugeController(), CURVE_GAUGE_CONTROLLER);

        assertGt(IGaugeController(CURVE_GAUGE_CONTROLLER).get_gauge_weight(LEGACY_CURVE_GAUGE), 0);
        assertGt(IGaugeController(CURVE_GAUGE_CONTROLLER).get_gauge_weight(MODERN_CURVE_GAUGE), 0);
        assertTrue(registry.isValidGauge(LEGACY_CURVE_GAUGE));
        assertTrue(registry.isValidGauge(MODERN_CURVE_GAUGE));
        assertFalse(ICurveGauge(MODERN_CURVE_GAUGE).is_killed());

        address[] memory gauges = new address[](1);
        gauges[0] = MODERN_CURVE_GAUGE;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 0;

        (bool gaugeVoteOk, bytes memory gaugeVoteData) =
            VOTE_DELEGATE.call(abi.encodeWithSelector(IVoteDelegateExtension.GaugeVote.selector, gauges, weights));
        assertFalse(gaugeVoteOk);
        assertEq(_decodeRevertReason(gaugeVoteData), "!gop");

        (bool daoVoteOk, bytes memory daoVoteData) = VOTE_DELEGATE.call(
            abi.encodeWithSelector(IVoteDelegationExtension.DaoVoteWithWeights.selector, 0, 0, 10000, true)
        );
        assertFalse(daoVoteOk);
        assertEq(_decodeRevertReason(daoVoteData), "!dop");
    }

    function test_fxAdapterAddressesAndInterfacesAtPinnedMainnetBlock() public {
        assertGt(FX_GAUGE_CONTROLLER.code.length, 0);
        assertGt(FX_GAUGE_VOTER.code.length, 0);
        assertGt(ACTIVE_FX_GAUGE.code.length, 0);
        assertGt(INACTIVE_FX_GAUGE.code.length, 0);

        FxGaugeRegistry registry = new FxGaugeRegistry(address(this));
        assertEq(registry.gaugeController(), FX_GAUGE_CONTROLLER);

        FxGaugeExecutor executor = new FxGaugeExecutor(address(1));
        assertEq(executor.gaugeController(), FX_GAUGE_CONTROLLER);
        assertEq(executor.gaugeVoter(), FX_GAUGE_VOTER);

        assertEq(IFxGaugeController(FX_GAUGE_CONTROLLER).gauge_types(ACTIVE_FX_GAUGE), registry.LIQUIDITY_POOL());
        assertTrue(IFxGauge(ACTIVE_FX_GAUGE).isActive());
        assertTrue(registry.isValidGauge(ACTIVE_FX_GAUGE));
        assertFalse(registry.isValidGauge(INACTIVE_FX_GAUGE));

        address[] memory gauges = new address[](1);
        gauges[0] = ACTIVE_FX_GAUGE;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 0;

        (bool ok, bytes memory data) = FX_GAUGE_VOTER.call(
            abi.encodeWithSelector(IFxGaugeVoter.voteGaugeWeight.selector, FX_GAUGE_CONTROLLER, gauges, weights)
        );
        assertFalse(ok);
        assertEq(_decodeRevertReason(data), "!o_auth");
    }

    function test_resupplyAdapterAddressesAndInterfacesAtPinnedMainnetBlock() public {
        assertGt(RESUPPLY_VOTING.code.length, 0);
        assertGt(RESUPPLY_STAKER.code.length, 0);

        ResupplyDaoProposer proposer = new ResupplyDaoProposer(address(this), address(1));
        assertEq(proposer.RESUPPLY_VOTING(), RESUPPLY_VOTING);

        ResupplyVoteExecutor executor = new ResupplyVoteExecutor(address(this), address(1), 0);
        assertEq(executor.RESUPPLY_VOTER(), RESUPPLY_VOTING);
        assertEq(executor.RESUPPLY_STAKER(), RESUPPLY_STAKER);

        (, uint256 epoch, uint256 createdAt,,,, bool processed,,) = IResupplyVoting(RESUPPLY_VOTING).getProposalData(0);
        assertEq(epoch, 15);
        assertEq(createdAt, 1751169587);
        assertTrue(processed);

        (bool safeExecuteOk, bytes memory safeExecuteData) =
            RESUPPLY_STAKER.call(abi.encodeWithSelector(IResupplyStaker.safeExecute.selector, RESUPPLY_VOTING, ""));
        assertFalse(safeExecuteOk);
        assertEq(_decodeRevertReason(safeExecuteData), "!ownerOrOperator");

        vm.prank(RESUPPLY_STAKER);
        (bool voteOk, bytes memory voteData) = RESUPPLY_VOTING.call(
            abi.encodeWithSelector(IResupplyVoter.voteForProposal.selector, RESUPPLY_STAKER, 0, 0, 10000)
        );
        assertFalse(voteOk);
        assertEq(_decodeRevertReason(voteData), "Already voted");
    }

    function _decodeRevertReason(bytes memory data) internal pure returns (string memory) {
        if (data.length < 68) return "";

        bytes4 selector;
        assembly {
            selector := mload(add(data, 0x20))
        }
        if (selector != ERROR_SELECTOR) return "";

        bytes memory reasonData = new bytes(data.length - 4);
        for (uint256 i = 0; i < reasonData.length;) {
            reasonData[i] = data[i + 4];
            unchecked {
                ++i;
            }
        }

        return abi.decode(reasonData, (string));
    }
}
