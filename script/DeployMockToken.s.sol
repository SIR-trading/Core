// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {MockERC20} from "src/test/MockERC20.sol";

contract DeployMockToken is Script {
    uint256 privateKey;

    string name = "MockToken";
    string symbol = "METH";
    uint8 decimals = 18;

    function setUp() public {
        privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
    }

    /** cli: forge script script/DeployMockToken.s.sol --rpc-url tarp_testnet --broadcast --env-var NAME=MockToken --env-var SYMBOL=MCK --env-var DECIMALS=18
     */
    function run() public {
        vm.startBroadcast(privateKey);
        address token = address(new MockERC20("MockToken", "MCK", 18));
        console.log(string.concat(name, " (", symbol, ") deployed at ", vm.toString(token)));
        vm.stopBroadcast();
    }
}
