// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
// import "forge-std/console.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {Vault} from "src/Vault.sol";

contract FindAllVaults is Script {
    Vault constant VAULT = Vault(0x41219a0a9C0b86ED81933c788a6B63Dfef8f17eE);

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("Vault bytecode length:", address(VAULT).code.length);

        uint256 Nvaults = VAULT.numberOfVaults();
        console.log("Number of vaults: ", Nvaults);

        // Check 1st vault
        for (uint48 i = 1; i <= Nvaults; i++) {
            console.log("------ Vault ID: ", i, " ------");
            SirStructs.VaultParameters memory vaultParams = VAULT.paramsById(i);
            console.log("debtToken: ", vaultParams.debtToken);
            console.log("collateralToken: ", vaultParams.collateralToken);
            console.log("leverageTier: ", vm.toString(vaultParams.leverageTier));
        }

        vm.stopBroadcast();
    }
}
