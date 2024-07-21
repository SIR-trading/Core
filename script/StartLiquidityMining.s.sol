// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SystemControl} from "src/SystemControl.sol";

contract StartLiquidityMining is Script {
    SystemControl systemControl;

    function setUp() public {
        systemControl = SystemControl(vm.envAddress("SYSTEM_CONTROL"));
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Start liquidity mining
        uint48[] memory newVaults = new uint48[](1);
        uint8[] memory newTaxes = new uint8[](1);
        newVaults[0] = 1;
        newTaxes[0] = type(uint8).max;

        systemControl.updateVaultsIssuances(new uint48[](0), newVaults, newTaxes);

        vm.stopBroadcast();
    }
}
