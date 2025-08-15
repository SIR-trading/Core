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

contract BasicSIRTest is Test {
    uint256 constant THREE_YEARS = 3 * 365 * 24 * 60 * 60;

    SIR public sir;
    Contributors public contributors;
    address public vault;

    function setUp() public {
        vm.warp(4269);

        // Deploy Contributors
        contributors = (new Contributors());

        // Deploy SIR
        sir = new SIR(address(contributors), Addresses.ADDR_WETH, vm.addr(10));

        // Deploy APE implementation
        address ape = address(new APE());

        // Deploy Vault
        vault = address(new Vault(vm.addr(10), address(sir), vm.addr(11), ape, Addresses.ADDR_WETH));

        // Initialize SIR
        sir.initialize(vault);
    }

    function test_sirInitialization() public {
        assertEq(address(sir.vault()), vault);
        assertEq(sir.SYSTEM_CONTROL(), vm.addr(10));
        assertEq(sir.decimals(), 12);
        assertEq(sir.name(), "Synthetics Implemented Right");
        assertEq(sir.symbol(), "SIR");
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
