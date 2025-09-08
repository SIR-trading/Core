// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {AddressesHyperEVMTest} from "src/libraries/AddressesHyperEVMTest.sol";
import {AddressesHyperEVM} from "src/libraries/AddressesHyperEVM.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SIR} from "src/SIR.sol";

/** @dev cli for HyperEVM testnet: forge script script/CollectWhypeFees.s.sol --rpc-url hypertest --chain 998 --broadcast
    @dev cli for HyperEVM mainnet: forge script script/CollectWhypeFees.s.sol --rpc-url hyperevm --chain 999 --broadcast --ledger
*/
contract CollectWhypeFees is Script {
    address whype;
    SIR sir;

    function setUp() public {
        if (block.chainid == 998) {
            whype = AddressesHyperEVMTest.ADDR_WHYPE;
        } else if (block.chainid == 999) {
            whype = AddressesHyperEVM.ADDR_WHYPE;
        } else {
            revert("Only HyperEVM testnet (chain 998) and mainnet (chain 999) are supported");
        }

        sir = SIR(payable(vm.envAddress("SIR")));
    }

    function run() public {
        if (block.chainid == 998) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        } else {
            // Chain 999 - use ledger
            vm.startBroadcast();
        }

        // Collect WHYPE fees
        uint256 totalFees = sir.collectFeesAndStartAuction(whype);
        console.log("Total WHYPE fees collected:", totalFees);

        vm.stopBroadcast();
    }
}
