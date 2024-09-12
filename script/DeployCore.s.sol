// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {Oracle} from "src/Oracle.sol";
import {SystemControl} from "src/SystemControl.sol";
import {SIR} from "src/SIR.sol";
import {Vault} from "src/Vault.sol";
import {APE} from "src/APE.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";

/** @dev cli for local testnet:  forge script script/DeployCore.s.sol --rpc-url tarp_testnet --broadcast --legacy
    @dev cli for Sepolia:        forge script script/DeployCore.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
    @dev Steps:
        1. Deploy Oracle.sol
        2. Deploy SystemControl.sol
        3. Deploy SIR.sol
        4. Deploy Vault.sol (and VaultExternal.sol) with addresses of SystemControl.sol, SIR.sol, and Oracle.sol
        5. Initialize SIR.sol with address of Vault.sol
        6. Initialize SystemControl.sol with addresses of Vault.sol and SIR.sol
*/
contract DeployCore is Script {
    string network;
    uint256 deployerPrivateKey;

    function setUp() public {
        if (block.chainid == 1) {
            deployerPrivateKey = vm.envUint("TARP_TESTNET_DEPLOYER_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            deployerPrivateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }
    }

    function run() public {
        vm.startBroadcast(deployerPrivateKey);

        // Deploy oracle
        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));
        console.log("Oracle deployed at: ", oracle);

        // Deploy SystemControl
        address systemControl = address(new SystemControl());
        console.log("SystemControl deployed at: ", systemControl);

        // Deploy SIR
        address payable sir = payable(address(new SIR(Addresses.ADDR_WETH)));
        console.log("SIR deployed at: ", sir);

        // Deploy Vault
        address vault = address(new Vault(systemControl, sir, oracle));
        console.log("Vault deployed at: ", vault);

        // Initialize SIR
        SIR(sir).initialize(vault);
        console.log("SIR initialized.");

        // Initialize SystemControl
        SystemControl(systemControl).initialize(vault);
        console.log("SystemControl initialized.");

        console.log("Hash of APE's contract creation code:");
        console.logBytes32(keccak256(type(APE).creationCode));

        vm.stopBroadcast();
    }
}
