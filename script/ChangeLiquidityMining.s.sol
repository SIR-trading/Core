// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {AddressesHyperEVMTest} from "src/libraries/AddressesHyperEVMTest.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SystemControl} from "src/SystemControl.sol";

/** @dev cli for HyperEVM testnet: forge script script/ChangeLiquidityMining.s.sol --rpc-url hypertest --chain 998 --broadcast
    @dev cli for HyperEVM mainnet: forge script script/ChangeLiquidityMining.s.sol --rpc-url hyperevm --chain 999 --broadcast --ledger
*/
contract ChangeLiquidityMining is Script {
    SystemControl systemControl;

    function setUp() public {
        if (block.chainid != 998 && block.chainid != 999) {
            revert("Only HyperEVM testnet (chain 998) and mainnet (chain 999) are supported");
        }

        systemControl = SystemControl(vm.envAddress("SYSTEM_CONTROL"));
    }

    function run() public {
        if (block.chainid == 998) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        } else {
            // Chain 999 - use ledger
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
