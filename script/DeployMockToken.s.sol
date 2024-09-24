// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {SepoliaERC20} from "src/test/SepoliaERC20.sol";

/** @dev cli for env variables: export NAME="MockToken" SYMBOL="METH" DECIMALS="18"
    @dev cli for local testnet:   forge script script/DeployMockToken.s.sol --rpc-url tarp_testnet --broadcast--legacy
    @dev cli for Sepolia:        forge script script/DeployMockToken.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract DeployMockToken is Script {
    uint256 privateKey;

    string name;
    string symbol;
    uint8 decimals;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        name = vm.envString("NAME");
        symbol = vm.envString("SYMBOL");
        decimals = uint8(vm.envUint("DECIMALS"));
    }

    function run() public {
        vm.startBroadcast(privateKey);

        // Deploy the token
        address token = address(new SepoliaERC20(name, symbol, decimals));
        console.log(string.concat(name, " (", symbol, ") deployed at ", vm.toString(token)));

        vm.stopBroadcast();
    }
}
