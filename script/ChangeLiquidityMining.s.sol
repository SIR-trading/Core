// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SystemControl} from "src/SystemControl.sol";
import {Initialize1Vault} from "script/Initialize1Vault.s.sol";

/** @dev cli for local testnet:  forge script script/ChangeLiquidityMining.s.sol --rpc-url tarp_testnet --broadcast --legacy
    @dev cli for Sepolia:        forge script script/ChangeLiquidityMining.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract ChangeLiquidityMining is Script {
    uint256 privateKey;

    SystemControl systemControl;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_DEPLOYER_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        systemControl = SystemControl(vm.envAddress("SYSTEM_CONTROL"));
    }

    function run() public {
        vm.startBroadcast(privateKey);

        uint48[] memory oldVaults = new uint48[](2);
        oldVaults[0] = 1;
        oldVaults[1] = 2;

        uint48[] memory newVaults = new uint48[](1);
        newVaults[0] = 1;

        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = 128;
        systemControl.updateVaultsIssuances(oldVaults, newVaults, newTaxes);

        vm.stopBroadcast();
    }
}
