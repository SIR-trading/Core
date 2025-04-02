// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {AddressesSepolia} from "src/libraries/AddressesSepolia.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {Vault} from "src/Vault.sol";

/** @dev cli for local testnet:  forge script script/InitializeVault.s.sol --rpc-url tarp_testnet --broadcast --legacy
    @dev cli for Sepolia:        forge script script/InitializeVault.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract InitializeVault is Script {
    uint256 privateKey;

    Vault vault;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_DEPLOYER_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        vault = Vault(vm.envAddress("VAULT"));
    }

    function run() public {
        if (block.chainid == 1) vm.startBroadcast();
        else vm.startBroadcast(privateKey);

        vault.initialize(
            block.chainid == 1
                ? SirStructs.VaultParameters(Addresses.ADDR_USDC, Addresses.ADDR_WETH, -1)
                : SirStructs.VaultParameters(AddressesSepolia.ADDR_USDC, AddressesSepolia.ADDR_WETH, -1)
        );

        vm.stopBroadcast();
    }
}
