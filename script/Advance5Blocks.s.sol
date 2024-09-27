// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
// import {SystemControl} from "src/SystemControl.sol";
import {SIR} from "src/SIR.sol";
import {Vault} from "src/Vault.sol";

import {StartLiquidityMining} from "script/StartLiquidityMining.s.sol";

/** @notice cli: forge script script/Advance5Blocks.s.sol --rpc-url tarp_testnet --broadcast
 */
contract Advance5Blocks is Script {
    uint256 privateKey;

    function setUp() public {
        privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
    }

    function run() public {
        vm.startBroadcast(privateKey);

        // Time forward
        vm.warp(block.timestamp + 12 seconds * 5); // Increase time by 12 second
        vm.roll(block.number + 5); // Mine a new block

        vm.stopBroadcast();
    }
}
