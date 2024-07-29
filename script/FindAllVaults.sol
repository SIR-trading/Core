// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
// import "forge-std/console.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {Vault} from "src/Vault.sol";

contract FindAllVaults is Script {
    Vault vault;

    function setUp() public {
        vault = Vault(vm.envAddress("VAULT"));
    }

    function run() public {
        vm.startBroadcast();

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
