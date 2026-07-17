// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "../src/ConvexCore.sol";
import "../src/ProposalMetadata.sol";
import "../src/VotingRegistry.sol";

contract ReplaceProposalMetadata is Script {
    using stdJson for string;

    address constant CONVEX_DEPLOYER = 0x947B7742C403f20e5FaCcDAc5E092C943E7D0277;
    address constant CONVEX_BOT = 0x724061efDFef4a421e8be05133ad24922D07b5Bf;

    uint8 constant DAO_METADATA = 7;

    struct Replacement {
        ProposalMetadata fx;
        ProposalMetadata frax;
        ProposalMetadata convex;
    }

    ConvexCore core;
    VotingRegistry registry;

    function _register(string memory _platform, ProposalMetadata _metadata) internal {
        core.execute(
            address(registry),
            abi.encodeWithSignature("setVotingContract(string,uint8,address)", _platform, DAO_METADATA, address(_metadata))
        );
        core.execute(address(_metadata), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_BOT, true));
        core.execute(address(_metadata), abi.encodeWithSignature("setOperator(address,bool)", CONVEX_DEPLOYER, true));
    }

    function run() external {
        string memory deploymentJson = vm.readFile("deployment/mainnet.json");
        core = ConvexCore(deploymentJson.readAddress(".ConvexCore"));
        registry = VotingRegistry(deploymentJson.readAddress(".VotingRegistry"));

        address oldFxMetadata = deploymentJson.readAddress(".FxProposalMetadata");
        address oldFraxMetadata = deploymentJson.readAddress(".FraxProposalMetadata");
        address oldConvexMetadata = deploymentJson.readAddress(".ConvexProposalMetadata");

        vm.startBroadcast(CONVEX_DEPLOYER);

        Replacement memory replacement;
        replacement.fx = new ProposalMetadata("Fx Proposal Metadata", address(core));
        replacement.frax = new ProposalMetadata("Frax Proposal Metadata", address(core));
        replacement.convex = new ProposalMetadata("Convex Proposal Metadata", address(core));

        _register("FX", replacement.fx);
        _register("FRAX", replacement.frax);
        _register("CONVEX", replacement.convex);

        vm.stopBroadcast();

        console.log("FxProposalMetadata old:", oldFxMetadata);
        console.log("FxProposalMetadata new:", address(replacement.fx));
        console.log("FraxProposalMetadata old:", oldFraxMetadata);
        console.log("FraxProposalMetadata new:", address(replacement.frax));
        console.log("ConvexProposalMetadata old:", oldConvexMetadata);
        console.log("ConvexProposalMetadata new:", address(replacement.convex));

        vm.serializeAddress("metadata", "OldFxProposalMetadata", oldFxMetadata);
        vm.serializeAddress("metadata", "FxProposalMetadata", address(replacement.fx));
        vm.serializeAddress("metadata", "OldFraxProposalMetadata", oldFraxMetadata);
        vm.serializeAddress("metadata", "FraxProposalMetadata", address(replacement.frax));
        vm.serializeAddress("metadata", "OldConvexProposalMetadata", oldConvexMetadata);
        string memory finalJson =
            vm.serializeAddress("metadata", "ConvexProposalMetadata", address(replacement.convex));

        vm.createDir("deployment", true);
        vm.writeJson(finalJson, "deployment/proposal-metadata-replacement-mainnet.json");
        vm.writeJson(string.concat('"', vm.toString(address(replacement.fx)), '"'), "deployment/mainnet.json", ".FxProposalMetadata");
        vm.writeJson(
            string.concat('"', vm.toString(address(replacement.frax)), '"'),
            "deployment/mainnet.json",
            ".FraxProposalMetadata"
        );
        vm.writeJson(
            string.concat('"', vm.toString(address(replacement.convex)), '"'),
            "deployment/mainnet.json",
            ".ConvexProposalMetadata"
        );
    }
}
