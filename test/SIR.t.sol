// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Addresses} from "src/libraries/Addresses.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {Oracle} from "src/Oracle.sol";
import {SIR} from "src/SIR.sol";
import {APE} from "src/APE.sol";
import {ErrorComputation} from "./ErrorComputation.sol";
import {Contributors} from "src/libraries/Contributors.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {ErrorComputation} from "./ErrorComputation.sol";

import "forge-std/Test.sol";

contract ContributorsTest is Test {
    struct ContributorFR {
        uint256 contribution;
        address addr;
        uint256 numBC;
    }

    struct ContributorPreMainnet {
        uint256 allocation;
        address addr;
    }

    uint256 constant THREE_YEARS = 3 * 365 * 24 * 60 * 60;
    uint256 constant FUNDRAISING_PERCENTAGE = 10; // 10% of the issuance reserved for fundraising
    uint256 constant BC_BOOST = 5; // [%] 5% boost per BC
    uint256 constant MAX_NUM_BC = 6; // Maximum number of BCs for boost

    uint256 fundraisingTotal = 0;

    SIR public sir;

    ContributorFR[] contributorsFR;
    ContributorPreMainnet[] contributorsPreMainnet;
    mapping(address => bool) existsContributor;

    function setUp() public {
        // vm.createSelectFork("mainnet", 18128102);
        vm.warp(4269);

        // Deploy SIR
        sir = new SIR(Addresses.ADDR_WETH);

        // Deploy APE implementation
        address ape = address(new APE());

        // Deploy Vault
        address vault = address(new Vault(vm.addr(10), address(sir), vm.addr(11), ape));

        // Initialize SIR
        sir.initialize(vault);

        // Get fundrasing contributors
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contributors/fundraising.json"));
        bytes memory data = vm.parseJson(json);
        ContributorFR[] memory contributorsFR_ = abi.decode(data, (ContributorFR[]));
        for (uint256 i = 0; i < contributorsFR_.length; i++) {
            // Sum total fundraising
            fundraisingTotal += contributorsFR_[i].contribution;

            // Limit the number of BCs
            if (contributorsFR_[i].numBC > MAX_NUM_BC) contributorsFR_[i].numBC = MAX_NUM_BC;

            // Add the contributor if the contribution is greater than 0
            if (contributorsFR_[i].contribution > 0) {
                contributorsFR.push(contributorsFR_[i]);

                // Indicate that the contributors exist
                existsContributor[contributorsFR_[i].addr] = true;
            }
        }

        // Get pre-mainnet contributors
        json = vm.readFile(string.concat(vm.projectRoot(), "/contributors/pre_mainnet.json"));
        data = vm.parseJson(json);
        ContributorPreMainnet[] memory contributorsPreMainnet_ = abi.decode(data, (ContributorPreMainnet[]));
        for (uint256 i = 0; i < contributorsPreMainnet_.length; i++) {
            if (contributorsPreMainnet_[i].allocation > 0) {
                contributorsPreMainnet.push(contributorsPreMainnet_[i]);

                // Indicate that the contributors exist
                existsContributor[contributorsPreMainnet_[i].addr] = true;
            }
        }
    }

    function test_getAllocation() public view {
        uint256 aggContributions = 0;

        for (uint256 i = 0; i < contributorsFR.length; i++) {
            aggContributions += Contributors.getAllocation(contributorsFR[i].addr);
        }

        for (uint256 i = 0; i < contributorsPreMainnet.length; i++) {
            aggContributions += Contributors.getAllocation(contributorsPreMainnet[i].addr);
        }

        assertEq(aggContributions, type(uint56).max); // This works for now but most likely it needs some error tolerance.
    }

    function testFuzz_fakeContributorMint(address contributor, uint32 timeSkip) public {
        vm.assume(!existsContributor[contributor]);

        // Skip time
        skip(timeSkip);

        // Fake contributor mint
        assertEq(sir.contributorUnclaimedSIR(contributor), 0);

        // Attempt to mint
        vm.prank(contributor);
        vm.expectRevert();
        sir.contributorMint();
    }

    function testFuzz_funraisingContributorMint(uint256 contributor, uint32 timeSkip, uint32 timeSkip2) public {
        ContributorFR memory contributorFR = _getContributorFR(contributor);

        // Skip time
        skip(timeSkip);

        // Issuance
        uint256 issuance = (((contributorFR.contribution * SystemConstants.ISSUANCE) * FUNDRAISING_PERCENTAGE) *
            (100 + BC_BOOST * contributorFR.numBC)) / (fundraisingTotal * (100 ** 2));

        // Contributor's rewards
        uint256 rewards = issuance * (timeSkip <= THREE_YEARS ? timeSkip : THREE_YEARS);
        assertEq(sir.contributorUnclaimedSIR(contributorFR.addr), rewards);

        // Mint contributor's rewards
        vm.prank(contributorFR.addr);
        if (timeSkip == 0) vm.expectRevert();
        uint256 rewards_ = sir.contributorMint();

        // Assert rewards
        assertEq(rewards_, rewards);
        assertEq(sir.contributorUnclaimedSIR(contributorFR.addr), 0);

        // Skip time
        skip(timeSkip2);

        // Contributor's rewards
        rewards =
            issuance *
            (
                uint256(timeSkip) + timeSkip2 <= THREE_YEARS
                    ? timeSkip2
                    : (timeSkip <= THREE_YEARS ? THREE_YEARS - timeSkip : 0)
            );
        assertEq(sir.contributorUnclaimedSIR(contributorFR.addr), rewards);
    }

    function testFuzz_preMainnetContributorMint(uint256 contributor, uint32 timeSkip, uint32 timeSkip2) public {
        ContributorPreMainnet memory contributorPreMainnet = _getContributorPreMainnet(contributor);

        // Skip time
        skip(timeSkip);

        // Issuance
        uint256 issuance = (contributorPreMainnet.allocation * SystemConstants.ISSUANCE) / 100000;

        // Contributor's rewards
        uint256 rewards = issuance * (timeSkip <= THREE_YEARS ? timeSkip : THREE_YEARS);
        assertEq(sir.contributorUnclaimedSIR(contributorPreMainnet.addr), rewards);

        // Mint contributor's rewards
        vm.prank(contributorPreMainnet.addr);
        if (timeSkip == 0) vm.expectRevert();
        uint256 rewards_ = sir.contributorMint();

        // Assert rewards
        assertEq(rewards_, rewards);
        assertEq(sir.contributorUnclaimedSIR(contributorPreMainnet.addr), 0);

        // Skip time
        skip(timeSkip2);

        // Contributor's rewards
        rewards =
            issuance *
            (
                uint256(timeSkip) + timeSkip2 <= THREE_YEARS
                    ? timeSkip2
                    : (timeSkip <= THREE_YEARS ? THREE_YEARS - timeSkip : 0)
            );
        assertEq(sir.contributorUnclaimedSIR(contributorPreMainnet.addr), rewards);
    }

    /////////////////////////////////////////////////////////////////////////////
    ///////////////////// H E L P E R // F U N C T I O N S /////////////////////
    ///////////////////////////////////////////////////////////////////////////

    function _getContributorFR(uint256 index) internal view returns (ContributorFR memory) {
        return contributorsFR[_bound(index, 0, contributorsFR.length - 1)];
    }

    function _getContributorPreMainnet(uint256 index) internal view returns (ContributorPreMainnet memory) {
        return contributorsPreMainnet[_bound(index, 0, contributorsPreMainnet.length - 1)];
    }
}

contract GentlemenTest is Test {
    uint256 constant THREE_YEARS = 3 * 365 * 24 * 60 * 60;

    IWETH9 private constant WETH = IWETH9(Addresses.ADDR_WETH);

    SIR public sir;
    Vault public vault;

    address alice = vm.addr(1);
    uint256 teaBalanceOfAlice;

    SirStructs.VaultParameters vaultParameters =
        SirStructs.VaultParameters({
            debtToken: Addresses.ADDR_USDT,
            collateralToken: Addresses.ADDR_WETH,
            leverageTier: -1
        });

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        // Deploy oracle
        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

        // Deploy SIR
        sir = new SIR(Addresses.ADDR_WETH);

        // Deploy APE implementation
        address ape = address(new APE());

        // Deploy Vault
        vault = new Vault(vm.addr(10), address(sir), oracle, ape);

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
        teaBalanceOfAlice = vault.mint(false, vaultParameters, 1 ether);
    }

    function testFuzz_fakeLPerMint(address lper, uint32 timeSkip) public {
        vm.assume(lper != alice);

        // Skip time
        skip(timeSkip);

        // Attempt to mint
        vm.prank(lper);
        vm.expectRevert();
        sir.lPerMint(1);
    }

    function testFuzz_fakeVaultLPerMint(uint256 vaultId, uint32 timeSkip) public {
        vm.assume(vaultId != 1);

        // Skip time
        skip(timeSkip);

        // Attempt to mint
        vm.prank(alice);
        vm.expectRevert();
        sir.lPerMint(vaultId);
    }

    function testFuzz_lPerMint(uint32 timeSkip, uint32 timeSkip2, uint32 timeSkip3) public {
        timeSkip = uint32(_bound(timeSkip, 1, type(uint32).max));
        timeSkip2 = uint32(_bound(timeSkip2, 1, type(uint32).max));
        timeSkip3 = uint32(_bound(timeSkip3, 1, type(uint32).max));

        // Skip time
        skip(timeSkip);

        // Attempt to mint
        vm.prank(alice);
        uint80 rewards = sir.lPerMint(1);

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
        sir.lPerMint(1);

        // Skip time
        skip(timeSkip2);

        // Attempt to mint
        vm.prank(alice);
        rewards += sir.lPerMint(1);

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
        vault.burn(false, vaultParameters, teaBalanceOfAlice);

        // Skip time
        skip(timeSkip3);

        // Attempt to mint
        vm.prank(alice);
        vm.expectRevert();
        sir.lPerMint(1);
    }

    function _dealWETH(address to, uint256 amount) internal {
        vm.deal(vm.addr(101), amount);
        vm.prank(vm.addr(101));
        WETH.deposit{value: amount}();
        vm.prank(vm.addr(101));
        WETH.transfer(address(to), amount);
    }
}
