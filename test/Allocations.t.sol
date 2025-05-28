// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

// Libraries
import {Addresses} from "src/libraries/Addresses.sol";
import {Contributors} from "src/Contributors.sol";
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

contract Posthack is Test {
    using stdJson for string;

    string compensationJson;
    string spiceJson;

    constructor() {
        // Get compensated contributors
        compensationJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/posthack-compensations.json"));

        // Get posthack contributors
        spiceJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/posthack-contributors.json"));
    }

    function getCompensations(uint256 index) external view returns (address addr, uint256 allocationInBillionParts) {
        string memory idx = vm.toString(index);
        string memory base = string.concat(".allocations[", idx, "]");

        addr = compensationJson.readAddress(string.concat(base, ".address"));
        allocationInBillionParts = compensationJson.readUint(string.concat(base, ".allocationInBillionParts"));
    }

    function getContributors(uint256 index) external view returns (address addr, uint256 allocationInBillionParts) {
        string memory idx = vm.toString(index);
        string memory base = string.concat("[", idx, "]");

        addr = spiceJson.readAddress(string.concat(base, ".address"));
        allocationInBillionParts = spiceJson.readUint(string.concat(base, ".allocationInBillionParts"));
    }
}

contract AllocationsTest is Test {
    using stdJson for string;

    mapping(address => uint256) allocationsInBillionParts;
    address[] public allContributors;
    address treasury;

    Contributors public contributorsContract;
    uint256 public constant YEAR_ISSUANCE = 2_015_000_000 * 10 ** (SystemConstants.SIR_DECIMALS); // 2,015 M SIR per year

    function setUp() public {
        // Helper contract
        Posthack compensations = new Posthack();

        // Get compensated contributors
        uint256 count = 0;
        while (true) {
            try compensations.getCompensations(count) returns (address addr, uint256 allocationInBillionParts) {
                if (allocationsInBillionParts[addr] == 0) {
                    allContributors.push(addr);
                }
                allocationsInBillionParts[addr] += allocationInBillionParts;
            } catch {
                // We reached the end of the array
                break;
            }

            count++;
        }

        // Get posthack contributors
        count = 0;
        while (true) {
            try compensations.getContributors(count) returns (address addr, uint256 allocationInBillionParts) {
                if (allocationsInBillionParts[addr] == 0) {
                    allContributors.push(addr);
                }
                allocationsInBillionParts[addr] += allocationInBillionParts;
            } catch {
                // We reached the end of the array
                break;
            }

            count++;
        }

        // Instantiate contributors contract
        contributorsContract = new Contributors();
    }

    // Test all allocations are greater than 0
    function test_allAddressesHaveAllocations() public view {
        for (uint256 i = 0; i < allContributors.length; i++) {
            uint56 allocation = contributorsContract.getAllocation(allContributors[i]);

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
            uint56 allocation = contributorsContract.getAllocation(allContributors[i]);
            totalAllocations += allocation;
        }

        assertEq(totalAllocations, type(uint56).max, "Total allocations is not type(uint56).max");
    }

    // Check the allocations match
    function test_allocationsMatch() public {
        // Validate allocations
        for (uint256 i = 0; i < allContributors.length; i++) {
            address addr = allContributors[i];
            uint256 issuance = (contributorsContract.getAllocation(addr) *
                uint256(SystemConstants.ISSUANCE - SystemConstants.LP_ISSUANCE_FIRST_3_YEARS)) / type(uint56).max;
            uint256 actual = issuance * 365 days;

            uint256 expected = (allocationsInBillionParts[addr] * YEAR_ISSUANCE) / 1e9;

            console.log(addr, actual, expected);
            assertApproxEqRel(actual, expected, 1e12, string.concat("Allocation mismatch for ", vm.toString(addr)));
        }
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

        // Deploy Contributors
        address contributors = address(new Contributors());

        // Deploy SIR
        sir = payable(address(new SIR(contributors, Addresses.ADDR_WETH, systemControl)));

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
