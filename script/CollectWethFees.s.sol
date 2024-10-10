// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SIR} from "src/SIR.sol";

import {Initialize1Vault} from "script/Initialize1Vault.s.sol";

/** @dev cli for local testnet:  forge script script/CollectWethFees.s.sol --rpc-url tarp_testnet --broadcast --legacy
    @dev cli for Sepolia:        forge script script/CollectWethFees.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract CollectWethFees is Script {
    uint256 privateKey;

    SIR sir;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_DEPLOYER_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        sir = SIR(payable(vm.envAddress("SIR")));
    }

    function run() public {
        vm.startBroadcast(privateKey);

        // Collect WETH fees
        uint256 totalFees = sir.collectFeesAndStartAuction(Addresses.ADDR_WETH);
        console.log("Total WETH fees collected:", totalFees);

        vm.stopBroadcast();
    }
}
