// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Contributors} from "src/libraries/Contributors.sol";
import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

contract AllocationsTest is Test {
    using stdJson for string;

    address[] public allContributors;

    function setUp() public {
        // Load spice contributors
        string memory spiceJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/spice-contributors.json"));
        address[] memory spiceAddresses = abi.decode(
            spiceJson.parseRaw("[*].address"), // Get all addresses from array
            (address[])
        );

        // Load USD contributors
        string memory usdJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/usd-contributors.json"));
        address[] memory usdAddresses = abi.decode(
            usdJson.parseRaw(".contributors[*].address"), // Path to addresses in USD data
            (address[])
        );

        // Combine and deduplicate
        _addUniqueAddresses(spiceAddresses);
        _addUniqueAddresses(usdAddresses);

        // Add treasury address directly from env
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address[] memory treasuryArray = new address[](1);
        treasuryArray[0] = treasury;
        _addUniqueAddresses(treasuryArray);
    }

    function _addUniqueAddresses(address[] memory addresses) internal {
        for (uint256 i = 0; i < addresses.length; i++) {
            address addr = addresses[i];
            bool exists = false;

            // Check if already exists (case-insensitive)
            for (uint256 j = 0; j < allContributors.length; j++) {
                if (addressMatches(addr, allContributors[j])) {
                    exists = true;
                    break;
                }
            }

            if (!exists) {
                allContributors.push(addr);
            }
        }
    }

    function addressMatches(address a, address b) internal pure returns (bool) {
        return uint160(a) == uint160(b);
    }

    // Test all allocations are greater than 0
    function test_allAddressesHaveAllocations() public view {
        for (uint256 i = 0; i < allContributors.length; i++) {
            uint56 allocation = Contributors.getAllocation(allContributors[i]);

            console.log("Address:", allContributors[i], ", allocation:", allocation);
            assertTrue(allocation > 0, "Address has zero allocation");
        }
    }

    // Test there are no weird addresses
    function test_noWeirdAddresses() public view {
        for (uint256 i = 0; i < allContributors.length; i++) {
            address addr = allContributors[i];

            address halfAddr = address(uint160(uint160(addr) & type(uint80).max));
            console.log("Address:", addr, ", right half:", halfAddr);
            assertTrue(halfAddr != address(0), "Address is half-zero");

            halfAddr = address(uint160(uint256(uint160(addr)) >> 80));
            console.log("Address:", addr, ", left half:", halfAddr);
            assertTrue(halfAddr != address(0), "Address is half-zero");
        }
    }

    // Check the sum of all allocations is type(uint56).max
    function test_totalAllocationsIsTypeMax() public view {
        uint256 totalAllocations = 0;

        for (uint256 i = 0; i < allContributors.length; i++) {
            uint56 allocation = Contributors.getAllocation(allContributors[i]);
            totalAllocations += allocation;
        }

        assertEq(totalAllocations, type(uint56).max, "Total allocations is not type(uint56).max");
    }
}
