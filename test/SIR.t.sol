// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AddressesMegaETHTest} from "src/libraries/AddressesMegaETHTest.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {Oracle} from "src/Oracle.sol";
import {SIR} from "src/SIR.sol";
import {APE} from "src/APE.sol";
import {ErrorComputation} from "./ErrorComputation.sol";
import {Contributors} from "src/Contributors.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {ErrorComputation} from "./ErrorComputation.sol";
import {AllocationsHelper} from "../script/AllocationsHelper.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import "forge-std/Test.sol";

contract BasicSIRTest is AllocationsHelper, Test {
    uint256 constant THREE_YEARS = 3 * 365 * 24 * 60 * 60;

    SIR public sir;
    Contributors public contributors;
    address public vault;

    function setUp() public {
        vm.warp(4269);

        // Deploy Contributors
        contributors = (new Contributors());

        // Deploy SIR
        sir = new SIR(address(contributors), AddressesMegaETHTest.ADDR_WETH, vm.addr(10));

        // Deploy APE implementation
        address ape = address(new APE());

        // Deploy Vault
        vault = address(new Vault(vm.addr(10), address(sir), vm.addr(11), ape, AddressesMegaETHTest.ADDR_WETH));

        // Initialize SIR
        sir.initialize(vault);
    }

    function test_sirInitialization() public view {
        assertEq(address(sir.vault()), vault);
        assertEq(sir.SYSTEM_CONTROL(), vm.addr(10));
        assertEq(sir.decimals(), 12);
        assertEq(sir.name(), "Synthetics Implemented Right");
        assertEq(sir.symbol(), "MegaSIR");
    }

    function test_sirContributorMintReverts() public {
        address fakeContributor = vm.addr(100);

        // Skip time
        skip(100);

        // Fake contributor mint should revert
        assertEq(sir.contributorUnclaimedSIR(fakeContributor), 0);

        // Attempt to mint
        vm.prank(fakeContributor);
        vm.expectRevert();
        sir.contributorMint();
    }

    function test_allocations() public {
        // Use the AllocationsHelper to read and allocate from JSON
        (uint256 totalAddresses, uint256 totalAllocations) = readAndAllocate(address(contributors));

        // Verify the statistics
        console.log("Total addresses allocated:", totalAddresses);
        console.log("Total allocations sum:", totalAllocations);
        console.log("Expected (type(uint56).max):", type(uint56).max);

        // Verify the sum equals type(uint56).max
        assertEq(totalAllocations, type(uint56).max, "Allocations do not sum to type(uint56).max");

        // Verify remaining allocation is 0
        uint56 remaining = contributors.remainingAllocation();
        assertEq(remaining, 0, "Remaining allocation should be 0");

        // Verify we have the expected number of addresses from JSON metadata
        assertEq(totalAddresses, 4096, "Should have 4096 addresses from allocations.json");

        // Verify allocation percentages match the JSON
        _verifyAllocationPercentages();
    }

    function _verifyAllocationPercentages() internal {
        // Read the JSON file
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/allocations/allocations.json");
        string memory json = vm.readFile(path);

        // Extract all addresses
        string[] memory allocationKeys = vm.parseJsonKeys(json, ".allocations");

        console.log("\n=== Verifying Allocation Percentages ===");

        // Non-LP issuance per second
        uint256 nonLPIssuance = SystemConstants.ISSUANCE - SystemConstants.LP_ISSUANCE_FIRST_3_YEARS;

        console.log("Total ISSUANCE per second:", SystemConstants.ISSUANCE);
        console.log("LP_ISSUANCE_FIRST_3_YEARS per second:", SystemConstants.LP_ISSUANCE_FIRST_3_YEARS);
        console.log("Non-LP issuance per second:", nonLPIssuance);

        for (uint256 i = 0; i < allocationKeys.length; i++) {
            string memory addrKey = allocationKeys[i];

            // Get allocation from contract
            uint56 allocation = contributors.allocations(vm.parseAddress(addrKey));

            // Calculate issuance per second using the formula:
            // issuance = (allocation * nonLPIssuance) / type(uint56).max
            uint256 issuance = (uint256(allocation) * nonLPIssuance) / type(uint56).max;

            // Calculate percentage in parts per million (1,000,000 ppm = 100%)
            uint256 calculatedPercPPM = (issuance * 1000000) / SystemConstants.ISSUANCE;

            if (calculatedPercPPM <= 1) break;

            // Parse expected percentage from JSON
            string memory expectedPercStr = vm.parseJsonString(
                json,
                string.concat(".allocations.", addrKey, ".allocationPerc")
            );
            uint256 jsonPercPPM = _parsePercentageStringToPPM(expectedPercStr);

            // Verify values match within tolerance
            assertApproxEqRel(
                calculatedPercPPM,
                jsonPercPPM,
                10e16, // 10% relative tolerance
                string.concat("Percentage mismatch for ", addrKey)
            );
        }

        console.log("Total addresses checked:", allocationKeys.length);
        console.log("All percentages match!");
    }

    function _parsePercentageStringToPPM(string memory percStr) internal pure returns (uint256) {
        bytes memory percBytes = bytes(percStr);
        uint256 result = 0;
        uint256 decimals = 0;
        bool foundDot = false;
        bool foundPercent = false;

        for (uint256 i = 0; i < percBytes.length; i++) {
            bytes1 char = percBytes[i];

            if (char == 0x25) {
                // '%' character
                foundPercent = true;
                break;
            } else if (char == 0x2e) {
                // '.' character
                foundDot = true;
            } else if (char >= 0x30 && char <= 0x39) {
                // '0'-'9'
                uint8 digit = uint8(char) - 0x30;
                result = result * 10 + digit;
                if (foundDot) {
                    decimals++;
                }
            }
        }

        require(foundPercent, "Invalid percentage string");

        // Convert to parts per million (ppm)
        // 1% = 10,000 ppm, 0.01% = 100 ppm, 0.001% = 10 ppm
        // If we have "7.42%", result = 742, decimals = 2 -> 74,200 ppm
        // If we have "0.010000%", result = 10000, decimals = 6 -> 100 ppm

        if (decimals == 0) {
            // e.g., "7%" -> 70,000 ppm
            return result * 10000;
        } else if (decimals == 1) {
            // e.g., "7.4%" -> 74,000 ppm
            return result * 1000;
        } else if (decimals == 2) {
            // e.g., "7.42%" -> 74,200 ppm
            return result * 100;
        } else if (decimals == 3) {
            // e.g., "7.421%" -> 74,210 ppm
            return result * 10;
        } else if (decimals == 4) {
            // e.g., "7.4210%" -> 74,210 ppm
            return result;
        } else if (decimals > 4) {
            // e.g., "0.010000%" with decimals=6 -> result=10000, want 100 ppm
            // Divide by 10^(decimals-4)
            uint256 divisor = 10 ** (decimals - 4);
            return result / divisor;
        }

        return 0;
    }
}

contract GentlemenTest is Test, ERC1155TokenReceiver {
    uint256 constant THREE_YEARS = 3 * 365 * 24 * 60 * 60;

    IWETH9 private constant WETH = IWETH9(AddressesMegaETHTest.ADDR_WETH);

    SIR public sir;
    Vault public vault;

    address alice; // Will be set to address(this) to receive ERC1155
    uint256 teaBalanceOfAlice;

    SirStructs.VaultParameters vaultParameters =
        SirStructs.VaultParameters({
            debtToken: AddressesMegaETHTest.ADDR_USDC,
            collateralToken: AddressesMegaETHTest.ADDR_WETH,
            leverageTier: -1
        });

    function setUp() public {
        vm.createSelectFork("megatest_alchemy", 5655720);

        // Set alice to this contract so it can receive ERC1155 tokens (TEA)
        alice = address(this);

        // Deploy oracle
        address oracle = address(new Oracle(AddressesMegaETHTest.ADDR_UNISWAPV3_FACTORY));

        // Deploy Contributors
        address contributors = address(new Contributors());

        // Deploy SIR
        sir = new SIR(contributors, AddressesMegaETHTest.ADDR_WETH, vm.addr(10));

        // Deploy APE implementation
        address ape = address(new APE());

        // Deploy Vault
        vault = new Vault(vm.addr(10), address(sir), oracle, ape, AddressesMegaETHTest.ADDR_WETH);

        // Initialize SIR
        sir.initialize(address(vault));

        // Initialize vault
        vault.initialize(vaultParameters);

        // Set 1 vault to receive all the SIR rewards
        uint48[] memory oldVaults = new uint48[](0);
        uint48[] memory newVaults = new uint48[](1);
        newVaults[0] = 1;
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = 1;
        vm.prank(vm.addr(10));
        vault.updateVaults(oldVaults, newVaults, newTaxes, 1);

        // First gentleman deposits 1 WETH
        _dealWETH(alice, 1 ether);
        vm.prank(alice);
        WETH.approve(address(vault), 1 ether);

        // Alice mints TEA
        vm.prank(alice);
        teaBalanceOfAlice = vault.mint(false, vaultParameters, 1 ether, 0, 0);
    }

    function testFuzz_fakeLPerMint(address lper, uint32 timeSkip) public {
        vm.assume(lper != alice);

        // Skip time
        skip(timeSkip);

        // Attempt to mint
        vm.prank(lper);
        vm.expectRevert();
        sir.lperMint(1);
    }

    function testFuzz_fakeVaultLPerMint(uint256 vaultId, uint32 timeSkip) public {
        vm.assume(vaultId != 1);

        // Skip time
        skip(timeSkip);

        // Attempt to mint
        vm.prank(alice);
        vm.expectRevert();
        sir.lperMint(vaultId);
    }

    function testFuzz_lPerMint(uint32 timeSkip, uint32 timeSkip2, uint32 timeSkip3) public {
        timeSkip = uint32(_bound(timeSkip, 1, type(uint32).max));
        timeSkip2 = uint32(_bound(timeSkip2, 1, type(uint32).max));
        timeSkip3 = uint32(_bound(timeSkip3, 1, type(uint32).max));

        // Skip time
        skip(timeSkip);

        // Attempt to mint
        vm.prank(alice);
        uint80 rewards = sir.lperMint(1);

        // Expected rewards
        uint256 rewards_;
        if (timeSkip <= THREE_YEARS) {
            rewards_ = SystemConstants.LP_ISSUANCE_FIRST_3_YEARS * timeSkip;
        } else {
            rewards_ =
                SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
                THREE_YEARS +
                SystemConstants.ISSUANCE *
                (timeSkip - THREE_YEARS);
        }

        // Assert rewards
        assertApproxEqAbs(
            rewards,
            rewards_,
            ErrorComputation.maxErrorBalance(96, teaBalanceOfAlice, 1),
            "Rewards mismatch after 1 skip"
        );

        // No more rewards
        vm.prank(alice);
        vm.expectRevert();
        sir.lperMint(1);

        // Skip time
        skip(timeSkip2);

        // Attempt to mint
        vm.prank(alice);
        rewards += sir.lperMint(1);

        // Expected rewards
        if (uint256(timeSkip) + timeSkip2 <= THREE_YEARS) {
            rewards_ = SystemConstants.LP_ISSUANCE_FIRST_3_YEARS * (uint256(timeSkip) + timeSkip2);
        } else {
            rewards_ =
                SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
                THREE_YEARS +
                SystemConstants.ISSUANCE *
                (uint256(timeSkip) + timeSkip2 - THREE_YEARS);
        }

        // Assert rewards
        assertApproxEqAbs(
            rewards,
            rewards_,
            ErrorComputation.maxErrorBalance(96, teaBalanceOfAlice, 1) + 1,
            "Rewards mismatch after 2 skips"
        );

        // Burn TEA
        vm.prank(alice);
        vault.burn(false, vaultParameters, teaBalanceOfAlice, 0);

        // Skip time
        skip(timeSkip3);

        // Attempt to mint
        vm.prank(alice);
        vm.expectRevert();
        sir.lperMint(1);
    }

    function _dealWETH(address to, uint256 amount) internal {
        vm.deal(vm.addr(101), amount);
        vm.prank(vm.addr(101));
        WETH.deposit{value: amount}();
        vm.prank(vm.addr(101));
        WETH.transfer(address(to), amount);
    }
}
