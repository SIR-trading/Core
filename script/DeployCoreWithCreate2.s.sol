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

/** @dev cli for Sepolia:        forge script DeployCoreWithCreate2 --rpc-url sepolia --chain sepolia --broadcast
    @dev cli for mainnet:        forge script DeployCoreWithCreate2 --rpc-url mainnet --chain 1 --broadcast --verify --slow --etherscan-api-key YOUR_KEY --ledger --hd-paths PATHS
    @dev Mine salts first:       node script/mineSalts.js
    @dev Steps:
        1. Deploy Oracle.sol using CREATE2
        2. Deploy SystemControl.sol using CREATE2
        3. Deploy Contributors.sol using CREATE2
        4. Deploy SIR.sol using CREATE2 with addresses of Contributors, WETH, and SystemControl
        5. Deploy APE.sol implementation using CREATE2
        6. Deploy Vault.sol using CREATE2 with addresses of SystemControl, SIR, Oracle, APE, and WETH
        7. Initialize SIR.sol with address of Vault.sol
        8. Initialize SystemControl.sol with addresses of Vault.sol and SIR.sol
*/
contract DeployCoreWithCreate2 is Script {
    uint256 deployerPrivateKey;

    // Pre-mined salts for CREATE2 deployment
    bytes32 constant ORACLE_SALT = 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e1972865b;
    bytes32 constant SYSTEM_CONTROL_SALT = 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e193e82e3;
    bytes32 constant CONTRIBUTORS_SALT = 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e18dca819;
    bytes32 constant SIR_SALT = 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e18c34dec;
    bytes32 constant APE_SALT = 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e18d94220;
    bytes32 constant VAULT_SALT = 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e190d204c;

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

        console.log("Deploying contracts using CREATE2...");
        console.log("Deployer address:", msg.sender);

        _deployContracts();
        _printSaltSummary();

        vm.stopBroadcast();
    }

    function _deployContracts() internal {
        // Get network-specific addresses
        address wethAddress = block.chainid == 1 ? Addresses.ADDR_WETH : AddressesSepolia.ADDR_WETH;
        address uniswapFactory = block.chainid == 1
            ? Addresses.ADDR_UNISWAPV3_FACTORY
            : AddressesSepolia.ADDR_UNISWAPV3_FACTORY;

        // Deploy and verify Oracle
        address oracle = _deployOracle(uniswapFactory);

        // Deploy and verify SystemControl
        address systemControl = _deploySystemControl();

        // Deploy and verify Contributors
        address contributors = _deployContributors();

        // Deploy and verify SIR
        address payable sir = _deploySir(contributors, wethAddress, systemControl);

        // Deploy and verify APE
        address apeImplementation = _deployApe();

        // Deploy and verify Vault
        address vault = _deployVault(systemControl, sir, oracle, apeImplementation, wethAddress);

        // Initialize contracts
        SIR(sir).initialize(vault);
        console.log("SIR initialized.");

        SystemControl(systemControl).initialize(vault, sir);
        console.log("SystemControl initialized.");

        console.log("");
        console.log("All contracts deployed successfully using CREATE2!");
    }

    function _deployOracle(address uniswapFactory) internal returns (address) {
        Oracle deployed = new Oracle{salt: ORACLE_SALT}(uniswapFactory);
        console.log("Oracle deployed at:", address(deployed));
        return address(deployed);
    }

    function _deploySystemControl() internal returns (address) {
        SystemControl deployed = new SystemControl{salt: SYSTEM_CONTROL_SALT}();
        console.log("SystemControl deployed at:", address(deployed));
        return address(deployed);
    }

    function _deployContributors() internal returns (address) {
        Contributors deployed = new Contributors{salt: CONTRIBUTORS_SALT}();
        console.log("Contributors deployed at:", address(deployed));
        return address(deployed);
    }

    function _deploySir(
        address contributors,
        address wethAddress,
        address systemControl
    ) internal returns (address payable) {
        SIR deployed = new SIR{salt: SIR_SALT}(contributors, wethAddress, systemControl);
        console.log("SIR deployed at:", address(deployed));
        return payable(address(deployed));
    }

    function _deployApe() internal returns (address) {
        APE deployed = new APE{salt: APE_SALT}();
        console.log("APE implementation deployed at:", address(deployed));
        return address(deployed);
    }

    function _deployVault(
        address systemControl,
        address sir,
        address oracle,
        address apeImplementation,
        address wethAddress
    ) internal returns (address) {
        Vault deployed = new Vault{salt: VAULT_SALT}(systemControl, sir, oracle, apeImplementation, wethAddress);
        console.log("Vault deployed at:", address(deployed));
        return address(deployed);
    }

    function _printSaltSummary() internal view {
        console.log("");
        console.log("=== SALT SUMMARY ===");
        console.log("ORACLE_SALT:", vm.toString(ORACLE_SALT));
        console.log("SYSTEM_CONTROL_SALT:", vm.toString(SYSTEM_CONTROL_SALT));
        console.log("CONTRIBUTORS_SALT:", vm.toString(CONTRIBUTORS_SALT));
        console.log("SIR_SALT:", vm.toString(SIR_SALT));
        console.log("APE_SALT:", vm.toString(APE_SALT));
        console.log("VAULT_SALT:", vm.toString(VAULT_SALT));
    }
}
