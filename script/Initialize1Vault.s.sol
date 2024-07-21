// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {Vault} from "src/Vault.sol";

contract Initialize1Vault is Script {
    Vault vault;

    function setUp() public {
        vault = Vault(vm.envAddress("VAULT"));
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy oracle
        vault.initialize(
            SirStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDT,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: int8(-1)
            })
        );

        vm.stopBroadcast();
    }
}
