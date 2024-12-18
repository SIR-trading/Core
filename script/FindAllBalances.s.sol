// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
// import "forge-std/console.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {Vault} from "src/Vault.sol";
import {SIR} from "src/SIR.sol";
import {IERC20} from "v2-core/interfaces/IERC20.sol";
import {AddressClone} from "src/libraries/AddressClone.sol";

/** @dev cli for local testnet:  forge script script/FindAllBalances.s.sol --rpc-url tarp_testnet --broadcast --legacy
    @dev cli for Sepolia:        forge script script/FindAllBalances.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract FindAllBalances is Script {
    uint256 privateKey;
    address queryAddress = 0x349DC3AcFb99ddACd3D00F1AEFC297eE8108Cb44;

    Vault vault;
    SIR sir;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        vault = Vault(vm.envAddress("VAULT"));
        sir = SIR(payable(vm.envAddress("SIR")));
    }

    function run() public {
        vm.startBroadcast(privateKey);

        console.log("---------------------------");
        console.log("Balance of unstaked SIR:", sir.balanceOf(queryAddress));
        console.log("Balance of unstaked SIR (human readable):", sir.balanceOf(queryAddress) / 10 ** sir.decimals());
        console.log("Balance of staked SIR:", sir.totalBalanceOf(queryAddress) - sir.balanceOf(queryAddress));
        console.log(
            "Balance of staked SIR (human readable):",
            (sir.totalBalanceOf(queryAddress) - sir.balanceOf(queryAddress)) / 10 ** sir.decimals()
        );

        // Check vaults
        uint256 Nvaults = vault.numberOfVaults();
        for (uint48 i = 1; i <= Nvaults; i++) {
            SirStructs.VaultParameters memory vaultParams = vault.paramsById(i);
            IERC20 collateral = IERC20(vaultParams.collateralToken);

            console.log("");
            console.log("---------------------------");
            console.log("Balance of TEA -", i, ":", vault.balanceOf(queryAddress, i));
            console.log(
                "Balance of TEA -",
                i,
                " (human readable):",
                vault.balanceOf(queryAddress, i) / 10 ** collateral.decimals()
            );
            IERC20 ape = IERC20(AddressClone.getAddress(address(vault), i));
            console.log("Balance of APE -", i, ":", ape.balanceOf(queryAddress));
            console.log("Balance of APE -", i, "(human readable):", ape.balanceOf(queryAddress) / 10 ** ape.decimals());
        }
    }
}
