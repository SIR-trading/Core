// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Create2} from "openzeppelin-contracts/contracts/utils/Create2.sol";

/** 
  Init code hash: 0x7c75ff90a0c68974e3774ad926338939a8693a266f57198a74781f5cb06449b9
  Deployer: 0xce0042B868300000d44A59004Da54A005ffdcf9f
  Salt: 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e19c67e4b
  Address: 0x512000415AC7f9c1C4771eBf1C566Da7c42eB80d
 */

/// @notice Script to mine a CREATE2 salt for a single library contract
contract MineSaltVaultExternal is Script {
    uint256 constant DESIRED_PREFIX = 0x512000; // Desired prefix for the deployed address (0x512000)

    /// @dev The address that will deploy the library
    address constant DEPLOYER_ADDRESS = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    /// @dev Adjust as needed: maximum iterations to try
    uint256 constant MAX_ITERATIONS = 100_000_000;

    /// @dev Length of the desired prefix in nibbles (4 bits each)
    uint256 numNibbles = countNibbleLength(DESIRED_PREFIX);

    function run() external view {
        console.log("Starting salt mining for VaultExternal...");

        // 1. Load the fully linked creation bytecode
        bytes memory creationCode = vm.getCode("VaultExternal.sol:VaultExternal");

        // 2. Compute initCodeHash = keccak256(creationCode)
        bytes32 initCodeHash = keccak256(creationCode);
        console.log("Init code hash:", vm.toString(initCodeHash));

        // 3. Brute-force salts
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

            // compute the prospective CREATE2 address
            address predicted = Create2.computeAddress(salt, initCodeHash, DEPLOYER_ADDRESS);

            // check prefix using bitwise operations (no memory allocation)
            if (uint160(predicted) >> (160 - numNibbles * 4) == DESIRED_PREFIX) {
                // Only log when found to minimize memory usage
                console.log("Deployer:", DEPLOYER_ADDRESS);
                console.log("Salt:", vm.toString(salt));
                console.log("Address:", predicted);
                return;
            }
        }
        console.log("No salt found after", MAX_ITERATIONS, "iterations");
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
