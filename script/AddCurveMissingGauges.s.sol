// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "../src/CurveGaugeRegistry.sol";

contract AddCurveMissingGauges is Script {
    using stdJson for string;

    uint256 constant DEFAULT_BATCH_SIZE = 50;

    function _sliceUints(uint256[] memory _values, uint256 _start, uint256 _end)
        internal
        pure
        returns (uint256[] memory sliced)
    {
        sliced = new uint256[](_end - _start);
        for (uint256 i = 0; i < sliced.length;) {
            sliced[i] = _values[_start + i];
            unchecked {
                ++i;
            }
        }
    }

    function run() external {
        string memory deploymentJson = vm.readFile("deployment/mainnet.json");
        CurveGaugeRegistry registry = CurveGaugeRegistry(deploymentJson.readAddress(".CurveGaugeRegistry"));

        string memory gaugeJson = vm.readFile("data/curve_missing_valid_gauges.json");
        uint256[] memory gaugeIds = gaugeJson.readUintArray(".ids");
        address[] memory gauges = gaugeJson.readAddressArray(".addresses");
        uint256 expectedCount = gaugeJson.readUint(".missingValidGaugeCount");

        uint256 batchSize = vm.envOr("CURVE_GAUGE_BATCH_SIZE", DEFAULT_BATCH_SIZE);
        require(batchSize != 0, "zero batch size");
        require(gaugeIds.length == gauges.length, "gauge length mismatch");
        require(gaugeIds.length == expectedCount, "gauge count mismatch");

        vm.startBroadcast();

        uint256 start;
        uint256 batch;
        while (start < gaugeIds.length) {
            uint256 end = start + batchSize;
            if (end > gaugeIds.length) end = gaugeIds.length;

            registry.setGauges(_sliceUints(gaugeIds, start, end));

            console.log("Queued Curve gauge registry batch", batch + 1);
            console.log("Gauge id start", gaugeIds[start]);
            console.log("Gauge id end", gaugeIds[end - 1]);
            console.log("Gauge count", end - start);

            start = end;
            unchecked {
                ++batch;
            }
        }

        vm.stopBroadcast();

        console.log("Queued Curve gauge registry total batches", batch);
        console.log("Queued Curve gauge registry total gauges", start);
    }
}
