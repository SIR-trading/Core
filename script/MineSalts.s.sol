// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {AddressesSepolia} from "src/libraries/AddressesSepolia.sol";
import {Oracle} from "src/Oracle.sol";
import {SystemControl} from "src/SystemControl.sol";
import {Contributors} from "src/Contributors.sol";
import {SIR} from "src/SIR.sol";
import {Vault} from "src/Vault.sol";
import {APE} from "src/APE.sol";

/**
 * @notice Script to mine CREATE2 salts for all contracts deployed in DeployCore script
 * @notice VERY IMPORTANT, manually replace all VaultExternal placeholder
 * in Vault's bytecode (__$…$__) with the VaultExternal's address (drop 0x).
 * @dev This script mines salts sequentially since some contracts depend on addresses of previously deployed contracts
 */

/**
  Oracle:
    Salt: 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e1972865b
    Address: 0x512000bDF1f6282ab9a17e2d64050b19bb8A77F9
    Init Code Hash: 0xf40b89211f5cc6fd975d51f9304f49f87413fdc7ca2554f19d3c5c5e91989f30

  SystemControl:
    Salt: 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e193e82e3
    Address: 0x512000A3497D312E0f33db3E214A225fe8C64a1F
    Init Code Hash: 0x77cff92c0b60a135c2debd319d0ce5dbbe4f439790fee7e648a7fc6053b6751c

  Contributors:
    Salt: 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e18dca819
    Address: 0x512000B12269e58722644F62f16b92AD84b9BD21
    Init Code Hash: 0x490a516af89b1533e9d9e161fe09bff53592f7c98da7a0473d741b9d86870013

  SIR:
    Salt: 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e18c34dec
    Address: 0x512000eA824a49C0316C5f4d287590fe31EA39fE
    Init Code Hash: 0x9de6ab24f36d38a02bb09339e6d285d85791766576464e385747836c75ba267b

  APE:
    Salt: 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e18d94220
    Address: 0x5120006F17517e81433eA4Ff8B161F8d2e65BCdE
    Init Code Hash: 0xef14a1c4ffbc25fe77357de229300be4c5f08118bbed7bbec9b17fe76cc8ac8f

  Vault:
    Salt: 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e190d204c
    Address: 0x5120008fAd9964fBf9D80Ed4b6D883154C95c3A3
    Init Code Hash: 0x0fdd824c5c03ccc63de3801379318c11ff7e81e410496b856f37350c0d96ed0f
 */
contract MineSalts is Script {
    uint256 constant DESIRED_PREFIX = 0x512000; // Desired prefix for all deployed addresses

    /// @dev Foundry's default test deployer address
    address constant DEPLOYER_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Maximum iterations to try for each contract
    uint256 constant MAX_ITERATIONS = 100_000_000;

    /// @dev Length of the desired prefix in nibbles (4 bits each)
    uint256 numNibbles = countNibbleLength(DESIRED_PREFIX);

    /// @dev Struct to store contract deployment info
    struct ContractInfo {
        string name;
        bytes32 salt;
        address predictedAddress;
        bytes32 initCodeHash;
    }

    function run() external view {
        console.log("Starting salt mining for all DeployCore contracts...");
        console.log("Deployer address:", DEPLOYER_ADDRESS);
        console.log("");

        // Mine salts in deployment order
        ContractInfo memory oracle = mineOracleSalt();
        ContractInfo memory systemControl = mineSystemControlSalt();
        ContractInfo memory contributors = mineContributorsSalt();
        ContractInfo memory sir = mineSIRSalt(contributors.predictedAddress, systemControl.predictedAddress);
        ContractInfo memory ape = mineAPESalt();
        ContractInfo memory vault = mineVaultSalt(
            systemControl.predictedAddress,
            sir.predictedAddress,
            oracle.predictedAddress,
            ape.predictedAddress
        );

        // Print summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        printContractInfo(oracle);
        printContractInfo(systemControl);
        printContractInfo(contributors);
        printContractInfo(sir);
        printContractInfo(ape);
        printContractInfo(vault);
    }

    function mineOracleSalt() internal view returns (ContractInfo memory info) {
        console.log("Mining salt for Oracle...");

        // Get creation bytecode with constructor parameters
        address uniswapFactory = block.chainid == 1
            ? Addresses.ADDR_UNISWAPV3_FACTORY
            : AddressesSepolia.ADDR_UNISWAPV3_FACTORY;

        // Get bytecode and compute initCodeHash correctly
        bytes memory initCode = abi.encodePacked(type(Oracle).creationCode, abi.encode(uniswapFactory));
        info.initCodeHash = keccak256(initCode);
        info.name = "Oracle";

        info.salt = mineSalt(info.initCodeHash);
        info.predictedAddress = computeCreate2Address(info.salt, info.initCodeHash, DEPLOYER_ADDRESS);

        console.log("Oracle salt found:", vm.toString(info.salt));
        console.log("Oracle address:", info.predictedAddress);
        console.log("");

        return info;
    }

    function mineSystemControlSalt() internal view returns (ContractInfo memory info) {
        console.log("Mining salt for SystemControl...");

        // SystemControl has no constructor parameters
        info.initCodeHash = keccak256(type(SystemControl).creationCode);
        info.name = "SystemControl";

        info.salt = mineSalt(info.initCodeHash);
        info.predictedAddress = computeCreate2Address(info.salt, info.initCodeHash, DEPLOYER_ADDRESS);

        console.log("SystemControl salt found:", vm.toString(info.salt));
        console.log("SystemControl address:", info.predictedAddress);
        console.log("");

        return info;
    }

    function mineContributorsSalt() internal view returns (ContractInfo memory info) {
        console.log("Mining salt for Contributors...");

        // Contributors has no constructor parameters
        info.initCodeHash = keccak256(type(Contributors).creationCode);
        info.name = "Contributors";

        info.salt = mineSalt(info.initCodeHash);
        info.predictedAddress = computeCreate2Address(info.salt, info.initCodeHash, DEPLOYER_ADDRESS);

        console.log("Contributors salt found:", vm.toString(info.salt));
        console.log("Contributors address:", info.predictedAddress);
        console.log("");

        return info;
    }

    function mineSIRSalt(address contributors, address systemControl) internal view returns (ContractInfo memory info) {
        console.log("Mining salt for SIR...");

        // SIR constructor parameters
        address wethAddress = block.chainid == 1 ? Addresses.ADDR_WETH : AddressesSepolia.ADDR_WETH;

        // Get bytecode and compute initCodeHash correctly
        bytes memory initCode = abi.encodePacked(
            type(SIR).creationCode,
            abi.encode(contributors, wethAddress, systemControl)
        );
        info.initCodeHash = keccak256(initCode);
        info.name = "SIR";

        info.salt = mineSalt(info.initCodeHash);
        info.predictedAddress = computeCreate2Address(info.salt, info.initCodeHash, DEPLOYER_ADDRESS);

        console.log("SIR salt found:", vm.toString(info.salt));
        console.log("SIR address:", info.predictedAddress);
        console.log("");

        return info;
    }

    function mineAPESalt() internal view returns (ContractInfo memory info) {
        console.log("Mining salt for APE...");

        // APE has no constructor parameters
        info.initCodeHash = keccak256(type(APE).creationCode);
        info.name = "APE";

        info.salt = mineSalt(info.initCodeHash);
        info.predictedAddress = computeCreate2Address(info.salt, info.initCodeHash, DEPLOYER_ADDRESS);

        console.log("APE salt found:", vm.toString(info.salt));
        console.log("APE address:", info.predictedAddress);
        console.log("");

        return info;
    }

    function mineVaultSalt(
        address systemControl,
        address sir,
        address oracle,
        address apeImplementation
    ) internal view returns (ContractInfo memory info) {
        console.log("Mining salt for Vault...");

        // Vault constructor parameters
        address wethAddress = block.chainid == 1 ? Addresses.ADDR_WETH : AddressesSepolia.ADDR_WETH;

        // Get bytecode and compute initCodeHash correctly
        bytes memory initCode = abi.encodePacked(
            type(Vault).creationCode,
            abi.encode(systemControl, sir, oracle, apeImplementation, wethAddress)
        );
        info.initCodeHash = keccak256(initCode);
        info.name = "Vault";

        info.salt = mineSalt(info.initCodeHash);
        info.predictedAddress = computeCreate2Address(info.salt, info.initCodeHash, DEPLOYER_ADDRESS);

        console.log("Vault salt found:", vm.toString(info.salt));
        console.log("Vault address:", info.predictedAddress);
        console.log("");

        return info;
    }

    function mineSalt(bytes32 initCodeHash) internal view returns (bytes32) {
        // Start with a random initial salt value
        uint256 baseSalt = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, block.number)));

        // Memory leak prevention - store initial free memory pointer
        bytes32 free_mem;
        assembly ("memory-safe") {
            free_mem := mload(0x40)
        }

        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            // Reset memory pointer to prevent memory leak
            assembly ("memory-safe") {
                mstore(0x40, free_mem)
            }

            // increment from the random starting point
            bytes32 salt = bytes32(baseSalt + i);

            // Compute CREATE2 address inline for efficiency
            bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER_ADDRESS, salt, initCodeHash));
            address predicted = address(uint160(uint256(hash)));

            // check prefix using bitwise operations (no memory allocation)
            if (uint160(predicted) >> (160 - numNibbles * 4) == DESIRED_PREFIX) {
                return salt;
            }
        }

        revert("No salt found after maximum iterations");
    }

    function printContractInfo(ContractInfo memory info) internal pure {
        console.log("%s:", info.name);
        console.log("  Salt: %s", vm.toString(info.salt));
        console.log("  Address: %s", info.predictedAddress);
        console.log("  Init Code Hash: %s", vm.toString(info.initCodeHash));
        console.log("");
    }

    function countNibbleLength(uint256 value) public pure returns (uint256 count) {
        // if value is zero, it has no digits
        if (value == 0) return 0;

        uint256 highestPosition = 0;
        uint256 temp = value;

        // Find the position of the highest non-zero digit
        while (temp != 0) {
            highestPosition++;
            temp >>= 4;
        }

        return highestPosition;
    }
}
