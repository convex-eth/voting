// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/ConvexCore.sol";
import "../src/VotingRegistry.sol";
import "../src/Delegation.sol";
import "../src/SurrogateRegistry.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/DaoVotePlatform.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/FxGaugeRegistry.sol";
import "../src/CurveGaugeExecutor.sol";
import "../src/FxGaugeExecutor.sol";
import "../src/CurveVoteExecutor.sol";
import "../src/ResupplyVoteExecutor.sol";
import "../src/ResupplyDaoProposer.sol";
import "../src/CurveDaoProposer.sol";
import "../src/GaugeProposer.sol";
import "../src/GenericDaoProposer.sol";

// ============================================================================
// Deploy Script for Convex Voting Project
// ============================================================================
//
// Deploy to mainnet:
//   forge script script/Deploy.s.sol:Deploy --rpc-url $ETH_RPC_URL --account <ACCOUNT_NAME> --broadcast --verify --verifier etherscan
//
// Deploy to local fork:
//   anvil --fork-url $ETH_RPC_URL
//   forge script script/Deploy.s.sol:Deploy --rpc-url local --broadcast --unlocked
//
// Create a keystore account:
//   cast wallet import myaccount --interactive
//
// Deploy to testnet using keystore:
//   forge script script/Deploy.s.sol:Deploy --rpc-url $SEPOLIA_RPC_URL --account myaccount --broadcast --verify --verifier etherscan
//
// ============================================================================

contract Deploy is Script {
    address constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address constant MSIG = 0xa3C5A1e09150B75ff251c1a7815A07182c3de2FB;
    address constant CONVEX_BOT = 0x724061efDFef4a421e8be05133ad24922D07b5Bf;
    address constant CONVEX_DEPLOYER = 0x947B7742C403f20e5FaCcDAc5E092C943E7D0277;
    address constant VOTE_DELEGATE = 0x5349ffba494aC3c888ffa16fD438F44B8c67fB07;
    address constant VOTIUM = 0xde1E6A7ED0ad3F61D531a8a78E83CcDdbd6E0c49;

    uint256 constant DEFAULT_QUORUM = 1500; // 15%

    ConvexCore core;

    function _setOperator(address _platform, address _operator) internal {
        core.execute(_platform, abi.encodeWithSignature("setOperator(address,bool)", _operator, true));
    }

    function _setGuardian(address _executor, address _guardian) internal {
        core.execute(_executor, abi.encodeWithSignature("setGuardian(address,bool)", _guardian, true));
    }

    function run() external {
        address[] memory initialOperators = new address[](2);
        initialOperators[0] = CONVEX_DEPLOYER;
        initialOperators[1] = MSIG;

        vm.startBroadcast(CONVEX_DEPLOYER);

        // ── 1. Deploy ConvexCore ──
        core = new ConvexCore(initialOperators);
        console.log("ConvexCore:", address(core));

        // ── 2. Deploy VotingRegistry ──
        VotingRegistry registry = new VotingRegistry(address(core));
        console.log("VotingRegistry:", address(registry));

        // ── 3. Deploy Delegation (DAO & Gauge) ──
        Delegation daoDelegation = new Delegation(VLCVX);
        console.log("Delegation (DAO):", address(daoDelegation));

        Delegation gaugeDelegation = new Delegation(VLCVX);
        console.log("Delegation (Gauge):", address(gaugeDelegation));

        // ── 4. Deploy SurrogateRegistry ──
        SurrogateRegistry surrogateRegistry = new SurrogateRegistry();
        console.log("SurrogateRegistry:", address(surrogateRegistry));

        // ── 5. Register Core Components ──
        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "DELEGATION", registry.VOTE_DAO, address(daoDelegation)));
        console.log("Registered DELEGATION -> DAO");

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "DELEGATION", registry.VOTE_GAUGE, address(gaugeDelegation)));
        console.log("Registered DELEGATION -> Gauge");

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "SURROGATE", registry.VOTE_DAO, address(surrogateRegistry)));
        console.log("Registered SURROGATE -> DAO");

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "SURROGATE", registry.VOTE_GAUGE, address(surrogateRegistry)));
        console.log("Registered SURROGATE -> Gauge");

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "ConvexCore", registry.VOTE_DAO, address(core)));
        console.log("Registered ConvexCore");

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "OWNER", registry.VOTE_DAO, address(core)));
        console.log("Registered OWNER");

        // ── 6. Deploy CurveGaugeRegistry ──
        address[] memory curveInitialGauges = new address[](11);
        curveInitialGauges[0]  = 0x7ca5b0a2910B33e9759DC7dDB0413949071D7575;
        curveInitialGauges[1]  = 0xBC89cd85491d81C6AD2954E6d0362Ee29fCa8F53;
        curveInitialGauges[2]  = 0xFA712EE4788C042e2B7BB55E6cb8ec569C4530c1;
        curveInitialGauges[3]  = 0x69Fb7c45726cfE2baDeE8317005d3F94bE838840;
        curveInitialGauges[4]  = 0x64E3C23bfc40722d3B649844055F1D51c1ac041d;
        curveInitialGauges[5]  = 0xB1F2cdeC61db658F091671F5f199635aEF202CAC;
        curveInitialGauges[6]  = 0xA90996896660DEcC6E997655E065b23788857849;
        curveInitialGauges[7]  = 0x705350c4BcD35c9441419DdD5d2f097d7a55410F;
        curveInitialGauges[8]  = 0x4c18E409Dc8619bFb6a1cB56D114C3f592E0aE79;
        curveInitialGauges[9]  = 0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A;
        curveInitialGauges[10] = 0x18478F737d40ed7DEFe5a9d6F1560d84E283B74e;
        CurveGaugeRegistry curveGaugeRegistry = new CurveGaugeRegistry(address(core), curveInitialGauges);
        console.log("CurveGaugeRegistry:", address(curveGaugeRegistry));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", registry.GAUGE_REGISTRY, address(curveGaugeRegistry)));
        console.log("Registered CURVE -> GAUGE_REGISTRY");

        // ── 7. Deploy CurveDaoVoting ──
        DaoVotePlatform curveDaoVoting = new DaoVotePlatform(
            address(core),
            VLCVX,
            address(surrogateRegistry),
            address(daoDelegation)
        );
        console.log("CurveDaoVoting:", address(curveDaoVoting));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", registry.VOTE_DAO, address(curveDaoVoting)));
        console.log("Registered CURVE -> VOTE_DAO");

        _setOperator(address(curveDaoVoting), MSIG);
        console.log("Set MSIG as operator on CurveDaoVoting");

        // ── 8. Deploy CurveGaugeVoting ──
        GaugeVotePlatform curveGaugeVoting = new GaugeVotePlatform(
            address(core),
            VLCVX,
            address(curveGaugeRegistry),
            address(surrogateRegistry),
            address(gaugeDelegation)
        );
        console.log("CurveGaugeVoting:", address(curveGaugeVoting));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", registry.VOTE_GAUGE, address(curveGaugeVoting)));
        console.log("Registered CURVE -> VOTE_GAUGE");

        _setOperator(address(curveGaugeVoting), MSIG);
        console.log("Set MSIG as operator on CurveGaugeVoting");

        core.execute(address(curveGaugeVoting), abi.encodeWithSignature("setOvertimeAccount(address,bool)", VOTIUM, true));
        console.log("Set Votium as equalizer on CurveGaugeVoting");
        CurveVoteExecutor curveVoteExecutor = new CurveVoteExecutor(
            address(core),
            address(curveDaoVoting),
            VOTE_DELEGATE,
            DEFAULT_QUORUM
        );
        console.log("CurveVoteExecutor:", address(curveVoteExecutor));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", registry.DAO_EXECUTOR, address(curveVoteExecutor)));
        console.log("Registered CURVE -> DAO_EXECUTOR");

        _setGuardian(address(curveVoteExecutor), MSIG);
        console.log("Set MSIG as guardian on CurveVoteExecutor");

        CurveGaugeExecutor curveGaugeExecutor = new CurveGaugeExecutor(
            address(curveGaugeVoting),
            VOTE_DELEGATE
        );
        console.log("CurveGaugeExecutor:", address(curveGaugeExecutor));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", registry.GAUGE_EXECUTOR, address(curveGaugeExecutor)));
        console.log("Registered CURVE -> GAUGE_EXECUTOR");

        // ── 10. Deploy Proposers ──
        CurveDaoProposer curveDaoProposer = new CurveDaoProposer(
            address(core),
            address(curveDaoVoting)
        );
        console.log("CurveDaoProposer:", address(curveDaoProposer));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", registry.DAO_PROPOSER, address(curveDaoProposer)));
        console.log("Registered CURVE -> DAO_PROPOSER");

        GaugeProposer curveGaugeProposer = new GaugeProposer(
            address(core),
            VLCVX,
            address(curveGaugeVoting)
        );
        console.log("GaugeProposer:", address(curveGaugeProposer));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", registry.GAUGE_PROPOSER, address(curveGaugeProposer)));
        console.log("Registered CURVE -> GAUGE_PROPOSER");

        // ── 11. Set Proposers as Operators on Platforms ──
        core.execute(address(curveDaoVoting), abi.encodeWithSignature("setOperator(address,bool)", address(curveDaoProposer), true));
        console.log("Set CurveDaoProposer as operator on CurveDaoVoting");

        core.execute(address(curveGaugeVoting), abi.encodeWithSignature("setOperator(address,bool)", address(curveGaugeProposer), true));
        console.log("Set GaugeProposer as operator on CurveGaugeVoting");

        // ── 12. Deploy F(x) GaugeRegistry ──
        address[] memory fxInitialGauges = new address[](0);
        FxGaugeRegistry fxGaugeRegistry = new FxGaugeRegistry(address(core), fxInitialGauges);
        console.log("FxGaugeRegistry:", address(fxGaugeRegistry));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FX", registry.GAUGE_REGISTRY, address(fxGaugeRegistry)));
        console.log("Registered FX -> GAUGE_REGISTRY");

        // ── 13. Deploy F(x) DaoVoting ──
        DaoVotePlatform fxDaoVoting = new DaoVotePlatform(
            address(core),
            VLCVX,
            address(surrogateRegistry),
            address(daoDelegation)
        );
        console.log("FxDaoVoting:", address(fxDaoVoting));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FX", registry.VOTE_DAO, address(fxDaoVoting)));
        console.log("Registered FX -> VOTE_DAO");

        _setOperator(address(fxDaoVoting), MSIG);
        console.log("Set MSIG as operator on FxDaoVoting");

        // ── 14. Deploy F(x) GaugeVoting ──
        GaugeVotePlatform fxGaugeVoting = new GaugeVotePlatform(
            address(core),
            VLCVX,
            address(fxGaugeRegistry),
            address(surrogateRegistry),
            address(gaugeDelegation)
        );
        console.log("FxGaugeVoting:", address(fxGaugeVoting));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FX", registry.VOTE_GAUGE, address(fxGaugeVoting)));
        console.log("Registered FX -> VOTE_GAUGE");

        _setOperator(address(fxGaugeVoting), MSIG);
        console.log("Set MSIG as operator on FxGaugeVoting");

        core.execute(address(fxGaugeVoting), abi.encodeWithSignature("setOvertimeAccount(address,bool)", VOTIUM, true));
        console.log("Set Votium as equalizer on FxGaugeVoting");
        GenericDaoProposer fxDaoProposer = new GenericDaoProposer(
            address(core),
            address(fxDaoVoting)
        );
        console.log("FxDaoProposer:", address(fxDaoProposer));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FX", registry.DAO_PROPOSER, address(fxDaoProposer)));
        console.log("Registered FX -> DAO_PROPOSER");

        // Set bot and deployer as operators on Fx GenericDaoProposer
        core.execute(address(fxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_BOT, true));
        console.log("Set ConvexBot as operator on FxDaoProposer");

        core.execute(address(fxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_DEPLOYER, true));
        console.log("Set ConvexDeployer as operator on FxDaoProposer");

        // ── 16. Deploy F(x) GaugeProposer ──
        GaugeProposer fxGaugeProposer = new GaugeProposer(
            address(core),
            VLCVX,
            address(fxGaugeVoting)
        );
        console.log("FxGaugeProposer:", address(fxGaugeProposer));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FX", registry.GAUGE_PROPOSER, address(fxGaugeProposer)));
        console.log("Registered FX -> GAUGE_PROPOSER");

        // ── 17. Set Proposers as Operators on F(x) Platforms ──
        core.execute(address(fxDaoVoting), abi.encodeWithSignature("setOperator(address,bool)", address(fxDaoProposer), true));
        console.log("Set FxDaoProposer as operator on FxDaoVoting");

        core.execute(address(fxGaugeVoting), abi.encodeWithSignature("setOperator(address,bool)", address(fxGaugeProposer), true));
        console.log("Set FxGaugeProposer as operator on FxGaugeVoting");

        // ── 18. Deploy F(x) GaugeExecutor ──
        FxGaugeExecutor fxGaugeExecutor = new FxGaugeExecutor(
            address(fxGaugeVoting)
        );
        console.log("FxGaugeExecutor:", address(fxGaugeExecutor));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FX", registry.GAUGE_EXECUTOR, address(fxGaugeExecutor)));
        console.log("Registered FX -> GAUGE_EXECUTOR");

        // ── 19. Deploy Frax DaoVoting ──
        DaoVotePlatform fraxDaoVoting = new DaoVotePlatform(
            address(core),
            VLCVX,
            address(surrogateRegistry),
            address(daoDelegation)
        );
        console.log("FraxDaoVoting:", address(fraxDaoVoting));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FRAX", registry.VOTE_DAO, address(fraxDaoVoting)));
        console.log("Registered FRAX -> VOTE_DAO");

        _setOperator(address(fraxDaoVoting), MSIG);
        console.log("Set MSIG as operator on FraxDaoVoting");

        // ── 20. Deploy Frax GenericDaoProposer ──
        GenericDaoProposer fraxDaoProposer = new GenericDaoProposer(
            address(core),
            address(fraxDaoVoting)
        );
        console.log("FraxDaoProposer:", address(fraxDaoProposer));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FRAX", registry.DAO_PROPOSER, address(fraxDaoProposer)));
        console.log("Registered FRAX -> DAO_PROPOSER");

        // Set bot and deployer as operators on Frax GenericDaoProposer
        core.execute(address(fraxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_BOT, true));
        console.log("Set ConvexBot as operator on FraxDaoProposer");

        core.execute(address(fraxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_DEPLOYER, true));
        console.log("Set ConvexDeployer as operator on FraxDaoProposer");

        // ── 21. Set Proposer as Operator on Frax Platform ──
        core.execute(address(fraxDaoVoting), abi.encodeWithSignature("setOperator(address,bool)", address(fraxDaoProposer), true));
        console.log("Set FraxDaoProposer as operator on FraxDaoVoting");

        // ── 22. Deploy Convex DaoVoting ──
        DaoVotePlatform convexDaoVoting = new DaoVotePlatform(
            address(core),
            VLCVX,
            address(surrogateRegistry),
            address(daoDelegation)
        );
        console.log("ConvexDaoVoting:", address(convexDaoVoting));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CONVEX", registry.VOTE_DAO, address(convexDaoVoting)));
        console.log("Registered CONVEX -> VOTE_DAO");

        _setOperator(address(convexDaoVoting), MSIG);
        console.log("Set MSIG as operator on ConvexDaoVoting");

        // ── 23. Deploy Convex GenericDaoProposer ──
        GenericDaoProposer convexDaoProposer = new GenericDaoProposer(
            address(core),
            address(convexDaoVoting)
        );
        console.log("ConvexDaoProposer:", address(convexDaoProposer));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CONVEX", registry.DAO_PROPOSER, address(convexDaoProposer)));
        console.log("Registered CONVEX -> DAO_PROPOSER");

        // Set bot and deployer as operators on Convex GenericDaoProposer
        core.execute(address(convexDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_BOT, true));
        console.log("Set ConvexBot as operator on ConvexDaoProposer");

        core.execute(address(convexDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_DEPLOYER, true));
        console.log("Set ConvexDeployer as operator on ConvexDaoProposer");

        // ── 24. Set Proposer as Operator on Convex Platform ──
        core.execute(address(convexDaoVoting), abi.encodeWithSignature("setOperator(address,bool)", address(convexDaoProposer), true));
        console.log("Set ConvexDaoProposer as operator on ConvexDaoVoting");

        // ── 25. Deploy Resupply DaoVoting ──
        DaoVotePlatform resupplyDaoVoting = new DaoVotePlatform(
            address(core),
            VLCVX,
            address(surrogateRegistry),
            address(daoDelegation)
        );
        console.log("ResupplyDaoVoting:", address(resupplyDaoVoting));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "RESUPPLY", registry.VOTE_DAO, address(resupplyDaoVoting)));
        console.log("Registered RESUPPLY -> VOTE_DAO");

        _setOperator(address(resupplyDaoVoting), MSIG);
        console.log("Set MSIG as operator on ResupplyDaoVoting");

        // ── 26. Deploy ResupplyVoteExecutor ──
        ResupplyVoteExecutor resupplyVoteExecutor = new ResupplyVoteExecutor(
            address(core),
            address(resupplyDaoVoting),
            DEFAULT_QUORUM
        );
        console.log("ResupplyVoteExecutor:", address(resupplyVoteExecutor));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "RESUPPLY", registry.DAO_EXECUTOR, address(resupplyVoteExecutor)));
        console.log("Registered RESUPPLY -> DAO_EXECUTOR");

        _setGuardian(address(resupplyVoteExecutor), MSIG);
        console.log("Set MSIG as guardian on ResupplyVoteExecutor");

        // ── 27. Deploy ResupplyDaoProposer ──
        ResupplyDaoProposer resupplyDaoProposer = new ResupplyDaoProposer(
            address(core),
            address(resupplyDaoVoting)
        );
        console.log("ResupplyDaoProposer:", address(resupplyDaoProposer));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "RESUPPLY", registry.DAO_PROPOSER, address(resupplyDaoProposer)));
        console.log("Registered RESUPPLY -> DAO_PROPOSER");

        _setOperator(address(resupplyDaoVoting), address(resupplyDaoProposer));
        console.log("Set ResupplyDaoProposer as operator on ResupplyDaoVoting");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("ConvexCore:", address(core));
        console.log("VotingRegistry:", address(registry));
        console.log("CurveDaoVoting:", address(curveDaoVoting));
        console.log("CurveGaugeVoting:", address(curveGaugeVoting));
        console.log("CurveGaugeRegistry:", address(curveGaugeRegistry));
        console.log("CurveVoteExecutor:", address(curveVoteExecutor));
        console.log("CurveGaugeExecutor:", address(curveGaugeExecutor));
        console.log("CurveDaoProposer:", address(curveDaoProposer));
        console.log("GaugeProposer:", address(curveGaugeProposer));
        console.log("FxGaugeRegistry:", address(fxGaugeRegistry));
        console.log("FxDaoVoting:", address(fxDaoVoting));
        console.log("FxGaugeVoting:", address(fxGaugeVoting));
        console.log("FxDaoProposer:", address(fxDaoProposer));
        console.log("FxGaugeProposer:", address(fxGaugeProposer));
        console.log("FxGaugeExecutor:", address(fxGaugeExecutor));
        console.log("FraxDaoVoting:", address(fraxDaoVoting));
        console.log("FraxDaoProposer:", address(fraxDaoProposer));
        console.log("ConvexDaoVoting:", address(convexDaoVoting));
        console.log("ConvexDaoProposer:", address(convexDaoProposer));
        console.log("ResupplyDaoVoting:", address(resupplyDaoVoting));
        console.log("ResupplyDaoProposer:", address(resupplyDaoProposer));
        console.log("ResupplyVoteExecutor:", address(resupplyVoteExecutor));
    }
}