// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {SystemControl} from "src/SystemControl.sol";

/** @dev cli for HyperEVM testnet: forge script script/StartLiquidityMining.s.sol --rpc-url hypertest --chain 998 --broadcast
*/
contract StartLiquidityMining is Script {
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

        // Start liquidity mining if not already started
        if (systemControl.hashActiveVaults() == 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470) {
            uint48[] memory newVaults = new uint48[](2);
            uint8[] memory newTaxes = new uint8[](2);
            newVaults[0] = 1; // 1st vault
            newVaults[1] = 2; // 2nd vault
            newTaxes[0] = 228;
            newTaxes[1] = 114;
            systemControl.updateVaultsIssuances(new uint48[](0), newVaults, newTaxes);
        }

        vm.stopBroadcast();
    }
}
