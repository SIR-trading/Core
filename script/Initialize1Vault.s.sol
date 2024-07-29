// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {Vault} from "src/Vault.sol";

contract Initialize1Vault is Script {
    Vault vault;
    SirStructs.VaultParameters vaultParams;

    function setUp() public {
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
        uint256 privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        vm.startBroadcast(privateKey);

        // Initialize vault if not already initialized
        SirStructs.VaultState memory vaultState = vault.vaultStates(vaultParams);
        if (vaultState.vaultId == 0) {
            vault.initialize(vaultParams);
        }

        vm.stopBroadcast();
    }
}
