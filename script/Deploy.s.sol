// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/VotingRegistry.sol";
import "../src/Delegation.sol";
import "../src/SurrogateRegistry.sol";
import "../src/GaugeVotePlatform.sol";
import "../src/DaoVotePlatform.sol";
import "../src/CurveGaugeRegistry.sol";
import "../src/CurveGaugeExecutor.sol";
import "../src/CurveVoteExecutor.sol";

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

    function run() external {
        address owner = msg.sender;

        vm.startBroadcast();

        // ── 1. Deploy VotingRegistry ──
        VotingRegistry registry = new VotingRegistry(owner);
        console.log("VotingRegistry:", address(registry));

        // ── 2. Deploy Delegation (DAO votes) ──
        Delegation daoDelegation = new Delegation(VLCVX);
        console.log("Delegation (DAO):", address(daoDelegation));

        // ── 3. Deploy Delegation (Gauge votes) ──
        Delegation gaugeDelegation = new Delegation(VLCVX);
        console.log("Delegation (Gauge):", address(gaugeDelegation));

        // ── 4. Deploy SurrogateRegistry ──
        SurrogateRegistry surrogateRegistry = new SurrogateRegistry();
        console.log("SurrogateRegistry:", address(surrogateRegistry));

        // ── 5. Register DAO delegation ──
        registry.setVotingContract("DELEGATION", registry.VOTE_DAO(), address(daoDelegation));
        console.log("Registered DELEGATION -> DAO delegation");

        // ── 6. Register Gauge delegation ──
        registry.setVotingContract("DELEGATION", registry.VOTE_GAUGE(), address(gaugeDelegation));
        console.log("Registered DELEGATION -> Gauge delegation");

        // ── 7. Register SurrogateRegistry for DAO (type 0) ──
        registry.setVotingContract("SURROGATE", 0, address(surrogateRegistry));
        console.log("Registered SURROGATE -> type 0");

        // ── 8. Register SurrogateRegistry for Gauge (type 1) ──
        registry.setVotingContract("SURROGATE", 1, address(surrogateRegistry));
        console.log("Registered SURROGATE -> type 1");

        // ── 9. Deploy CurveGaugeRegistry ──
        CurveGaugeRegistry curveGaugeRegistry = new CurveGaugeRegistry();
        console.log("CurveGaugeRegistry:", address(curveGaugeRegistry));

        // ── 10. Register CurveGaugeRegistry ──
        registry.setVotingContract("CURVE", registry.GAUGE_REGISTRY(), address(curveGaugeRegistry));
        console.log("Registered CURVE -> GAUGE_REGISTRY");

        // ── 11. Deploy DaoVotePlatform ──
        DaoVotePlatform daoVotePlatform = new DaoVotePlatform(
            owner,
            VLCVX,
            address(surrogateRegistry),
            address(daoDelegation)
        );
        console.log("DaoVotePlatform:", address(daoVotePlatform));

        // ── 12. Register DaoVotePlatform ──
        registry.setVotingContract("CURVE", registry.VOTE_DAO(), address(daoVotePlatform));
        console.log("Registered CURVE -> VOTE_DAO");

        // ── 13. Deploy GaugeVotePlatform ──
        GaugeVotePlatform gaugeVotePlatform = new GaugeVotePlatform(
            owner,
            VLCVX,
            address(curveGaugeRegistry),
            address(surrogateRegistry),
            address(gaugeDelegation)
        );
        console.log("GaugeVotePlatform:", address(gaugeVotePlatform));

        // ── 14. Register GaugeVotePlatform ──
        registry.setVotingContract("CURVE", registry.VOTE_GAUGE(), address(gaugeVotePlatform));
        console.log("Registered CURVE -> VOTE_GAUGE");

        // ── 15. Deploy CurveVoteExecutor ──
        CurveVoteExecutor curveVoteExecutor = new CurveVoteExecutor(
            owner,
            address(daoVotePlatform),
            address(0), // voteDelegate - set later
            0           // quorumBps - set later
        );
        console.log("CurveVoteExecutor:", address(curveVoteExecutor));

        // ── 16. Register CurveVoteExecutor ──
        registry.setVotingContract("CURVE", registry.DAO_EXECUTOR(), address(curveVoteExecutor));
        console.log("Registered CURVE -> DAO_EXECUTOR");

        // ── 17. Deploy CurveGaugeExecutor ──
        CurveGaugeExecutor curveGaugeExecutor = new CurveGaugeExecutor(
            address(gaugeVotePlatform),
            address(0) // voteDelegate - set later
        );
        console.log("CurveGaugeExecutor:", address(curveGaugeExecutor));

        // ── 18. Register CurveGaugeExecutor ──
        registry.setVotingContract("CURVE", registry.GAUGE_EXECUTOR(), address(curveGaugeExecutor));
        console.log("Registered CURVE -> GAUGE_EXECUTOR");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("Owner:", owner);
        console.log("VotingRegistry:", address(registry));
        console.log("Delegation (DAO):", address(daoDelegation));
        console.log("Delegation (Gauge):", address(gaugeDelegation));
        console.log("SurrogateRegistry:", address(surrogateRegistry));
        console.log("CurveGaugeRegistry:", address(curveGaugeRegistry));
        console.log("DaoVotePlatform:", address(daoVotePlatform));
        console.log("GaugeVotePlatform:", address(gaugeVotePlatform));
        console.log("CurveVoteExecutor:", address(curveVoteExecutor));
        console.log("CurveGaugeExecutor:", address(curveGaugeExecutor));
    }
}
