// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {MockERC20} from "src/test/MockERC20.sol";

/** @notice cli:
    export NAME="MockToken" SYMBOL="METH" DECIMALS="18" && forge script script/DeployMockToken.s.sol --rpc-url tarp_testnet --broadcast
*/
contract DeployMockToken is Script {
    uint256 privateKey;

    string name;
    string symbol;
    uint8 decimals;

    function setUp() public {
        privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");

        name = vm.envString("NAME");
        symbol = vm.envString("SYMBOL");
        decimals = uint8(vm.envUint("DECIMALS"));
    }

    function run() public {
        vm.startBroadcast(privateKey);

        // Deploy the token
        address token = address(new MockERC20(name, symbol, decimals));
        console.log(string.concat(name, " (", symbol, ") deployed at ", vm.toString(token)));

        // Mint 1M tokens to the deployer
        MockERC20(token).mint(1e6 * 10 ** decimals);

        vm.stopBroadcast();
    }
}
