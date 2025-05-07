// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Addresses} from "src/libraries/Addresses.sol";
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

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

contract ContributorsTest is Test {
    using stdJson for string;

    struct USDContributor {
        address addr;
        uint256 allocation;
        uint256 allocationPrecision;
        uint256 contribution;
        string disclaimer;
        string ens;
        uint256 lock_nfts;
    }

    struct SpiceContributor {
        address addr;
        uint256 allocation;
    }

    uint256 constant THREE_YEARS = 3 * 365 * 24 * 60 * 60;
    uint256 constant FUNDRAISING_GOAL = 100_000; // $100K
    uint256 constant FUNDRAISING_PERCENTAGE = 10; // 10% of the issuance reserved for fundraising
    uint256 constant BC_BOOST = 6; // [%] 5% boost per BC

    SIR public sir;
    Contributors public contributors;

    USDContributor[] usdContributors;
    SpiceContributor[] spiceContributors;
    mapping(address => uint256) contributorIssuance;

    mapping(address => bool) addressChecked;

    function setUp() public {
        // vm.createSelectFork("mainnet", 18128102);
        vm.warp(4269);

        // Deploy Contributors
        contributors = (new Contributors());

        // Deploy SIR
        sir = new SIR(address(contributors), Addresses.ADDR_WETH, vm.addr(10));

        // Deploy APE implementation
        address ape = address(new APE());

        // Deploy Vault
        address vault = address(new Vault(vm.addr(10), address(sir), vm.addr(11), ape, Addresses.ADDR_WETH));

        // Initialize SIR
        sir.initialize(vault);

        // Get fundrasing contributors
        string memory usdJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/usd-contributors.json"));
        USDContributor[] memory usdContributors_ = abi.decode(
            usdJson.parseRaw(".contributors"), // Decode entire contributors array
            (USDContributor[])
        );

        // Get pre-mainnet contributors
        string memory spiceJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/spice-contributors.json"));
        SpiceContributor[] memory spiceContributors_ = abi.decode(
            spiceJson.parseRaw(""), // Decode root array
            (SpiceContributor[])
        );

        // Update their issuances
        for (uint256 i = 0; i < usdContributors_.length; i++) {
            usdContributors.push(usdContributors_[i]);

            uint256 issuance = (((usdContributors[i].contribution * SystemConstants.ISSUANCE) *
                FUNDRAISING_PERCENTAGE) * (100 + BC_BOOST * usdContributors[i].lock_nfts)) /
                (FUNDRAISING_GOAL * (100 ** 2));

            // Update the contributors issuance
            contributorIssuance[usdContributors[i].addr] += issuance;
        }
        for (uint256 i = 0; i < spiceContributors_.length; i++) {
            spiceContributors.push(spiceContributors_[i]);

            uint256 issuance = (spiceContributors[i].allocation * SystemConstants.ISSUANCE) / 10000;

            // Update the contributors issuance
            contributorIssuance[spiceContributors[i].addr] += issuance;
        }
    }

    function test_getAllocation() public {
        uint256 aggContributions = 0;
        for (uint256 i = 0; i < usdContributors.length; i++) {
            if (!addressChecked[usdContributors[i].addr]) {
                aggContributions += contributors.getAllocation(usdContributors[i].addr);
                addressChecked[usdContributors[i].addr] = true;
            }
        }

        for (uint256 i = 0; i < spiceContributors.length; i++) {
            if (!addressChecked[spiceContributors[i].addr]) {
                aggContributions += contributors.getAllocation(spiceContributors[i].addr);
                addressChecked[spiceContributors[i].addr] = true;
            }
        }

        // Treasury address
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        if (!addressChecked[treasury]) {
            aggContributions += contributors.getAllocation(treasury);
            addressChecked[treasury] = true;
        }

        assertEq(aggContributions, type(uint56).max);
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

        address contributorAddr = typeContributor ? _getUsdContributor(contributor) : _getSpiceContributor(contributor);

        // Skip time
        skip(timeSkip);

        // Issuance
        uint256 issuance = contributorIssuance[contributorAddr];

        // Contributor's rewards
        uint256 rewards = issuance * (timeSkip <= THREE_YEARS ? timeSkip : THREE_YEARS);
        assertApproxEqRel(
            sir.contributorUnclaimedSIR(contributorAddr),
            rewards,
            relErr18Decimals,
            string.concat("Unclaimed rewards mismatch for address ", vm.toString(contributorAddr))
        );

        // Mint contributor's rewards
        vm.prank(contributorAddr);
        if (timeSkip == 0) vm.expectRevert();
        uint256 rewards_ = sir.contributorMint();

        // Assert rewards
        assertApproxEqRel(
            rewards_,
            rewards,
            relErr18Decimals,
            string.concat("Rewards mismatch for address ", vm.toString(contributorAddr))
        );
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
        assertApproxEqRel(
            sir.contributorUnclaimedSIR(contributorAddr),
            rewards,
            relErr18Decimals,
            string.concat("Delayed rewards mismatch for address ", vm.toString(contributorAddr))
        );
    }

    /////////////////////////////////////////////////////////////////////////////
    ///////////////////// H E L P E R // F U N C T I O N S /////////////////////
    ///////////////////////////////////////////////////////////////////////////

    function _getUsdContributor(uint256 index) internal view returns (address) {
        return usdContributors[_bound(index, 0, usdContributors.length - 1)].addr;
    }

    function _getSpiceContributor(uint256 index) internal view returns (address) {
        return spiceContributors[_bound(index, 0, spiceContributors.length - 1)].addr;
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

        // Deploy Contributors
        address contributors = address(new Contributors());

        // Deploy SIR
        sir = new SIR(contributors, Addresses.ADDR_WETH, vm.addr(10));

        // Deploy APE implementation
        address ape = address(new APE());

        // Deploy Vault
        vault = new Vault(vm.addr(10), address(sir), oracle, ape, Addresses.ADDR_WETH);

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
