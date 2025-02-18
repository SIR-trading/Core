// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

// Libraries
import {Addresses} from "src/libraries/Addresses.sol";
import {Contributors} from "src/libraries/Contributors.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

// Contracts
import {Oracle} from "src/Oracle.sol";
import {SystemControl} from "src/SystemControl.sol";
import {SIR} from "src/SIR.sol";
import {APE} from "src/APE.sol";
import {Vault} from "src/Vault.sol";

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

contract AllocationsTest is Test {
    using stdJson for string;

    // Define JSON structure
    struct USDContributor {
        address addr;
        uint256 allocation; // Basis points from JSON
        uint256 allocationPrecision;
        uint256 contribution;
        string ens;
        uint256 lock_nfts;
    }

    // Define JSON structure
    struct SpiceContributor {
        address addr;
        uint256 allocation; // Basis points from JSON
    }

    mapping(address => uint256) allocationPrecision;
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

    // Check the allocations match
    function test_allocationsMatch() public {
        // Process USD Contributors - Use same method as in setUp()
        string memory usdJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/usd-contributors.json"));
        USDContributor[] memory usdContributors = abi.decode(
            usdJson.parseRaw(".contributors"), // Decode entire contributors array
            (USDContributor[])
        );

        for (uint256 i = 0; i < usdContributors.length; i++) {
            allocationPrecision[usdContributors[i].addr] += usdContributors[i].allocationPrecision;
        }

        // Process Spice Contributors - Use same method as in setUp()
        string memory spiceJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/spice-contributors.json"));
        SpiceContributor[] memory spiceContributors = abi.decode(
            spiceJson.parseRaw(""), // Decode root array
            (SpiceContributor[])
        );

        for (uint256 i = 0; i < spiceContributors.length; i++) {
            allocationPrecision[spiceContributors[i].addr] += spiceContributors[i].allocation * 1e15;
        }

        // Add treasury
        allocationPrecision[treasury] += 1000 * 1e15;

        // Validate allocations
        for (uint256 i = 0; i < allContributors.length; i++) {
            address addr = allContributors[i];
            uint256 actual = ((Contributors.getAllocation(addr) *
                uint256(SystemConstants.ISSUANCE - SystemConstants.LP_ISSUANCE_FIRST_3_YEARS)) / type(uint56).max) *
                365 days;

            uint256 expected = (allocationPrecision[addr] * YEAR_ISSUANCE) / 1e19;

            console.log(addr, actual, expected);
            assertApproxEqRel(actual, expected, 1e9, string.concat("Allocation mismatch for ", vm.toString(addr)));
        }
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
}

interface ITreasuryV1 {
    function relayCall(address to, bytes memory data) external returns (bytes memory);
}

contract TreasuryTest is Test {
    address constant OWNER = 0x5000Ff6Cc1864690d947B864B9FB0d603E8d1F1A;
    address constant TREASURY = 0x686748764c5C7Aa06FEc784E60D14b650bF79129;

    address payable sir;

    function setUp() public {
        vm.createSelectFork("mainnet", 21873556);

        // Deploy oracle
        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

        // Deploy SystemControl
        address systemControl = address(new SystemControl());

        // Deploy SIR
        sir = payable(address(new SIR(Addresses.ADDR_WETH, systemControl)));

        // Deploy APE implementation
        address apeImplementation = address(new APE());

        // Deploy Vault
        address vault = address(new Vault(systemControl, sir, oracle, apeImplementation, Addresses.ADDR_WETH));

        // Initialize SIR
        SIR(sir).initialize(vault);

        // Initialize SystemControl
        SystemControl(systemControl).initialize(vault, sir);
    }

    function test_treasuryMintsSIR() public {
        skip(1000 days);

        assertEq(IERC20(sir).balanceOf(TREASURY), 0);
        vm.prank(OWNER);
        ITreasuryV1(TREASURY).relayCall(sir, abi.encodeWithSelector(SIR.contributorMint.selector));
        assertTrue(IERC20(sir).balanceOf(TREASURY) > 0);
    }

    function test_noBodyMintsSIR() public {
        skip(1000 days);

        assertEq(IERC20(sir).balanceOf(TREASURY), 0);
        vm.expectRevert();
        ITreasuryV1(TREASURY).relayCall(sir, abi.encodeWithSelector(SIR.contributorMint.selector));
    }
}
