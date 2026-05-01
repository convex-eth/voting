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

    uint256 constant DEFAULT_QUORUM = 1500; // 15%

    ConvexCore core;

    function _setOperator(address _platform, address _operator) internal {
        core.execute(_platform, abi.encodeWithSignature("setOperator(address,bool)", _operator, true));
    }

    function _setGuardian(address _executor, address _guardian) internal {
        core.execute(_executor, abi.encodeWithSignature("setGuardian(address,bool)", _guardian, true));
    }

    function run() external {
        address deployer = msg.sender;
        address[] memory initialOperators = new address[](2);
        initialOperators[0] = deployer;
        initialOperators[1] = MSIG;

        vm.startBroadcast();

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
        CurveGaugeRegistry curveGaugeRegistry = new CurveGaugeRegistry();
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

        // ── 9. Deploy Executors ──
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
            VOTE_DELEGATE,
            address(curveGaugeVoting)
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
        FxGaugeRegistry fxGaugeRegistry = new FxGaugeRegistry(address(core));
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

        // ── 15. Deploy F(x) GenericDaoProposer ──
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

        // ── 22. Deploy ResupplyVoteExecutor ──
        ResupplyVoteExecutor resupplyVoteExecutor = new ResupplyVoteExecutor(
            address(core),
            address(fraxDaoVoting),
            DEFAULT_QUORUM
        );
        console.log("ResupplyVoteExecutor:", address(resupplyVoteExecutor));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "RESUPPLY", registry.DAO_EXECUTOR, address(resupplyVoteExecutor)));
        console.log("Registered RESUPPLY -> DAO_EXECUTOR");

        _setGuardian(address(resupplyVoteExecutor), MSIG);
        console.log("Set MSIG as guardian on ResupplyVoteExecutor");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("ConvexCore:", address(core));
        console.log("VotingRegistry:", address(registry));
        console.log("CurveDaoVoting:", address(curveDaoVoting));
        console.log("CurveGaugeVoting:", address(curveGaugeVoting));
        console.log("CurveDaoProposer:", address(curveDaoProposer));
        console.log("GaugeProposer:", address(curveGaugeProposer));
        console.log("FxDaoVoting:", address(fxDaoVoting));
        console.log("FxGaugeVoting:", address(fxGaugeVoting));
        console.log("FxDaoProposer:", address(fxDaoProposer));
        console.log("FxGaugeProposer:", address(fxGaugeProposer));
        console.log("FxGaugeExecutor:", address(fxGaugeExecutor));
        console.log("FraxDaoVoting:", address(fraxDaoVoting));
        console.log("FraxDaoProposer:", address(fraxDaoProposer));
        console.log("ResupplyVoteExecutor:", address(resupplyVoteExecutor));
    }
}