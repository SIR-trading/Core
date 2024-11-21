// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {AddressesSepolia} from "src/libraries/AddressesSepolia.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SIR} from "src/SIR.sol";

import {Initialize1Vault} from "script/Initialize1Vault.s.sol";

/** @dev cli for local testnet:  forge script script/CollectWethFees.s.sol --rpc-url tarp_testnet --broadcast --legacy
    @dev cli for Sepolia:        forge script script/CollectWethFees.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract CollectWethFees is Script {
    uint256 privateKey;

    address weth;
    SIR sir;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_DEPLOYER_PRIVATE_KEY");
            weth = Addresses.ADDR_WETH;
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
            weth = AddressesSepolia.ADDR_WETH;
        } else {
            revert("Network not supported");
        }

        sir = SIR(payable(vm.envAddress("SIR")));
    }

    function run() public {
        vm.startBroadcast(privateKey);

        // Collect WETH fees
        uint256 totalFees = sir.collectFeesAndStartAuction(weth);
        console.log("Total WETH fees collected:", totalFees);

        vm.stopBroadcast();
    }
}
