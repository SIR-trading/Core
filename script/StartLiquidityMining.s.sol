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

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_DEPLOYER_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        systemControl = SystemControl(vm.envAddress("SYSTEM_CONTROL"));
    }

    function run() public {
        vm.startBroadcast(privateKey);

        // Start liquidity mining if not already started
        if (systemControl.hashActiveVaults() == 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470) {
            uint48[] memory newVaults = new uint48[](2);
            uint8[] memory newTaxes = new uint8[](2);
            newVaults[0] = 1; // 1st vault
            newVaults[1] = 2; // 2nd vault
            newTaxes[0] = 128;
            newTaxes[1] = 220;
            systemControl.updateVaultsIssuances(new uint48[](0), newVaults, newTaxes);
        }

        vm.stopBroadcast();
    }
}
