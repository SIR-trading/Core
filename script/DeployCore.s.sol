// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {Oracle} from "src/Oracle.sol";
import {SystemControl} from "src/SystemControl.sol";
import {SIR} from "src/SIR.sol";
import {Vault} from "src/Vault.sol";

contract DeploySIR is Script {
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
        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));
        console.log("Oracle deployed at: ", oracle);

        // Deploy SystemControl
        address systemControl = address(new SystemControl());
        console.log("SystemControl deployed at: ", systemControl);

        // Deploy SIR
        address sir = address(new SIR(Addresses.ADDR_WETH));
        console.log("SIR deployed at: ", sir);

        // Deploy Vault
        address vault = address(new Vault(systemControl, sir, oracle));
        console.log("Vault deployed at: ", vault);

        // Initialize SIR
        SIR(sir).initialize(vault);
        console.log("SIR initialized.");

        // Initialize SystemControl
        SystemControl(systemControl).initialize(vault, sir);
        console.log("SystemControl initialized.");

        vm.stopBroadcast();
    }
}
