// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {Contributors} from "src/Contributors.sol";

/**
 * @title AllocationsHelper
 * @notice Helper contract for reading and allocating contributors from allocations.json
 * @dev Can be used in both scripts and tests to ensure consistent allocation behavior
 */
abstract contract AllocationsHelper is Script {
    uint256 constant BATCH_SIZE = 1000;

    /**
     * @notice Read allocations from JSON and allocate them to Contributors contract
     * @param contributorsContract The Contributors contract address
     * @return totalAddresses Total number of addresses allocated
     * @return totalAllocations Sum of all allocations
     */
    function readAndAllocate(
        address contributorsContract
    ) internal returns (uint256 totalAddresses, uint256 totalAllocations) {
        // Read the JSON file and extract addresses
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/allocations/allocations.json"));
        string[] memory allocationKeys = vm.parseJsonKeys(json, ".allocations");

        totalAddresses = allocationKeys.length;
        console.log("Total addresses to allocate:", totalAddresses);

        // Process in batches
        for (uint256 batchIndex = 0; batchIndex < (totalAddresses + BATCH_SIZE - 1) / BATCH_SIZE; batchIndex++) {
            (address[] memory addresses, uint16[] memory amounts, uint256 batchAlloc) = _prepareBatch(
                json,
                allocationKeys,
                batchIndex,
                totalAddresses
            );

            // Call allocate for this batch
            Contributors(contributorsContract).allocate(addresses, amounts);
            totalAllocations += batchAlloc;
            console.log("Allocated batch", batchIndex + 1, "of", (totalAddresses + BATCH_SIZE - 1) / BATCH_SIZE);
        }

        return (totalAddresses, totalAllocations);
    }

    function _prepareBatch(
        string memory json,
        string[] memory allocationKeys,
        uint256 batchIndex,
        uint256 totalAddresses
    ) private pure returns (address[] memory addresses, uint16[] memory amounts, uint256 batchAlloc) {
        uint256 startIdx = batchIndex * BATCH_SIZE;
        uint256 endIdx = startIdx + BATCH_SIZE;
        if (endIdx > totalAddresses) {
            endIdx = totalAddresses;
        }
        uint256 batchLength = endIdx - startIdx;

        addresses = new address[](batchLength);
        amounts = new uint16[](batchLength);

        for (uint256 i = 0; i < batchLength; i++) {
            string memory addrKey = allocationKeys[startIdx + i];
            addresses[i] = vm.parseAddress(addrKey);

            // Get the allocation amount for this address
            amounts[i] = uint16(vm.parseJsonUint(json, string.concat(".allocations.", addrKey, ".allocation")));
            batchAlloc += amounts[i];
        }

        return (addresses, amounts, batchAlloc);
    }
}
