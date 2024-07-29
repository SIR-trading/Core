// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
// import {SystemControl} from "src/SystemControl.sol";
import {SIR} from "src/SIR.sol";
import {Vault} from "src/Vault.sol";

import {StartLiquidityMining} from "script/StartLiquidityMining.s.sol";

/** @notice cli: forge script script/GetSIR.s.sol --rpc-url tarp_testnet --broadcast --skip-simulation
    @notice Script will deposit some SIR on the calling wallet address
    @notice tarp_testnet is the network RPC URL defined in foundry.toml
    @notice Environment variables
    @notice     TARP_TESTNET_PRIVATE_KEY is the private key of the calling wallet address
    @notice     VAULT is the address of the vault contract
    @notice     SIR is the address of the SIR contract
    @notice     SYSTEM_CONTROL is the address of the system control contract
 */
contract GetSIR is Script {
    Vault vault;
    SIR sir;
    IWETH9 weth = IWETH9(Addresses.ADDR_WETH);
    StartLiquidityMining startLiquidityMining;

    // SystemControl systemControl;

    function setUp() public {
        vault = Vault(vm.envAddress("VAULT"));
        sir = SIR(payable(vm.envAddress("SIR")));
        startLiquidityMining = new StartLiquidityMining();
        startLiquidityMining.setUp();
    }

    function run() public {
        // Start liquidity mining on the 1st vault
        startLiquidityMining.run();

        uint256 privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        vm.startBroadcast(privateKey);

        // If the caller owns no TEA, mint some
        uint256 balance = vault.balanceOf(vm.addr(privateKey), 1);
        if (balance == 0) {
            weth.deposit{value: 1 ether}(); // Wrap 1 ETH
            weth.transfer(address(vault), 1 ether); // Transfer 1 WETH to the vault

            SirStructs.VaultParameters memory vaultParams = vault.paramsById(1);
            vault.mint(false, vaultParams); // Mint TEA
        }

        // Time forward
        vm.warp(block.timestamp + 12); // Increase time by 12 second
        vm.roll(block.number + 1); // Mine a new block

        // Claim SIR
        uint256 sirRewards = sir.lPerMint(1);
        console.log(sirRewards, "/ 2^12 SIR sent to", vm.addr(privateKey));

        vm.stopBroadcast();
    }
}
