// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {MockERC20} from "src/test/MockERC20.sol";

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

    /** cli:
            export NAME="MockToken" SYMBOL="METH" DECIMALS="18" && forge script script/DeployMockToken.s.sol --rpc-url tarp_testnet --broadcast
     */
    function run() public {
        vm.startBroadcast(privateKey);
        address token = address(new MockERC20("MockToken", "MCK", 18));
        console.log(string.concat(name, " (", symbol, ") deployed at ", vm.toString(token)));
        vm.stopBroadcast();
    }
}
