// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SystemControl} from "src/SystemControl.sol";

import {Initialize1Vault} from "script/Initialize1Vault.s.sol";

/** @dev cli for local testnet:  forge script script/StartLiquidityMining.s.sol --rpc-url tarp_testnet --broadcast --legacy
    @dev cli for Sepolia:        forge script script/StartLiquidityMining.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract StartLiquidityMining is Script {
    uint256 privateKey;

    SystemControl systemControl;
    Initialize1Vault initialize1Vault;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_DEPLOYER_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        systemControl = SystemControl(vm.envAddress("SYSTEM_CONTROL"));
        initialize1Vault = new Initialize1Vault();
        initialize1Vault.setUp();
    }

    function run() public {
        // Initialize vault if not already initialized
        initialize1Vault.run();

        vm.startBroadcast(privateKey);

        // Start liquidity mining if not already started
        if (systemControl.hashActiveVaults() == 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470) {
            uint48[] memory newVaults = new uint48[](1);
            uint8[] memory newTaxes = new uint8[](1);
            newVaults[0] = 1; // 1st vault
            newTaxes[0] = type(uint8).max;
            systemControl.updateVaultsIssuances(new uint48[](0), newVaults, newTaxes);
        }

        vm.stopBroadcast();
    }
}
