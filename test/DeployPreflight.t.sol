// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../script/Deploy.s.sol";

contract DeployPreflightTest is Test {
    uint256 internal constant FORK_BLOCK = 25002097;

    address internal constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address internal constant MSIG = 0xa3C5A1e09150B75ff251c1a7815A07182c3de2FB;
    address internal constant CONVEX_BOT = 0x724061efDFef4a421e8be05133ad24922D07b5Bf;
    address internal constant CONVEX_DEPLOYER = 0x947B7742C403f20e5FaCcDAc5E092C943E7D0277;
    address internal constant VOTE_DELEGATE = 0x5349ffba494aC3c888ffa16fD438F44B8c67fB07;

    address internal constant CURVE_GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;
    address internal constant FX_GAUGE_CONTROLLER = 0xe60eB8098B34eD775ac44B1ddE864e098C6d7f37;
    address internal constant FX_GAUGE_VOTER = 0xAffe966B27ba3E4Ebb8A0eC124C7b7019CC762f8;
    address internal constant RESUPPLY_VOTING = 0x11111111063874cE8dC6232cb5C1C849359476E6;
    address internal constant RESUPPLY_STAKER = 0xCCCCCccc94bFeCDd365b4Ee6B86108fC91848901;

    uint256 internal constant DEFAULT_QUORUM = 1500;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) vm.skip(true, "MAINNET_RPC_URL not set");

        vm.createSelectFork(rpcUrl, FORK_BLOCK);
    }

    function test_deployScriptWiresProductionGraphOnMainnetFork() public {
        Deploy deploy = new Deploy();
        deploy.run();

        Deploy.Deployment memory d = deploy.getDeployment();

        _assertCodeDeployed(d);
        _assertCoreAndRegistry(d);
        _assertDelegationAndSurrogateDependencies(d);
        _assertCurveWiring(d);
        _assertFxWiring(d);
        _assertFraxWiring(d);
        _assertConvexWiring(d);
        _assertResupplyWiring(d);
    }

    function _assertCodeDeployed(Deploy.Deployment memory d) internal view {
        assertGt(d.core.code.length, 0, "core code");
        assertGt(d.registry.code.length, 0, "registry code");
        assertGt(d.daoDelegation.code.length, 0, "dao delegation code");
        assertGt(d.gaugeDelegation.code.length, 0, "gauge delegation code");
        assertGt(d.surrogateRegistry.code.length, 0, "surrogate registry code");
        assertGt(d.curveGaugeRegistry.code.length, 0, "curve gauge registry code");
        assertGt(d.curveDaoVoting.code.length, 0, "curve dao voting code");
        assertGt(d.curveGaugeVoting.code.length, 0, "curve gauge voting code");
        assertGt(d.curveVoteExecutor.code.length, 0, "curve vote executor code");
        assertGt(d.curveGaugeExecutor.code.length, 0, "curve gauge executor code");
        assertGt(d.curveDaoProposer.code.length, 0, "curve dao proposer code");
        assertGt(d.curveGaugeProposer.code.length, 0, "curve gauge proposer code");
        assertGt(d.fxGaugeRegistry.code.length, 0, "fx gauge registry code");
        assertGt(d.fxDaoVoting.code.length, 0, "fx dao voting code");
        assertGt(d.fxGaugeVoting.code.length, 0, "fx gauge voting code");
        assertGt(d.fxDaoProposer.code.length, 0, "fx dao proposer code");
        assertGt(d.fxGaugeProposer.code.length, 0, "fx gauge proposer code");
        assertGt(d.fxGaugeExecutor.code.length, 0, "fx gauge executor code");
        assertGt(d.fraxDaoVoting.code.length, 0, "frax dao voting code");
        assertGt(d.fraxDaoProposer.code.length, 0, "frax dao proposer code");
        assertGt(d.convexDaoVoting.code.length, 0, "convex dao voting code");
        assertGt(d.convexDaoProposer.code.length, 0, "convex dao proposer code");
        assertGt(d.resupplyDaoVoting.code.length, 0, "resupply dao voting code");
        assertGt(d.resupplyVoteExecutor.code.length, 0, "resupply vote executor code");
        assertGt(d.resupplyDaoProposer.code.length, 0, "resupply dao proposer code");
    }

    function _assertCoreAndRegistry(Deploy.Deployment memory d) internal view {
        ConvexCore core = ConvexCore(d.core);
        VotingRegistry registry = VotingRegistry(d.registry);

        assertTrue(core.operators(d.deployer), "deployer core operator");
        assertTrue(core.operators(MSIG), "msig core operator");
        assertEq(registry.owner(), d.core, "registry owner");

        assertEq(registry.getAddress("DELEGATION", registry.VOTE_DAO()), d.daoDelegation, "dao delegation registry");
        assertEq(
            registry.getAddress("DELEGATION", registry.VOTE_GAUGE()), d.gaugeDelegation, "gauge delegation registry"
        );
        assertEq(registry.getAddress("SURROGATE", registry.VOTE_DAO()), d.surrogateRegistry, "dao surrogate registry");
        assertEq(
            registry.getAddress("SURROGATE", registry.VOTE_GAUGE()), d.surrogateRegistry, "gauge surrogate registry"
        );
        assertEq(registry.getAddress("ConvexCore", registry.VOTE_DAO()), d.core, "core registry");
        assertEq(registry.getAddress("OWNER", registry.VOTE_DAO()), d.core, "owner registry");

        assertEq(registry.getAddress("CURVE", registry.GAUGE_REGISTRY()), d.curveGaugeRegistry, "curve gauge registry");
        assertEq(registry.getAddress("CURVE", registry.VOTE_DAO()), d.curveDaoVoting, "curve dao vote registry");
        assertEq(registry.getAddress("CURVE", registry.VOTE_GAUGE()), d.curveGaugeVoting, "curve gauge vote registry");
        assertEq(
            registry.getAddress("CURVE", registry.DAO_EXECUTOR()), d.curveVoteExecutor, "curve dao executor registry"
        );
        assertEq(
            registry.getAddress("CURVE", registry.GAUGE_EXECUTOR()),
            d.curveGaugeExecutor,
            "curve gauge executor registry"
        );
        assertEq(
            registry.getAddress("CURVE", registry.DAO_PROPOSER()), d.curveDaoProposer, "curve dao proposer registry"
        );
        assertEq(
            registry.getAddress("CURVE", registry.GAUGE_PROPOSER()),
            d.curveGaugeProposer,
            "curve gauge proposer registry"
        );

        assertEq(registry.getAddress("FX", registry.GAUGE_REGISTRY()), d.fxGaugeRegistry, "fx gauge registry");
        assertEq(registry.getAddress("FX", registry.VOTE_DAO()), d.fxDaoVoting, "fx dao vote registry");
        assertEq(registry.getAddress("FX", registry.VOTE_GAUGE()), d.fxGaugeVoting, "fx gauge vote registry");
        assertEq(registry.getAddress("FX", registry.DAO_PROPOSER()), d.fxDaoProposer, "fx dao proposer registry");
        assertEq(registry.getAddress("FX", registry.GAUGE_PROPOSER()), d.fxGaugeProposer, "fx gauge proposer registry");
        assertEq(registry.getAddress("FX", registry.GAUGE_EXECUTOR()), d.fxGaugeExecutor, "fx gauge executor registry");
        assertEq(registry.getAddress("FX", registry.DAO_EXECUTOR()), address(0), "fx dao executor unset");

        assertEq(registry.getAddress("FRAX", registry.VOTE_DAO()), d.fraxDaoVoting, "frax dao vote registry");
        assertEq(registry.getAddress("FRAX", registry.DAO_PROPOSER()), d.fraxDaoProposer, "frax dao proposer registry");
        assertEq(registry.getAddress("FRAX", registry.DAO_EXECUTOR()), address(0), "frax dao executor unset");
        assertEq(registry.getAddress("FRAX", registry.VOTE_GAUGE()), address(0), "frax gauge vote unset");

        assertEq(registry.getAddress("CONVEX", registry.VOTE_DAO()), d.convexDaoVoting, "convex dao vote registry");
        assertEq(
            registry.getAddress("CONVEX", registry.DAO_PROPOSER()), d.convexDaoProposer, "convex dao proposer registry"
        );
        assertEq(registry.getAddress("CONVEX", registry.DAO_EXECUTOR()), address(0), "convex dao executor unset");
        assertEq(registry.getAddress("CONVEX", registry.VOTE_GAUGE()), address(0), "convex gauge vote unset");

        assertEq(
            registry.getAddress("RESUPPLY", registry.VOTE_DAO()), d.resupplyDaoVoting, "resupply dao vote registry"
        );
        assertEq(
            registry.getAddress("RESUPPLY", registry.DAO_EXECUTOR()),
            d.resupplyVoteExecutor,
            "resupply dao executor registry"
        );
        assertEq(
            registry.getAddress("RESUPPLY", registry.DAO_PROPOSER()),
            d.resupplyDaoProposer,
            "resupply dao proposer registry"
        );
        assertEq(registry.getAddress("RESUPPLY", registry.VOTE_GAUGE()), address(0), "resupply gauge vote unset");
    }

    function _assertDelegationAndSurrogateDependencies(Deploy.Deployment memory d) internal view {
        assertEq(address(Delegation(d.daoDelegation).vlCVX()), VLCVX, "dao delegation vlcvx");
        assertEq(address(Delegation(d.gaugeDelegation).vlCVX()), VLCVX, "gauge delegation vlcvx");
    }

    function _assertCurveWiring(Deploy.Deployment memory d) internal view {
        DaoVotePlatform daoVote = DaoVotePlatform(d.curveDaoVoting);
        GaugeVotePlatform gaugeVote = GaugeVotePlatform(d.curveGaugeVoting);
        CurveVoteExecutor daoExecutor = CurveVoteExecutor(d.curveVoteExecutor);
        CurveGaugeExecutor gaugeExecutor = CurveGaugeExecutor(d.curveGaugeExecutor);
        CurveDaoProposer daoProposer = CurveDaoProposer(d.curveDaoProposer);
        GaugeProposer gaugeProposer = GaugeProposer(d.curveGaugeProposer);

        _assertDaoPlatform(daoVote, d.core, d.daoDelegation, d.surrogateRegistry, MSIG, d.curveDaoProposer, "curve");
        _assertGaugePlatform(
            gaugeVote,
            d.core,
            d.gaugeDelegation,
            d.surrogateRegistry,
            d.curveGaugeRegistry,
            MSIG,
            d.curveGaugeProposer,
            "curve"
        );
        assertEq(CurveGaugeRegistry(d.curveGaugeRegistry).gaugeController(), CURVE_GAUGE_CONTROLLER, "curve controller");

        assertEq(daoExecutor.owner(), d.core, "curve dao executor owner");
        assertEq(address(daoExecutor.votePlatform()), d.curveDaoVoting, "curve dao executor platform");
        assertEq(address(daoExecutor.voteDelegate()), VOTE_DELEGATE, "curve dao executor delegate");
        assertEq(daoExecutor.quorumBps(), DEFAULT_QUORUM, "curve dao executor quorum");
        assertTrue(daoExecutor.guardians(MSIG), "curve dao executor guardian");

        assertEq(address(gaugeExecutor.votePlatform()), d.curveGaugeVoting, "curve gauge executor platform");
        assertEq(address(gaugeExecutor.voteDelegate()), VOTE_DELEGATE, "curve gauge executor delegate");

        assertEq(daoProposer.owner(), d.core, "curve dao proposer owner");
        assertEq(address(daoProposer.daoVotePlatform()), d.curveDaoVoting, "curve dao proposer platform");
        assertEq(gaugeProposer.owner(), d.core, "curve gauge proposer owner");
        assertEq(address(gaugeProposer.vlCVX()), VLCVX, "curve gauge proposer vlcvx");
        assertEq(address(gaugeProposer.gaugeVotePlatform()), d.curveGaugeVoting, "curve gauge proposer platform");
    }

    function _assertFxWiring(Deploy.Deployment memory d) internal view {
        DaoVotePlatform daoVote = DaoVotePlatform(d.fxDaoVoting);
        GaugeVotePlatform gaugeVote = GaugeVotePlatform(d.fxGaugeVoting);
        GenericDaoProposer daoProposer = GenericDaoProposer(d.fxDaoProposer);
        GaugeProposer gaugeProposer = GaugeProposer(d.fxGaugeProposer);
        FxGaugeExecutor gaugeExecutor = FxGaugeExecutor(d.fxGaugeExecutor);

        _assertDaoPlatform(daoVote, d.core, d.daoDelegation, d.surrogateRegistry, MSIG, d.fxDaoProposer, "fx");
        _assertGaugePlatform(
            gaugeVote, d.core, d.gaugeDelegation, d.surrogateRegistry, d.fxGaugeRegistry, MSIG, d.fxGaugeProposer, "fx"
        );

        assertEq(FxGaugeRegistry(d.fxGaugeRegistry).owner(), d.core, "fx gauge registry owner");
        assertEq(FxGaugeRegistry(d.fxGaugeRegistry).gaugeController(), FX_GAUGE_CONTROLLER, "fx gauge controller");

        _assertGenericDaoProposer(daoProposer, d.core, d.fxDaoVoting, "fx");
        assertEq(gaugeProposer.owner(), d.core, "fx gauge proposer owner");
        assertEq(address(gaugeProposer.vlCVX()), VLCVX, "fx gauge proposer vlcvx");
        assertEq(address(gaugeProposer.gaugeVotePlatform()), d.fxGaugeVoting, "fx gauge proposer platform");

        assertEq(address(gaugeExecutor.votePlatform()), d.fxGaugeVoting, "fx gauge executor platform");
        assertEq(gaugeExecutor.gaugeController(), FX_GAUGE_CONTROLLER, "fx gauge executor controller");
        assertEq(gaugeExecutor.gaugeVoter(), FX_GAUGE_VOTER, "fx gauge executor voter");
    }

    function _assertFraxWiring(Deploy.Deployment memory d) internal view {
        DaoVotePlatform daoVote = DaoVotePlatform(d.fraxDaoVoting);
        GenericDaoProposer daoProposer = GenericDaoProposer(d.fraxDaoProposer);

        _assertDaoPlatform(daoVote, d.core, d.daoDelegation, d.surrogateRegistry, MSIG, d.fraxDaoProposer, "frax");
        _assertGenericDaoProposer(daoProposer, d.core, d.fraxDaoVoting, "frax");
    }

    function _assertConvexWiring(Deploy.Deployment memory d) internal view {
        DaoVotePlatform daoVote = DaoVotePlatform(d.convexDaoVoting);
        GenericDaoProposer daoProposer = GenericDaoProposer(d.convexDaoProposer);

        _assertDaoPlatform(daoVote, d.core, d.daoDelegation, d.surrogateRegistry, MSIG, d.convexDaoProposer, "convex");
        _assertGenericDaoProposer(daoProposer, d.core, d.convexDaoVoting, "convex");
    }

    function _assertResupplyWiring(Deploy.Deployment memory d) internal view {
        DaoVotePlatform daoVote = DaoVotePlatform(d.resupplyDaoVoting);
        ResupplyVoteExecutor executor = ResupplyVoteExecutor(d.resupplyVoteExecutor);
        ResupplyDaoProposer proposer = ResupplyDaoProposer(d.resupplyDaoProposer);

        _assertDaoPlatform(
            daoVote, d.core, d.daoDelegation, d.surrogateRegistry, MSIG, d.resupplyDaoProposer, "resupply"
        );

        assertEq(executor.owner(), d.core, "resupply executor owner");
        assertEq(address(executor.votePlatform()), d.resupplyDaoVoting, "resupply executor platform");
        assertEq(executor.quorumBps(), DEFAULT_QUORUM, "resupply executor quorum");
        assertEq(executor.RESUPPLY_VOTER(), RESUPPLY_VOTING, "resupply voter");
        assertEq(executor.RESUPPLY_STAKER(), RESUPPLY_STAKER, "resupply staker");
        assertTrue(executor.guardians(MSIG), "resupply guardian");

        assertEq(proposer.owner(), d.core, "resupply proposer owner");
        assertEq(address(proposer.daoVotePlatform()), d.resupplyDaoVoting, "resupply proposer platform");
        assertEq(proposer.RESUPPLY_VOTING(), RESUPPLY_VOTING, "resupply proposer external voter");
    }

    function _assertDaoPlatform(
        DaoVotePlatform platform,
        address owner,
        address delegation,
        address surrogateRegistry,
        address msigOperator,
        address proposerOperator,
        string memory prefix
    ) internal view {
        assertEq(platform.owner(), owner, string.concat(prefix, " dao owner"));
        assertEq(address(platform.vlCVX()), VLCVX, string.concat(prefix, " dao vlcvx"));
        assertEq(address(platform.delegation()), delegation, string.concat(prefix, " dao delegation"));
        assertEq(address(platform.surrogateRegistry()), surrogateRegistry, string.concat(prefix, " dao surrogate"));
        assertTrue(platform.operators(owner), string.concat(prefix, " dao owner operator"));
        assertTrue(platform.operators(msigOperator), string.concat(prefix, " dao msig operator"));
        assertTrue(platform.operators(proposerOperator), string.concat(prefix, " dao proposer operator"));
    }

    function _assertGaugePlatform(
        GaugeVotePlatform platform,
        address owner,
        address delegation,
        address surrogateRegistry,
        address gaugeRegistry,
        address msigOperator,
        address proposerOperator,
        string memory prefix
    ) internal view {
        assertEq(platform.owner(), owner, string.concat(prefix, " gauge owner"));
        assertEq(address(platform.vlCVX()), VLCVX, string.concat(prefix, " gauge vlcvx"));
        assertEq(address(platform.delegation()), delegation, string.concat(prefix, " gauge delegation"));
        assertEq(address(platform.surrogateRegistry()), surrogateRegistry, string.concat(prefix, " gauge surrogate"));
        assertEq(address(platform.gaugeRegistry()), gaugeRegistry, string.concat(prefix, " gauge registry"));
        assertTrue(platform.operators(owner), string.concat(prefix, " gauge owner operator"));
        assertTrue(platform.operators(msigOperator), string.concat(prefix, " gauge msig operator"));
        assertTrue(platform.operators(proposerOperator), string.concat(prefix, " gauge proposer operator"));
    }

    function _assertGenericDaoProposer(
        GenericDaoProposer proposer,
        address owner,
        address daoVotePlatform,
        string memory prefix
    ) internal view {
        assertEq(proposer.owner(), owner, string.concat(prefix, " generic proposer owner"));
        assertEq(
            address(proposer.daoVotePlatform()), daoVotePlatform, string.concat(prefix, " generic proposer platform")
        );
        assertTrue(proposer.operators(CONVEX_BOT), string.concat(prefix, " bot proposer operator"));
        assertTrue(proposer.operators(CONVEX_DEPLOYER), string.concat(prefix, " deployer proposer operator"));
    }
}
