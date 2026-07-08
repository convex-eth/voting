// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "../src/ConvexCore.sol";

contract SeedDelegates is Script {
    using stdJson for string;

    address constant CONVEX_DEPLOYER = 0x947B7742C403f20e5FaCcDAc5E092C943E7D0277;
    address constant CONVEX_CORE = 0xCC07e8BA6bc8aeb18C4AE110C3Da9c7Dce4A3e74;

    uint256 constant DEFAULT_BATCH_SIZE = 50;

    ConvexCore core;

    function _sliceAddresses(address[] memory _addresses, uint256 _start, uint256 _end)
        internal
        pure
        returns (address[] memory sliced)
    {
        sliced = new address[](_end - _start);
        for (uint256 i = 0; i < sliced.length;) {
            sliced[i] = _addresses[_start + i];
            unchecked {
                ++i;
            }
        }
    }

    function run() external {
        if (CONVEX_CORE.code.length == 0) revert("ConvexCore not deployed");
        core = ConvexCore(CONVEX_CORE);

        string memory deploymentJson = vm.readFile("deployment/mainnet.json");
        address gaugeDelegation = deploymentJson.readAddress(".GaugeDelegation");

        string memory seedJson = vm.readFile("data/vlcvx_delegations_arrays.json");
        address[] memory seedUsers = seedJson.readAddressArray(".users");
        address[] memory seedDelegates = seedJson.readAddressArray(".delegates");

        uint256 batchSize = vm.envOr("SEED_BATCH_SIZE", DEFAULT_BATCH_SIZE);
        bool completeInitialization = vm.envOr("COMPLETE_INITIALIZATION", false);

        require(seedUsers.length == seedDelegates.length, "seed length mismatch");
        require(batchSize != 0, "zero batch size");

        vm.startBroadcast(CONVEX_DEPLOYER);

        // Always cover the full list; Delegation skips users already seeded, so reruns fill gaps.
        uint256 start;
        uint256 batch;
        while (start < seedUsers.length) {
            uint256 end = start + batchSize;
            if (end > seedUsers.length) end = seedUsers.length;

            address[] memory users = _sliceAddresses(seedUsers, start, end);
            address[] memory delegates = _sliceAddresses(seedDelegates, start, end);
            core.execute(gaugeDelegation, abi.encodeWithSignature("seedDelegates(address[],address[])", users, delegates));

            console.log("Seeded Gauge Delegation batch", batch + 1);
            console.log("Seed start", start);
            console.log("Seed count", users.length);

            start = end;
            unchecked {
                ++batch;
            }
        }

        if (completeInitialization) {
            core.execute(gaugeDelegation, abi.encodeWithSignature("completeInitialization()"));
            console.log("Completed Gauge Delegation initialization");
        }

        vm.stopBroadcast();

        console.log("Seeded Gauge Delegation total batches", batch);
        console.log("Seeded Gauge Delegation total users", start);
    }
}
