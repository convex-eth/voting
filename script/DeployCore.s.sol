// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/ConvexCore.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
}

contract DeployCore is Script {
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    address constant MSIG = 0xa3C5A1e09150B75ff251c1a7815A07182c3de2FB;
    address constant CONVEX_DEPLOYER = 0x947B7742C403f20e5FaCcDAc5E092C943E7D0277;
    bytes32 constant DEFAULT_CORE_SALT_ENTROPY = bytes32(uint256(0x6e35b));

    function run() external {
        if (CREATEX.code.length == 0) revert("CreateX not deployed");

        address[] memory initialOperators = new address[](2);
        initialOperators[0] = CONVEX_DEPLOYER;
        initialOperators[1] = MSIG;

        bytes32 salt = _guardedSalt(CONVEX_DEPLOYER, vm.envOr("CORE_SALT", DEFAULT_CORE_SALT_ENTROPY));
        bytes memory initCode = abi.encodePacked(type(ConvexCore).creationCode, abi.encode(initialOperators));

        vm.startBroadcast(CONVEX_DEPLOYER);
        address core = ICreateX(CREATEX).deployCreate3(salt, initCode);
        vm.stopBroadcast();

        console.log("ConvexCore:", core);
        console.log("CreateX salt:");
        console.logBytes32(salt);
    }

    function _guardedSalt(address deployer, bytes32 entropy) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(deployer)) << 96) | uint88(uint256(entropy)));
    }
}
