// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {AddressesHyperEVMTest} from "src/libraries/AddressesHyperEVMTest.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SystemControl} from "src/SystemControl.sol";

/** @dev cli for HyperEVM testnet: forge script script/ChangeLiquidityMining.s.sol --rpc-url hypertest --chain 998 --broadcast
*/
contract ChangeLiquidityMining is Script {
    uint256 privateKey;

    SystemControl systemControl;

    function setUp() public {
        if (block.chainid == 998) {
            privateKey = vm.envUint("HYPERTEST_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Only HyperEVM testnet (chain 998) is supported");
        }

        systemControl = SystemControl(vm.envAddress("SYSTEM_CONTROL"));
    }

    function run() public {
        vm.startBroadcast(privateKey);

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
