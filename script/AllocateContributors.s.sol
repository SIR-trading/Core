// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import {Contributors} from "src/Contributors.sol";

/**
 * @title AllocateContributors
 * @notice Allocates contributors from allocations-deploy.json to an existing Contributors contract
 * @dev cli for MegaETH testnet:
        forge script script/AllocateContributors.s.sol --rpc-url megatest --broadcast --private-key $PRIVATE_KEY \
        --skip-simulation --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 --slow
 */
contract AllocateContributors is Script {
    // Set this to the deployed Contributors contract address
    address constant CONTRIBUTORS = 0x99033401338A06aA619eB76D8761b155c99244Cf;

    uint256 constant BATCH_SIZE = 5000;

    function setUp() public view {
        require(CONTRIBUTORS != address(0), "Set CONTRIBUTORS address before running");
    }

    function run() public {
        // Read the compact deployment JSON with parallel arrays
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/allocations/allocations-deploy.json"));

        // Parse arrays directly - much more memory efficient
        address[] memory addresses = vm.parseJsonAddressArray(json, ".addresses");
        uint256[] memory amounts = vm.parseJsonUintArray(json, ".amounts");

        uint256 totalAddresses = addresses.length;
        console.log("Total addresses to allocate:", totalAddresses);

        vm.startBroadcast();

        // Process in batches
        uint256 numBatches = (totalAddresses + BATCH_SIZE - 1) / BATCH_SIZE;
        uint256 totalAllocations = 0;

        for (uint256 batchIndex = 0; batchIndex < numBatches; batchIndex++) {
            uint256 startIdx = batchIndex * BATCH_SIZE;
            uint256 endIdx = startIdx + BATCH_SIZE;
            if (endIdx > totalAddresses) {
                endIdx = totalAddresses;
            }
            uint256 batchLength = endIdx - startIdx;

            // Create batch arrays
            address[] memory batchAddresses = new address[](batchLength);
            uint16[] memory batchAmounts = new uint16[](batchLength);
            uint256 batchAlloc = 0;

            for (uint256 i = 0; i < batchLength; i++) {
                batchAddresses[i] = addresses[startIdx + i];
                batchAmounts[i] = uint16(amounts[startIdx + i]);
                batchAlloc += batchAmounts[i];
            }

            // Call allocate for this batch
            Contributors(CONTRIBUTORS).allocate(batchAddresses, batchAmounts);
            totalAllocations += batchAlloc;
            console.log("Allocated batch", batchIndex + 1, "of", numBatches);
        }

        vm.stopBroadcast();

        // Verify
        console.log("Total addresses allocated:", totalAddresses);
        console.log("Total allocations sum:", totalAllocations);
        uint16 remaining = Contributors(CONTRIBUTORS).remainingAllocation();
        console.log("Remaining allocation:", remaining);

        require(remaining == 0, "Remaining allocation must be 0");
        require(totalAllocations == uint256(type(uint16).max), "Total allocations must equal type(uint16).max");
        console.log("All allocations completed successfully!");
    }
}
