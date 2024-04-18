// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {Vault} from "src/Vault.sol";

contract Initialize1Vault is Script {
    Vault constant VAULT = Vault(0xCA87833e830652C2ab07E1e03eBa4F2c246D3b58);

    function setUp() public {}

    /** 
        1. Deploy Oracle.sol
        2. Deploy SystemControl.sol
        3. Deploy SIR.sol
        4. Deploy Vault.sol (and VaultExternal.sol) with addresses of SystemControl.sol, SIR.sol, and Oracle.sol
        5. Initialize SIR.sol with address of Vault.sol
        6. Initialize SystemControl.sol with addresses of Vault.sol and SIR.sol
    */
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy oracle
        VAULT.initialize(
            VaultStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDT,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: int8(-1)
            })
        );

        vm.stopBroadcast();
    }
}
