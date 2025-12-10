// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {AddressesMegaETHTest} from "src/libraries/AddressesMegaETHTest.sol";
import {AddressesMegaETH} from "src/libraries/AddressesMegaETH.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SIR} from "src/SIR.sol";

/** @dev cli for MegaETH testnet: forge script script/CollectWethFees.s.sol --rpc-url megatest --chain 6343 --broadcast
    @dev cli for MegaETH mainnet: forge script script/CollectWethFees.s.sol --rpc-url megaeth --broadcast --ledger
*/
contract CollectWethFees is Script {
    address weth;
    SIR sir;

    function setUp() public {
        if (block.chainid == 6343) {
            weth = AddressesMegaETHTest.ADDR_WETH;
        } else {
            weth = AddressesMegaETH.ADDR_WETH;
        }

        if (weth == address(0)) {
            revert("WETH address not configured for this chain");
        }

        sir = SIR(payable(vm.envAddress("SIR")));
    }

    function run() public {
        if (block.chainid == 6343) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        } else {
            // MegaETH mainnet - use ledger
            vm.startBroadcast();
        }

        // Collect WETH fees
        uint256 totalFees = sir.collectFeesAndStartAuction(weth);
        console.log("Total WETH fees collected:", totalFees);

        vm.stopBroadcast();
    }
}
