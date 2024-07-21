// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {SaltedAddress} from "src/libraries/SaltedAddress.sol";
import {APE} from "src/APE.sol";

contract ComputeAddress is Script {
    address vault;

    function setUp() public {
        vault = vm.envAddress("VAULT");
    }

    function run() public view {
        console.log("Vauld address:", vault);
        console.log("Vauld ID: 1");
        console.log("APE address:", SaltedAddress.getAddress(vault, uint256(1)));
    }
}
