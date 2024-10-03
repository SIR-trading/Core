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

    SIR public sir;

    ContributorFR[] contributorsFR;
    ContributorPreMainnet[] contributorsPreMainnet;
    mapping(address => uint256) contributorIssuance;

    mapping(address => bool) addressChecked;

    function setUp() public {
        // vm.createSelectFork("mainnet", 18128102);
        vm.warp(4269);

        // Deploy SIR
        sir = new SIR();

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
        uint256 fundraisingTotal = 0;
        for (uint256 i = 0; i < contributorsFR_.length; i++) {
            // Sum total fundraising
            fundraisingTotal += contributorsFR_[i].contribution;

            // Limit the number of BCs
            if (contributorsFR_[i].numBC > MAX_NUM_BC) contributorsFR_[i].numBC = MAX_NUM_BC;

            // Add the contributor if the contribution is greater than 0
            if (contributorsFR_[i].contribution > 0) {
                contributorsFR.push(contributorsFR_[i]);
            }
        }

        // Get pre-mainnet contributors
        json = vm.readFile(string.concat(vm.projectRoot(), "/contributors/pre_mainnet.json"));
        data = vm.parseJson(json);
        ContributorPreMainnet[] memory contributorsPreMainnet_ = abi.decode(data, (ContributorPreMainnet[]));
        for (uint256 i = 0; i < contributorsPreMainnet_.length; i++) {
            if (contributorsPreMainnet_[i].allocation > 0) {
                contributorsPreMainnet.push(contributorsPreMainnet_[i]);
            }
        }

        // Update their issuances
        for (uint256 i = 0; i < contributorsFR.length; i++) {
            uint256 issuance = (((contributorsFR[i].contribution * SystemConstants.ISSUANCE) * FUNDRAISING_PERCENTAGE) *
                (100 + BC_BOOST * contributorsFR[i].numBC)) / (fundraisingTotal * (100 ** 2));

            // Update the contributors issuance
            contributorIssuance[contributorsFR[i].addr] += issuance;
        }
        for (uint256 i = 0; i < contributorsPreMainnet.length; i++) {
            uint256 issuance = (contributorsPreMainnet[i].allocation * SystemConstants.ISSUANCE) / 100000;

            // Update the contributors issuance
            contributorIssuance[contributorsPreMainnet[i].addr] += issuance;
        }
    }

    function test_getAllocation() public {
        uint256 aggContributions = 0;
        for (uint256 i = 0; i < contributorsFR.length; i++) {
            if (!addressChecked[contributorsFR[i].addr]) {
                aggContributions += Contributors.getAllocation(contributorsFR[i].addr);
                addressChecked[contributorsFR[i].addr] = true;
            }
        }

        for (uint256 i = 0; i < contributorsPreMainnet.length; i++) {
            if (!addressChecked[contributorsPreMainnet[i].addr]) {
                aggContributions += Contributors.getAllocation(contributorsPreMainnet[i].addr);
                addressChecked[contributorsPreMainnet[i].addr] = true;
            }
        }

        assertEq(aggContributions, type(uint56).max); // This works for now but most likely it needs some error tolerance.
    }

    function testFuzz_fakeContributorMint(address contributor, uint32 timeSkip) public {
        vm.assume(contributorIssuance[contributor] == 0);

        // Skip time
        skip(timeSkip);

        // Fake contributor mint
        assertEq(sir.contributorUnclaimedSIR(contributor), 0);

        // Attempt to mint
        vm.prank(contributor);
        vm.expectRevert();
        sir.contributorMint();
    }

    function testFuzz_contributorMint(
        bool typeContributor,
        uint256 contributor,
        uint32 timeSkip,
        uint32 timeSkip2
    ) public {
        uint256 relErr18Decimals = 1e6;

        address contributorAddr = typeContributor
            ? _getContributorFR(contributor)
            : _getContributorPreMainnet(contributor);

        // Skip time
        skip(timeSkip);

        // Issuance
        uint256 issuance = contributorIssuance[contributorAddr];

        // Contributor's rewards
        uint256 rewards = issuance * (timeSkip <= THREE_YEARS ? timeSkip : THREE_YEARS);
        assertApproxEqRel(sir.contributorUnclaimedSIR(contributorAddr), rewards, relErr18Decimals);

        // Mint contributor's rewards
        vm.prank(contributorAddr);
        if (timeSkip == 0) vm.expectRevert();
        uint256 rewards_ = sir.contributorMint();

        // Assert rewards
        assertApproxEqRel(rewards_, rewards, relErr18Decimals);
        assertEq(sir.contributorUnclaimedSIR(contributorAddr), 0);

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
        assertApproxEqRel(sir.contributorUnclaimedSIR(contributorAddr), rewards, relErr18Decimals);
    }

    /////////////////////////////////////////////////////////////////////////////
    ///////////////////// H E L P E R // F U N C T I O N S /////////////////////
    ///////////////////////////////////////////////////////////////////////////

    function _getContributorFR(uint256 index) internal view returns (address) {
        return contributorsFR[_bound(index, 0, contributorsFR.length - 1)].addr;
    }

    function _getContributorPreMainnet(uint256 index) internal view returns (address) {
        return contributorsPreMainnet[_bound(index, 0, contributorsPreMainnet.length - 1)].addr;
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
        address oracle = address(new Oracle());

        // Deploy SIR
        sir = new SIR();

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
