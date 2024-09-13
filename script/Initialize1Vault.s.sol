// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {Vault} from "src/Vault.sol";

/** @dev cli for local testnet:  forge script script/Initialize1Vault.s.sol --rpc-url tarp_testnet --broadcast
    @dev cli for Sepolia:        forge script script/Initialize1Vault.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract Initialize1Vault is Script {
    uint256 deployerPrivateKey;

    Vault vault;
    SirStructs.VaultParameters vaultParams;

    function setUp() public {
        if (block.chainid == 1) {
            deployerPrivateKey = vm.envUint("TARP_TESTNET_DEPLOYER_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            deployerPrivateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        setVaultParams(
            SirStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDT,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: int8(-1)
            })
        );
    }

    function setVaultParams(SirStructs.VaultParameters memory vaultParams_) public {
        vault = Vault(vm.envAddress("VAULT"));
        vaultParams = vaultParams_;
    }

    function run() public {
        vm.startBroadcast(deployerPrivateKey);

        // Initialize vault if not already initialized
        SirStructs.VaultState memory vaultState = vault.vaultStates(vaultParams);
        if (vaultState.vaultId == 0) {
            vault.initialize(vaultParams);
        }

        vm.stopBroadcast();
    }
}
