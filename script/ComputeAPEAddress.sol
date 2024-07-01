// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {SaltedAddress} from "src/libraries/SaltedAddress.sol";
import {APE} from "src/APE.sol";

contract ComputeAddress is Script {
    address constant VAULT = 0x41219a0a9C0b86ED81933c788a6B63Dfef8f17eE;

    function setUp() public {}

    /** 
        1. Deploy Oracle.sol
        2. Deploy SystemControl.sol
        3. Deploy SIR.sol
        4. Deploy Vault.sol (and VaultExternal.sol) with addresses of SystemControl.sol, SIR.sol, and Oracle.sol
        5. Initialize SIR.sol with address of Vault.sol
        6. Initialize SystemControl.sol with addresses of Vault.sol and SIR.sol
    */
    function run() public view {
        console.log("Vauld address:", VAULT);
        console.log("Vauld ID: 1");
        console.log("APE address:", SaltedAddress.getAddress(VAULT, uint256(1)));
    }
}
