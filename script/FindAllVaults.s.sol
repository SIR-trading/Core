// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
// import "forge-std/console.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {Vault} from "src/Vault.sol";

/** @dev cli for local testnet:  forge script script/FindAllVaults.s.sol --rpc-url tarp_testnet --broadcast --legacy
    @dev cli for Sepolia:        forge script script/FindAllVaults.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract FindAllVaults is Script {
    uint256 privateKey;

    Vault vault;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        vault = Vault(vm.envAddress("VAULT"));
    }

    function run() public {
        vm.startBroadcast(privateKey);

        console.log("Vault bytecode length:", address(vault).code.length);

        uint256 Nvaults = vault.numberOfVaults();
        console.log("Number of vaults: ", Nvaults);

        // Check 1st vault
        for (uint48 i = 1; i <= Nvaults; i++) {
            console.log("------ Vault ID: ", i, " ------");
            SirStructs.VaultParameters memory vaultParams = vault.paramsById(i);
            console.log("debtToken: ", vaultParams.debtToken);
            console.log("collateralToken: ", vaultParams.collateralToken);
            console.log("leverageTier: ", vm.toString(vaultParams.leverageTier));
        }

        vm.stopBroadcast();
    }
}
