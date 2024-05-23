// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
// import "forge-std/console.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {Vault} from "src/Vault.sol";

contract Initialize1Vault is Script {
    Vault constant VAULT = Vault(0x9Bb65b12162a51413272d10399282E730822Df44);

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("Vault bytecode length:", address(VAULT).code.length);
        console.log("Number of vaults: ", VAULT.numberOfVaults());

        // // Check 1st vault
        // (address debtToken, address collateralToken, int8 leverageTier) = VAULT.paramsById(0);
        // console.log("debtToken: ", debtToken);
        // console.log("collateralToken: ", collateralToken);
        // console.log("leverageTier: ", vm.toString(leverageTier));

        vm.stopBroadcast();
    }
}
