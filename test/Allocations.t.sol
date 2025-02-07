// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Contributors} from "src/libraries/Contributors.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

contract AllocationsTest is Test {
    using stdJson for string;

    address[] public allContributors;
    address treasury;

    uint256 public constant YEAR_ISSUANCE = 2_015_000_000 * 10 ** (SystemConstants.SIR_DECIMALS); // 2,015 M SIR per year

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
        treasury = vm.envAddress("TREASURY_ADDRESS");
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

    // Define JSON structure
    struct USDContributor {
        address addr;
        uint256 allocation; // Basis points from JSON
        uint256 contribution;
        string ens;
        uint256 lock_nfts;
    }

    // Define JSON structure
    struct SpiceContributor {
        address addr;
        uint256 allocation; // Basis points from JSON
    }

    mapping(address => uint256) allocations;

    // Check the allocations match
    function test_allocationsMatch() public {
        // Process USD Contributors - Use same method as in setUp()
        string memory usdJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/usd-contributors.json"));
        USDContributor[] memory usdContributors = abi.decode(
            usdJson.parseRaw(".contributors"), // Decode entire contributors array
            (USDContributor[])
        );

        for (uint256 i = 0; i < usdContributors.length; i++) {
            allocations[usdContributors[i].addr] += usdContributors[i].allocation;
        }

        // Process Spice Contributors - Use same method as in setUp()
        string memory spiceJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/spice-contributors.json"));
        SpiceContributor[] memory spiceContributors = abi.decode(
            spiceJson.parseRaw(""), // Decode root array
            (SpiceContributor[])
        );

        for (uint256 i = 0; i < spiceContributors.length; i++) {
            allocations[spiceContributors[i].addr] += spiceContributors[i].allocation;
        }

        // Add treasury
        allocations[treasury] += 100;

        // Validate allocations
        for (uint256 i = 0; i < allContributors.length; i++) {
            address addr = allContributors[i];
            uint256 actual = ((Contributors.getAllocation(addr) *
                uint256(SystemConstants.ISSUANCE - SystemConstants.LP_ISSUANCE_FIRST_3_YEARS)) / type(uint56).max) *
                365 days;

            uint256 expected = (allocations[addr] * YEAR_ISSUANCE) / 10000;

            assertApproxEqRel(actual, expected, 1e17, string.concat("Allocation mismatch for ", vm.toString(addr)));
        }
    }
}
