// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {AddressesMegaETHTest} from "src/libraries/AddressesMegaETHTest.sol";
import {AddressesMegaETH} from "src/libraries/AddressesMegaETH.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {Vault} from "src/Vault.sol";

/** @dev cli for MegaETH testnet: forge script script/InitializeVault.s.sol --rpc-url megatest --chain 6343 --broadcast
    @dev cli for MegaETH mainnet: forge script script/InitializeVault.s.sol --rpc-url megaeth --broadcast --ledger
*/
contract InitializeVault is Script {
    Vault vault;
    address collateralToken; // Set via environment or update for your vault
    address debtToken; // Set via environment or update for your vault

    function setUp() public {
        if (block.chainid != 6343) {
            revert("Only MegaETH testnet (chain 6343) is currently supported");
        }

        vault = Vault(vm.envAddress("VAULT"));
        collateralToken = vm.envAddress("COLLATERAL_TOKEN");
        debtToken = vm.envAddress("DEBT_TOKEN");
    }

    function run() public {
        if (block.chainid == 6343) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        } else {
            // MegaETH mainnet - use ledger
            vm.startBroadcast();
        }

        vault.initialize(SirStructs.VaultParameters(debtToken, collateralToken, -1));

        vm.stopBroadcast();
    }
}
