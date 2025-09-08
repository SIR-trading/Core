// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {AddressesHyperEVMTest} from "src/libraries/AddressesHyperEVMTest.sol";
import {AddressesHyperEVM} from "src/libraries/AddressesHyperEVM.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {Vault} from "src/Vault.sol";

/** @dev cli for HyperEVM testnet: forge script script/InitializeVault.s.sol --rpc-url hypertest --chain 998 --broadcast
    @dev cli for HyperEVM mainnet: forge script script/InitializeVault.s.sol --rpc-url hyperevm --chain 999 --broadcast --ledger
*/
contract InitializeVault is Script {
    Vault vault;

    function setUp() public {
        if (block.chainid != 998 && block.chainid != 999) {
            revert("Only HyperEVM testnet (chain 998) and mainnet (chain 999) are supported");
        }

        vault = Vault(vm.envAddress("VAULT"));
    }

    function run() public {
        if (block.chainid == 998) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        } else {
            // Chain 999 - use ledger
            vm.startBroadcast();
        }

        address usdc;
        address whype;
        
        if (block.chainid == 998) {
            usdc = AddressesHyperEVMTest.ADDR_USDC;
            whype = AddressesHyperEVMTest.ADDR_WHYPE;
        } else {
            usdc = AddressesHyperEVM.ADDR_USDT0;
            whype = AddressesHyperEVM.ADDR_WHYPE;
        }

        vault.initialize(
            SirStructs.VaultParameters(usdc, whype, 2)
        );

        vm.stopBroadcast();
    }
}
