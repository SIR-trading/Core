// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SIR} from "src/SIR.sol";
import {Vault} from "src/Vault.sol";

/** @notice cli: forge script script/DistributeDividends.s.sol --rpc-url tarp_testnet --broadcast
 */
contract DistributeDividends is Script {
    uint256 donatorPrivateKey;
    uint256 privateKey;

    Vault vault;
    SIR sir;

    function setUp() public {
        donatorPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");

        vault = Vault(vm.envAddress("VAULT"));
        sir = SIR(payable(vm.envAddress("SIR")));
    }

    function run() public {
        // Stake any SIR you own
        vm.startBroadcast(privateKey);
        uint80 unstakedSIR = uint80(sir.balanceOf(vm.addr(privateKey)));
        sir.stake(unstakedSIR);

        console.log("You have staked ", unstakedSIR, "/ 2^12 SIR");

        vm.stopBroadcast();

        // Donate 1 eth to the staker
        vm.broadcast(donatorPrivateKey);
        payable(sir).transfer(1 ether);

        // Trigger dividend distribution
        vm.startBroadcast(privateKey);
        sir.collectFeesAndStartAuction(Addresses.ADDR_WETH);

        // Number of dividends?
        uint96 dividends = sir.dividends(vm.addr(privateKey));
        console.log("You own ", dividends, "wei in dividends");

        vm.stopBroadcast();
    }
}
