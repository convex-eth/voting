// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
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
import "../src/GaugeVoteHelper.sol";
import "../src/ProposalMetadata.sol";

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
    using stdJson for string;
    address constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address constant MSIG = 0xa3C5A1e09150B75ff251c1a7815A07182c3de2FB;
    address constant CONVEX_BOT = 0x724061efDFef4a421e8be05133ad24922D07b5Bf;
    address constant CONVEX_DEPLOYER = 0x947B7742C403f20e5FaCcDAc5E092C943E7D0277;
    address constant VOTE_DELEGATE = 0x5349ffba494aC3c888ffa16fD438F44B8c67fB07;
    address constant VOTIUM = 0xde1E6A7ED0ad3F61D531a8a78E83CcDdbd6E0c49;
    address constant CONVEX_CORE = 0xCC07e8BA6bc8aeb18C4AE110C3Da9c7Dce4A3e74;

    uint256 constant DEFAULT_QUORUM = 1500; // 15%

    uint8 constant VOTE_DAO = 0;
    uint8 constant VOTE_GAUGE = 1;
    uint8 constant GAUGE_REGISTRY = 2;
    uint8 constant DAO_EXECUTOR = 3;
    uint8 constant GAUGE_EXECUTOR = 4;
    uint8 constant DAO_PROPOSER = 5;
    uint8 constant GAUGE_PROPOSER = 6;
    uint8 constant DAO_METADATA = 7;

    ConvexCore core;

    function _setOperator(address _platform, address _operator) internal {
        core.execute(_platform, abi.encodeWithSignature("setOperator(address,bool)", _operator, true));
    }

    function _setGuardian(address _executor, address _guardian) internal {
        core.execute(_executor, abi.encodeWithSignature("setGuardian(address,bool)", _guardian, true));
    }

    function run() external {
        if (CONVEX_CORE.code.length == 0) revert("ConvexCore not deployed");
        core = ConvexCore(CONVEX_CORE);

        vm.startBroadcast(CONVEX_DEPLOYER);

        // ── 1. Use existing ConvexCore ──
        console.log("ConvexCore:", address(core));

        // ── 2. Deploy VotingRegistry ──
        VotingRegistry registry = new VotingRegistry(address(core));
        console.log("VotingRegistry:", address(registry));

        // ── 3. Deploy Delegation (DAO & Gauge) ──
        Delegation daoDelegation = new Delegation("Dao Delegation", address(core), VLCVX);
        console.log("Delegation (DAO):", address(daoDelegation));

        Delegation gaugeDelegation = new Delegation("Gauge Delegation", address(core), VLCVX);
        console.log("Delegation (Gauge):", address(gaugeDelegation));

        core.execute(address(daoDelegation), abi.encodeWithSignature("completeInitialization()"));
        console.log("Completed DAO Delegation initialization");
        console.log("Gauge Delegation initialization left open for SeedDelegates script");

        // ── 4. Deploy SurrogateRegistry ──
        SurrogateRegistry surrogateRegistry = new SurrogateRegistry("Convex Surrogate Registry");
        console.log("SurrogateRegistry:", address(surrogateRegistry));

        // ── 5. Register Core Components ──
        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "DELEGATION", VOTE_DAO, address(daoDelegation)
            )
        );
        console.log("Registered DELEGATION -> DAO");

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "DELEGATION", VOTE_GAUGE, address(gaugeDelegation)
            )
        );
        console.log("Registered DELEGATION -> Gauge");

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "SURROGATE", VOTE_DAO, address(surrogateRegistry)
            )
        );
        console.log("Registered SURROGATE -> DAO");

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "SURROGATE", VOTE_GAUGE, address(surrogateRegistry)
            )
        );
        console.log("Registered SURROGATE -> Gauge");

        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "ConvexCore", VOTE_DAO, address(core))
        );
        console.log("Registered ConvexCore");

        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "OWNER", VOTE_DAO, address(core))
        );
        console.log("Registered OWNER");

        // ── 6. Deploy CurveGaugeRegistry ──
        uint256[] memory curveInitialGauges = new uint256[](11);
        for (uint256 i = 0; i < curveInitialGauges.length;) {
            curveInitialGauges[i] = i;
            unchecked {
                ++i;
            }
        }
        CurveGaugeRegistry curveGaugeRegistry =
            new CurveGaugeRegistry("Curve Gauge Registry", address(core), curveInitialGauges);
        console.log("CurveGaugeRegistry:", address(curveGaugeRegistry));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", GAUGE_REGISTRY, address(curveGaugeRegistry)
            )
        );
        console.log("Registered CURVE -> GAUGE_REGISTRY");

        // ── 7. Deploy CurveDaoVoting ──
        DaoVotePlatform curveDaoVoting = new DaoVotePlatform(
            "Curve Dao Voting", address(core), VLCVX, address(surrogateRegistry), address(daoDelegation)
        );
        console.log("CurveDaoVoting:", address(curveDaoVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", VOTE_DAO, address(curveDaoVoting)
            )
        );
        console.log("Registered CURVE -> VOTE_DAO");

        _setOperator(address(curveDaoVoting), MSIG);
        console.log("Set MSIG as operator on CurveDaoVoting");

        // ── 8. Deploy CurveGaugeVoting ──
        GaugeVotePlatform curveGaugeVoting = new GaugeVotePlatform(
            "Curve Gauge Voting",
            address(core),
            VLCVX,
            address(curveGaugeRegistry),
            address(surrogateRegistry),
            address(gaugeDelegation)
        );
        console.log("CurveGaugeVoting:", address(curveGaugeVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", VOTE_GAUGE, address(curveGaugeVoting)
            )
        );
        console.log("Registered CURVE -> VOTE_GAUGE");

        _setOperator(address(curveGaugeVoting), MSIG);
        console.log("Set MSIG as operator on CurveGaugeVoting");

        core.execute(
            address(curveGaugeVoting), abi.encodeWithSignature("setOvertimeAccount(address,bool)", VOTIUM, true)
        );
        console.log("Set Votium as equalizer on CurveGaugeVoting");
        CurveVoteExecutor curveVoteExecutor = new CurveVoteExecutor(
            "Curve Vote Executor", address(core), address(curveDaoVoting), VOTE_DELEGATE, DEFAULT_QUORUM
        );
        console.log("CurveVoteExecutor:", address(curveVoteExecutor));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", DAO_EXECUTOR, address(curveVoteExecutor)
            )
        );
        console.log("Registered CURVE -> DAO_EXECUTOR");

        _setGuardian(address(curveVoteExecutor), MSIG);
        console.log("Set MSIG as guardian on CurveVoteExecutor");

        CurveGaugeExecutor curveGaugeExecutor =
            new CurveGaugeExecutor("Curve Gauge Executor", address(curveGaugeVoting), VOTE_DELEGATE);
        console.log("CurveGaugeExecutor:", address(curveGaugeExecutor));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", GAUGE_EXECUTOR, address(curveGaugeExecutor)
            )
        );
        console.log("Registered CURVE -> GAUGE_EXECUTOR");

        GaugeVoteHelper curveGaugeHelper = new GaugeVoteHelper("Gauge Vote Helper", address(gaugeDelegation));
        console.log("GaugeVoteHelper:", address(curveGaugeHelper));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "HELPER", VOTE_GAUGE, address(curveGaugeHelper)
            )
        );
        console.log("Registered HELPER -> GAUGE_HELPER");

        // ── 10. Deploy Proposers ──
        CurveDaoProposer curveDaoProposer =
            new CurveDaoProposer("Curve Dao Proposer", address(core), address(curveDaoVoting));
        console.log("CurveDaoProposer:", address(curveDaoProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", DAO_PROPOSER, address(curveDaoProposer)
            )
        );
        console.log("Registered CURVE -> DAO_PROPOSER");

        GaugeProposer curveGaugeProposer =
            new GaugeProposer("Curve Gauge Proposer", address(core), VLCVX, address(curveGaugeVoting));
        console.log("GaugeProposer:", address(curveGaugeProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CURVE", GAUGE_PROPOSER, address(curveGaugeProposer)
            )
        );
        console.log("Registered CURVE -> GAUGE_PROPOSER");

        // ── 11. Set Proposers as Operators on Platforms ──
        core.execute(
            address(curveDaoVoting),
            abi.encodeWithSignature("setOperator(address,bool)", address(curveDaoProposer), true)
        );
        console.log("Set CurveDaoProposer as operator on CurveDaoVoting");

        core.execute(
            address(curveGaugeVoting),
            abi.encodeWithSignature("setOperator(address,bool)", address(curveGaugeProposer), true)
        );
        console.log("Set GaugeProposer as operator on CurveGaugeVoting");

        // ── 12. Deploy F(x) GaugeRegistry ──
        uint256[] memory fxInitialGauges = new uint256[](0);
        FxGaugeRegistry fxGaugeRegistry = new FxGaugeRegistry("Fx Gauge Registry", address(core), fxInitialGauges);
        console.log("FxGaugeRegistry:", address(fxGaugeRegistry));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FX", GAUGE_REGISTRY, address(fxGaugeRegistry)
            )
        );
        console.log("Registered FX -> GAUGE_REGISTRY");

        string memory fxGaugeJson = vm.readFile("data/fx_gauge_ids.json");
        uint256[] memory fxGauges = fxGaugeJson.readUintArray(".ids");
        console.log("FX gauge id count", fxGauges.length);
        fxGaugeRegistry.setGauges(fxGauges);
        console.log("Registered FX gauges");

        // ── 13. Deploy F(x) DaoVoting ──
        DaoVotePlatform fxDaoVoting = new DaoVotePlatform(
            "Fx Dao Voting", address(core), VLCVX, address(surrogateRegistry), address(daoDelegation)
        );
        console.log("FxDaoVoting:", address(fxDaoVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FX", VOTE_DAO, address(fxDaoVoting))
        );
        console.log("Registered FX -> VOTE_DAO");

        _setOperator(address(fxDaoVoting), MSIG);
        console.log("Set MSIG as operator on FxDaoVoting");

        // ── 14. Deploy F(x) GaugeVoting ──
        GaugeVotePlatform fxGaugeVoting = new GaugeVotePlatform(
            "Fx Gauge Voting",
            address(core),
            VLCVX,
            address(fxGaugeRegistry),
            address(surrogateRegistry),
            address(gaugeDelegation)
        );
        console.log("FxGaugeVoting:", address(fxGaugeVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FX", VOTE_GAUGE, address(fxGaugeVoting))
        );
        console.log("Registered FX -> VOTE_GAUGE");

        _setOperator(address(fxGaugeVoting), MSIG);
        console.log("Set MSIG as operator on FxGaugeVoting");

        core.execute(address(fxGaugeVoting), abi.encodeWithSignature("setOvertimeAccount(address,bool)", VOTIUM, true));
        console.log("Set Votium as equalizer on FxGaugeVoting");
        GenericDaoProposer fxDaoProposer =
            new GenericDaoProposer("Fx Dao Proposer", address(core), address(fxDaoVoting));
        console.log("FxDaoProposer:", address(fxDaoProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FX", DAO_PROPOSER, address(fxDaoProposer)
            )
        );
        console.log("Registered FX -> DAO_PROPOSER");

        // Set bot and deployer as operators on Fx GenericDaoProposer
        core.execute(address(fxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_BOT, true));
        console.log("Set ConvexBot as operator on FxDaoProposer");

        core.execute(
            address(fxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_DEPLOYER, true)
        );
        console.log("Set ConvexDeployer as operator on FxDaoProposer");

        ProposalMetadata fxProposalMetadata = new ProposalMetadata("Fx Proposal Metadata", address(core));
        console.log("FxProposalMetadata:", address(fxProposalMetadata));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FX", DAO_METADATA, address(fxProposalMetadata)
            )
        );
        console.log("Registered FX -> DAO_METADATA");

        _setOperator(address(fxProposalMetadata), CONVEX_BOT);
        console.log("Set ConvexBot as operator on FxProposalMetadata");

        _setOperator(address(fxProposalMetadata), CONVEX_DEPLOYER);
        console.log("Set ConvexDeployer as operator on FxProposalMetadata");

        // ── 16. Deploy F(x) GaugeProposer ──
        GaugeProposer fxGaugeProposer =
            new GaugeProposer("Fx Gauge Proposer", address(core), VLCVX, address(fxGaugeVoting));
        console.log("FxGaugeProposer:", address(fxGaugeProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FX", GAUGE_PROPOSER, address(fxGaugeProposer)
            )
        );
        console.log("Registered FX -> GAUGE_PROPOSER");

        // ── 17. Set Proposers as Operators on F(x) Platforms ──
        core.execute(
            address(fxDaoVoting), abi.encodeWithSignature("setOperator(address,bool)", address(fxDaoProposer), true)
        );
        console.log("Set FxDaoProposer as operator on FxDaoVoting");

        core.execute(
            address(fxGaugeVoting), abi.encodeWithSignature("setOperator(address,bool)", address(fxGaugeProposer), true)
        );
        console.log("Set FxGaugeProposer as operator on FxGaugeVoting");

        // ── 18. Deploy F(x) GaugeExecutor ──
        FxGaugeExecutor fxGaugeExecutor =
            new FxGaugeExecutor("Fx Gauge Executor", address(fxGaugeVoting), address(core));
        console.log("FxGaugeExecutor:", address(fxGaugeExecutor));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FX", GAUGE_EXECUTOR, address(fxGaugeExecutor)
            )
        );
        console.log("Registered FX -> GAUGE_EXECUTOR");

        // ── 19. Deploy Frax DaoVoting ──
        DaoVotePlatform fraxDaoVoting = new DaoVotePlatform(
            "Frax Dao Voting", address(core), VLCVX, address(surrogateRegistry), address(daoDelegation)
        );
        console.log("FraxDaoVoting:", address(fraxDaoVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", "FRAX", VOTE_DAO, address(fraxDaoVoting))
        );
        console.log("Registered FRAX -> VOTE_DAO");

        _setOperator(address(fraxDaoVoting), MSIG);
        console.log("Set MSIG as operator on FraxDaoVoting");

        // ── 20. Deploy Frax GenericDaoProposer ──
        GenericDaoProposer fraxDaoProposer =
            new GenericDaoProposer("Frax Dao Proposer", address(core), address(fraxDaoVoting));
        console.log("FraxDaoProposer:", address(fraxDaoProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FRAX", DAO_PROPOSER, address(fraxDaoProposer)
            )
        );
        console.log("Registered FRAX -> DAO_PROPOSER");

        // Set bot and deployer as operators on Frax GenericDaoProposer
        core.execute(address(fraxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_BOT, true));
        console.log("Set ConvexBot as operator on FraxDaoProposer");

        core.execute(
            address(fraxDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_DEPLOYER, true)
        );
        console.log("Set ConvexDeployer as operator on FraxDaoProposer");

        ProposalMetadata fraxProposalMetadata = new ProposalMetadata("Frax Proposal Metadata", address(core));
        console.log("FraxProposalMetadata:", address(fraxProposalMetadata));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "FRAX", DAO_METADATA, address(fraxProposalMetadata)
            )
        );
        console.log("Registered FRAX -> DAO_METADATA");

        _setOperator(address(fraxProposalMetadata), CONVEX_BOT);
        console.log("Set ConvexBot as operator on FraxProposalMetadata");

        _setOperator(address(fraxProposalMetadata), CONVEX_DEPLOYER);
        console.log("Set ConvexDeployer as operator on FraxProposalMetadata");

        // ── 21. Set Proposer as Operator on Frax Platform ──
        core.execute(
            address(fraxDaoVoting), abi.encodeWithSignature("setOperator(address,bool)", address(fraxDaoProposer), true)
        );
        console.log("Set FraxDaoProposer as operator on FraxDaoVoting");

        // ── 22. Deploy Convex DaoVoting ──
        DaoVotePlatform convexDaoVoting = new DaoVotePlatform(
            "Convex Dao Voting", address(core), VLCVX, address(surrogateRegistry), address(daoDelegation)
        );
        console.log("ConvexDaoVoting:", address(convexDaoVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CONVEX", VOTE_DAO, address(convexDaoVoting)
            )
        );
        console.log("Registered CONVEX -> VOTE_DAO");

        _setOperator(address(convexDaoVoting), MSIG);
        console.log("Set MSIG as operator on ConvexDaoVoting");

        // ── 23. Deploy Convex GenericDaoProposer ──
        GenericDaoProposer convexDaoProposer =
            new GenericDaoProposer("Convex Dao Proposer", address(core), address(convexDaoVoting));
        console.log("ConvexDaoProposer:", address(convexDaoProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CONVEX", DAO_PROPOSER, address(convexDaoProposer)
            )
        );
        console.log("Registered CONVEX -> DAO_PROPOSER");

        // Set bot and deployer as operators on Convex GenericDaoProposer
        core.execute(address(convexDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_BOT, true));
        console.log("Set ConvexBot as operator on ConvexDaoProposer");

        core.execute(
            address(convexDaoProposer), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_DEPLOYER, true)
        );
        console.log("Set ConvexDeployer as operator on ConvexDaoProposer");

        ProposalMetadata convexProposalMetadata = new ProposalMetadata("Convex Proposal Metadata", address(core));
        console.log("ConvexProposalMetadata:", address(convexProposalMetadata));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "CONVEX", DAO_METADATA, address(convexProposalMetadata)
            )
        );
        console.log("Registered CONVEX -> DAO_METADATA");

        _setOperator(address(convexProposalMetadata), CONVEX_BOT);
        console.log("Set ConvexBot as operator on ConvexProposalMetadata");

        _setOperator(address(convexProposalMetadata), CONVEX_DEPLOYER);
        console.log("Set ConvexDeployer as operator on ConvexProposalMetadata");

        // ── 24. Set Proposer as Operator on Convex Platform ──
        core.execute(
            address(convexDaoVoting),
            abi.encodeWithSignature("setOperator(address,bool)", address(convexDaoProposer), true)
        );
        console.log("Set ConvexDaoProposer as operator on ConvexDaoVoting");

        // ── 25. Deploy Resupply DaoVoting ──
        DaoVotePlatform resupplyDaoVoting = new DaoVotePlatform(
            "Resupply Dao Voting", address(core), VLCVX, address(surrogateRegistry), address(daoDelegation)
        );
        console.log("ResupplyDaoVoting:", address(resupplyDaoVoting));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "RESUPPLY", VOTE_DAO, address(resupplyDaoVoting)
            )
        );
        console.log("Registered RESUPPLY -> VOTE_DAO");

        _setOperator(address(resupplyDaoVoting), MSIG);
        console.log("Set MSIG as operator on ResupplyDaoVoting");

        // ── 26. Deploy ResupplyVoteExecutor ──
        ResupplyVoteExecutor resupplyVoteExecutor = new ResupplyVoteExecutor(
            "Resupply Vote Executor", address(core), address(resupplyDaoVoting), DEFAULT_QUORUM
        );
        console.log("ResupplyVoteExecutor:", address(resupplyVoteExecutor));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "RESUPPLY", DAO_EXECUTOR, address(resupplyVoteExecutor)
            )
        );
        console.log("Registered RESUPPLY -> DAO_EXECUTOR");

        _setGuardian(address(resupplyVoteExecutor), MSIG);
        console.log("Set MSIG as guardian on ResupplyVoteExecutor");

        // ── 27. Deploy ResupplyDaoProposer ──
        ResupplyDaoProposer resupplyDaoProposer =
            new ResupplyDaoProposer("Resupply Dao Proposer", address(core), address(resupplyDaoVoting));
        console.log("ResupplyDaoProposer:", address(resupplyDaoProposer));

        core.execute(
            address(registry),
            abi.encodeWithSignature(
                "setVotingContract(string,uint8,address)", "RESUPPLY", DAO_PROPOSER, address(resupplyDaoProposer)
            )
        );
        console.log("Registered RESUPPLY -> DAO_PROPOSER");

        _setOperator(address(resupplyDaoVoting), address(resupplyDaoProposer));
        console.log("Set ResupplyDaoProposer as operator on ResupplyDaoVoting");

        // ── 28. Register Convex Gauges ──
        string memory curveGaugeJson = vm.readFile("data/curve_gauge_ids.json");
        uint256[] memory allGauges = curveGaugeJson.readUintArray(".ids");
        console.log("Curve gauge id count", allGauges.length);
        uint256 batchSize = 50;
        uint256 total = allGauges.length;
        for (uint256 i = 0; i < total; i += batchSize) {
            uint256 end = i + batchSize;
            if (end > total) end = total;
            uint256[] memory batch = new uint256[](end - i);
            for (uint256 j = 0; j < end - i;) {
                batch[j] = allGauges[i + j];
                unchecked {
                    ++j;
                }
            }
            curveGaugeRegistry.setGauges(batch);
            console.log("Registered gauge batch", (i / batchSize) + 1);
        }

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
        console.log("FxProposalMetadata:", address(fxProposalMetadata));
        console.log("FxGaugeProposer:", address(fxGaugeProposer));
        console.log("FxGaugeExecutor:", address(fxGaugeExecutor));
        console.log("FraxDaoVoting:", address(fraxDaoVoting));
        console.log("FraxDaoProposer:", address(fraxDaoProposer));
        console.log("FraxProposalMetadata:", address(fraxProposalMetadata));
        console.log("ConvexDaoVoting:", address(convexDaoVoting));
        console.log("ConvexDaoProposer:", address(convexDaoProposer));
        console.log("ConvexProposalMetadata:", address(convexProposalMetadata));
        console.log("ResupplyDaoVoting:", address(resupplyDaoVoting));
        console.log("ResupplyDaoProposer:", address(resupplyDaoProposer));
        console.log("ResupplyVoteExecutor:", address(resupplyVoteExecutor));
        console.log("GaugeVoteHelper:", address(curveGaugeHelper));

        vm.serializeAddress("deploy", "ConvexCore", address(core));
        vm.serializeAddress("deploy", "VotingRegistry", address(registry));
        vm.serializeAddress("deploy", "CurveDaoVoting", address(curveDaoVoting));
        vm.serializeAddress("deploy", "CurveGaugeVoting", address(curveGaugeVoting));
        vm.serializeAddress("deploy", "CurveGaugeRegistry", address(curveGaugeRegistry));
        vm.serializeAddress("deploy", "CurveVoteExecutor", address(curveVoteExecutor));
        vm.serializeAddress("deploy", "CurveGaugeExecutor", address(curveGaugeExecutor));
        vm.serializeAddress("deploy", "CurveDaoProposer", address(curveDaoProposer));
        vm.serializeAddress("deploy", "CurveGaugeProposer", address(curveGaugeProposer));
        vm.serializeAddress("deploy", "GaugeVoteHelper", address(curveGaugeHelper));
        vm.serializeAddress("deploy", "FxGaugeRegistry", address(fxGaugeRegistry));
        vm.serializeAddress("deploy", "FxDaoVoting", address(fxDaoVoting));
        vm.serializeAddress("deploy", "FxGaugeVoting", address(fxGaugeVoting));
        vm.serializeAddress("deploy", "FxDaoProposer", address(fxDaoProposer));
        vm.serializeAddress("deploy", "FxProposalMetadata", address(fxProposalMetadata));
        vm.serializeAddress("deploy", "FxGaugeProposer", address(fxGaugeProposer));
        vm.serializeAddress("deploy", "FxGaugeExecutor", address(fxGaugeExecutor));
        vm.serializeAddress("deploy", "FraxDaoVoting", address(fraxDaoVoting));
        vm.serializeAddress("deploy", "FraxDaoProposer", address(fraxDaoProposer));
        vm.serializeAddress("deploy", "FraxProposalMetadata", address(fraxProposalMetadata));
        vm.serializeAddress("deploy", "ConvexDaoVoting", address(convexDaoVoting));
        vm.serializeAddress("deploy", "ConvexDaoProposer", address(convexDaoProposer));
        vm.serializeAddress("deploy", "ConvexProposalMetadata", address(convexProposalMetadata));
        vm.serializeAddress("deploy", "ResupplyDaoVoting", address(resupplyDaoVoting));
        vm.serializeAddress("deploy", "ResupplyDaoProposer", address(resupplyDaoProposer));
        vm.serializeAddress("deploy", "ResupplyVoteExecutor", address(resupplyVoteExecutor));
        vm.serializeAddress("deploy", "DaoDelegation", address(daoDelegation));
        vm.serializeAddress("deploy", "GaugeDelegation", address(gaugeDelegation));
        vm.serializeAddress("deploy", "SurrogateRegistry", address(surrogateRegistry));
        string memory finalJson = vm.serializeAddress("deploy", "VoteDelegateExtension", VOTE_DELEGATE);

        vm.createDir("deployment", true);
        vm.writeJson(finalJson, "deployment/mainnet.json");
    }
}
