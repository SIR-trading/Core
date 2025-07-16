// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {AddressesSepolia} from "src/libraries/AddressesSepolia.sol";
import {Oracle} from "src/Oracle.sol";
import {SystemControl} from "src/SystemControl.sol";
import {Contributors} from "src/Contributors.sol";
import {SIR} from "src/SIR.sol";
import {Vault} from "src/Vault.sol";
import {APE} from "src/APE.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";

/** @dev cli for local testnet:  forge script script/DeployCore.s.sol --rpc-url mainnet --chain 1 --broadcast --verify --slow --etherscan-api-key YOUR_KEY --ledger --hd-paths PATHS
    @dev cli for Sepolia:        forge script script/DeployCore.s.sol --rpc-url sepolia --chain sepolia --broadcast
    @dev Steps:
        1. Deploy Oracle.sol
        2. Deploy SystemControl.sol
        3. Deploy SIR.sol
        4. Deploy Vault.sol (and VaultExternal.sol) with addresses of SystemControl.sol, SIR.sol, and Oracle.sol
        5. Initialize SIR.sol with address of Vault.sol
        6. Initialize SystemControl.sol with addresses of Vault.sol and SIR.sol
*/
contract DeployCore is Script {
    uint256 deployerPrivateKey;

    function setUp() public {
        if (block.chainid == 11155111) {
            deployerPrivateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else if (block.chainid != 1) {
            revert("Network not supported");
        }
    }

    function run() public {
        if (block.chainid == 1) vm.startBroadcast();
        else vm.startBroadcast(deployerPrivateKey);

        // Deploy oracle
        address oracle = address(
            new Oracle(block.chainid == 1 ? Addresses.ADDR_UNISWAPV3_FACTORY : AddressesSepolia.ADDR_UNISWAPV3_FACTORY)
        );
        console.log("Oracle deployed at: ", oracle);

        // Deploy SystemControl
        address systemControl = address(new SystemControl(vm.addr(deployerPrivateKey)));
        console.log("SystemControl deployed at: ", systemControl);

        // Deploy Contributors
        address contributors = address(new Contributors());
        console.log("Contributors deployed at: ", contributors);

        // Deploy SIR
        address payable sir = payable(
            address(
                new SIR(
                    contributors,
                    (block.chainid == 1 ? Addresses.ADDR_WETH : AddressesSepolia.ADDR_WETH),
                    systemControl,
                    vm.addr(deployerPrivateKey) // DIFFERENT WHEN USING LEDGER!!! NEEDS FIX
                )
            )
        );
        console.log("SIR deployed at: ", sir);

        // Deploy APE implementation
        address apeImplementation = address(new APE());
        console.log("APE implementation deployed at: ", apeImplementation);

        // Deploy Vault
        address vault = address(
            new Vault(
                systemControl,
                sir,
                oracle,
                apeImplementation,
                block.chainid == 1 ? Addresses.ADDR_WETH : AddressesSepolia.ADDR_WETH
            )
        );
        console.log("Vault deployed at: ", vault);

        // Initialize SIR
        SIR(sir).initialize(vault, vm.addr(deployerPrivateKey));
        console.log("SIR initialized.");

        // Initialize SystemControl
        SystemControl(systemControl).initialize(vault, sir);
        console.log("SystemControl initialized.");

        vm.stopBroadcast();
    }
}
