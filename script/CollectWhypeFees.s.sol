// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {AddressesHyperEVMTest} from "src/libraries/AddressesHyperEVMTest.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SIR} from "src/SIR.sol";

/** @dev cli for HyperEVM testnet: forge script script/CollectWhypeFees.s.sol --rpc-url hypertest --chain 998 --broadcast
*/
contract CollectWhypeFees is Script {
    uint256 privateKey;

    address whype;
    SIR sir;

    function setUp() public {
        if (block.chainid == 998) {
            privateKey = vm.envUint("HYPERTEST_DEPLOYER_PRIVATE_KEY");
            whype = AddressesHyperEVMTest.ADDR_WHYPE;
        } else {
            revert("Only HyperEVM testnet (chain 998) is supported");
        }

        sir = SIR(payable(vm.envAddress("SIR")));
    }

    function run() public {
        vm.startBroadcast(privateKey);

        // Collect WHYPE fees
        uint256 totalFees = sir.collectFeesAndStartAuction(whype);
        console.log("Total WHYPE fees collected:", totalFees);

        vm.stopBroadcast();
    }
}
