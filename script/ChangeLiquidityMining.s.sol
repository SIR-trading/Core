// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {AddressesMegaETHTest} from "src/libraries/AddressesMegaETHTest.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SystemControl} from "src/SystemControl.sol";

/** @dev cli for MegaETH testnet: forge script script/ChangeLiquidityMining.s.sol --rpc-url megatest --chain 6343 --broadcast
    @dev cli for MegaETH mainnet: forge script script/ChangeLiquidityMining.s.sol --rpc-url megaeth --broadcast --ledger
*/
contract ChangeLiquidityMining is Script {
    SystemControl systemControl;

    function setUp() public {
        if (block.chainid != 6343) {
            revert("Only MegaETH testnet (chain 6343) is currently supported");
        }

        systemControl = SystemControl(vm.envAddress("SYSTEM_CONTROL"));
    }

    function run() public {
        if (block.chainid == 6343) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        } else {
            // MegaETH mainnet - use ledger
            vm.startBroadcast();
        }

        uint48[] memory oldVaults = new uint48[](1);
        oldVaults[0] = 1;

        uint48[] memory newVaults = new uint48[](1);
        newVaults[0] = 2;

        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = 128;
        systemControl.updateVaultsIssuances(oldVaults, newVaults, newTaxes);

        vm.stopBroadcast();
    }
}
