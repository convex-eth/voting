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
import "../src/CurveGaugeExecutor.sol";
import "../src/CurveVoteExecutor.sol";
import "../src/CurveDaoProposer.sol";
import "../src/CurveGaugeProposer.sol";

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

    function run() external {
        address deployer = msg.sender;
        address[] memory initialOperators = new address[](2);
        initialOperators[0] = deployer;
        initialOperators[1] = MSIG;

        vm.startBroadcast();

        // ── 1. Deploy ConvexCore ──
        ConvexCore core = new ConvexCore(initialOperators);
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
        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "DELEGATION", 0, address(daoDelegation)));
        console.log("Registered DELEGATION -> DAO (0)");

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "DELEGATION", 1, address(gaugeDelegation)));
        console.log("Registered DELEGATION -> Gauge (1)");

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "SURROGATE", 0, address(surrogateRegistry)));
        console.log("Registered SURROGATE -> 0");

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "SURROGATE", 1, address(surrogateRegistry)));
        console.log("Registered SURROGATE -> 1");

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "ConvexCore", 0, address(core)));
        console.log("Registered ConvexCore");

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "OWNER", 0, address(core)));
        console.log("Registered OWNER");

        // ── 6. Deploy CurveGaugeRegistry ──
        CurveGaugeRegistry curveGaugeRegistry = new CurveGaugeRegistry();
        console.log("CurveGaugeRegistry:", address(curveGaugeRegistry));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", 2, address(curveGaugeRegistry)));
        console.log("Registered CURVE -> GAUGE_REGISTRY (2)");

        // ── 7. Deploy CurveDaoVoting ──
        DaoVotePlatform curveDaoVoting = new DaoVotePlatform(
            address(core),
            VLCVX,
            address(surrogateRegistry),
            address(daoDelegation)
        );
        console.log("CurveDaoVoting:", address(curveDaoVoting));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", 0, address(curveDaoVoting)));
        console.log("Registered CURVE -> VOTE_DAO (0)");

        // ── 8. Deploy CurveGaugeVoting ──
        GaugeVotePlatform curveGaugeVoting = new GaugeVotePlatform(
            address(core),
            VLCVX,
            address(curveGaugeRegistry),
            address(surrogateRegistry),
            address(gaugeDelegation)
        );
        console.log("CurveGaugeVoting:", address(curveGaugeVoting));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", 1, address(curveGaugeVoting)));
        console.log("Registered CURVE -> VOTE_GAUGE (1)");

        // ── 9. Deploy Executors ──
        CurveVoteExecutor curveVoteExecutor = new CurveVoteExecutor(
            address(core),
            address(curveDaoVoting),
            address(0), // voteDelegate TBD
            0           // quorumBps TBD
        );
        console.log("CurveVoteExecutor:", address(curveVoteExecutor));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", 3, address(curveVoteExecutor)));
        console.log("Registered CURVE -> DAO_EXECUTOR (3)");

        CurveGaugeExecutor curveGaugeExecutor = new CurveGaugeExecutor(
            address(curveGaugeVoting),
            address(0) // voteDelegate TBD
        );
        console.log("CurveGaugeExecutor:", address(curveGaugeExecutor));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", 4, address(curveGaugeExecutor)));
        console.log("Registered CURVE -> GAUGE_EXECUTOR (4)");

        // ── 10. Deploy Proposers ──
        CurveDaoProposer curveDaoProposer = new CurveDaoProposer(
            address(core),
            address(curveDaoVoting)
        );
        console.log("CurveDaoProposer:", address(curveDaoProposer));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", 5, address(curveDaoProposer)));
        console.log("Registered CURVE -> DAO_PROPOSER (5)");

        CurveGaugeProposer curveGaugeProposer = new CurveGaugeProposer(
            address(core),
            VLCVX,
            address(curveGaugeVoting)
        );
        console.log("CurveGaugeProposer:", address(curveGaugeProposer));

        core.execute(address(registry), abi.encodeWithSignature("setVotingContract(string,uint8,address)", "CURVE", 6, address(curveGaugeProposer)));
        console.log("Registered CURVE -> GAUGE_PROPOSER (6)");

        // ── 11. Set Proposers as Operators on Platforms ──
        core.execute(address(curveDaoVoting), abi.encodeWithSignature("setOperator(address,bool)", address(curveDaoProposer), true));
        console.log("Set CurveDaoProposer as operator on CurveDaoVoting");

        core.execute(address(curveGaugeVoting), abi.encodeWithSignature("setOperator(address,bool)", address(curveGaugeProposer), true));
        console.log("Set CurveGaugeProposer as operator on CurveGaugeVoting");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("ConvexCore:", address(core));
        console.log("VotingRegistry:", address(registry));
        console.log("CurveDaoVoting:", address(curveDaoVoting));
        console.log("CurveGaugeVoting:", address(curveGaugeVoting));
        console.log("CurveDaoProposer:", address(curveDaoProposer));
        console.log("CurveGaugeProposer:", address(curveGaugeProposer));
    }
}