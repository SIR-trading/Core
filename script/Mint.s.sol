// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {Vault} from "src/Vault.sol";

/** @dev cli: forge script script/Mint.s.sol --rpc-url tarp_testnet --broadcast
    @dev cli for Sepolia:        forge script script/Mint.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
 */
contract Mint is Script {
    uint256 privateKey;

    Vault vault;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_DEPLOYER_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        vault = Vault(vm.envAddress("VAULT"));
    }

    function run() public {
        vm.startBroadcast(privateKey);

        vault.mint(
            true,
            SirStructs.VaultParameters({
                debtToken: 0x7Aef48AdbFDc1262161e71Baf205b47316430067,
                collateralToken: 0x3ED05DE92879a5D47a3c8cc402DD5259219505aD,
                leverageTier: -1
            }),
            20e18,
            0
        );

        vm.stopBroadcast();
    }
}
