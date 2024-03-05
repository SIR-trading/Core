// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {Vault} from "src/Vault.sol";
import {Oracle} from "src/Oracle.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {Fees} from "src/libraries/Fees.sol";
import {SaltedAddress} from "src/libraries/SaltedAddress.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

// import {APE} from "src/APE.sol";

contract VaultInitializeTest is Test {
    error VaultAlreadyInitialized();
    error LeverageTierOutOfRange();
    error NoUniswapPool();

    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId
    );

    address public systemControl = vm.addr(1);
    address public sir = vm.addr(2);

    Vault public vault;

    address public debtToken = Addresses.ADDR_USDT;
    address public collateralToken = Addresses.ADDR_WETH;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        address oracle = address(new Oracle());

        // Deploy vault
        vault = new Vault(systemControl, sir, oracle);
    }

    function testFuzz_InitializeVault(int8 leverageTier) public {
        // Stay within the allowed range
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER));

        vm.expectRevert();
        vault.paramsById(1);

        vm.expectEmit();
        emit VaultInitialized(debtToken, collateralToken, leverageTier, 1);
        vault.initialize(VaultStructs.VaultParameters(debtToken, collateralToken, leverageTier));

        (uint144 reserve, int64 tickPriceSatX42, uint48 vaultId) = vault.vaultStates(
            debtToken,
            collateralToken,
            leverageTier
        );
        (address debtToken_, address collateralToken_, int8 leverageTier_) = vault.paramsById(1);

        assertEq(reserve, 0);
        assertEq(tickPriceSatX42, 0);
        assertEq(vaultId, 1);
        assertEq(debtToken, debtToken_);
        assertEq(collateralToken, collateralToken_);
        assertEq(leverageTier, leverageTier_);

        vm.expectRevert();
        vault.paramsById(2);

        vm.expectEmit();
        emit VaultInitialized(collateralToken, debtToken, leverageTier, 2);
        vault.initialize(VaultStructs.VaultParameters(collateralToken, debtToken, leverageTier));

        (reserve, tickPriceSatX42, vaultId) = vault.vaultStates(collateralToken, debtToken, leverageTier);
        (debtToken_, collateralToken_, leverageTier_) = vault.paramsById(2);

        assertEq(reserve, 0);
        assertEq(tickPriceSatX42, 0);
        assertEq(vaultId, 2);
        assertEq(debtToken, collateralToken_);
        assertEq(collateralToken, debtToken_);
        assertEq(leverageTier, leverageTier_);

        vm.expectRevert();
        vault.paramsById(3);
    }

    function testFuzz_InitializeVaultWrongLeverage(int8 leverageTier) public {
        leverageTier = _boundExclude(
            leverageTier,
            SystemConstants.MIN_LEVERAGE_TIER,
            SystemConstants.MAX_LEVERAGE_TIER
        );

        vm.expectRevert(LeverageTierOutOfRange.selector);
        vault.initialize(VaultStructs.VaultParameters(debtToken, collateralToken, leverageTier));
    }

    function testFuzz_InitializeVaultAlreadyInitialized(int8 leverageTier) public {
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER));

        testFuzz_InitializeVault(leverageTier);

        vm.expectRevert(VaultAlreadyInitialized.selector);
        vault.initialize(VaultStructs.VaultParameters(debtToken, collateralToken, leverageTier));
    }

    function testFuzz_InitializeVaultNoUniswapPool(int8 leverageTier) public {
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER));

        vm.expectRevert(NoUniswapPool.selector);
        vault.initialize(VaultStructs.VaultParameters(Addresses.ADDR_BNB, Addresses.ADDR_ALUSD, leverageTier));
    }

    // function testMintAPE() public {
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    //     uint256 amountMinted = vault.mint(true, debtToken, collateralToken, validLeverageTier);
    //     assertTrue(amountMinted > 0);
    //     // Additional checks for reserves and token balances can be added here
    // }

    // function testMintTEA() public {
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    //     uint256 amountMinted = vault.mint(false, debtToken, collateralToken, validLeverageTier);
    //     assertTrue(amountMinted > 0);
    //     // Additional checks for reserves and token balances can be added here
    // }

    // function testMintWithEmergencyStop() public {
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    //     // Simulate emergency stop
    //     vm.prank(systemControl);
    //     vault.updateSystemState(VaultStructs.SystemParameters(0, 0, 0, true, 0));
    //     vm.expectRevert(); // Expect specific revert message for emergency stop
    //     vault.mint(false, debtToken, collateralToken, validLeverageTier);
    // }

    // function testMintBeforeSIRStart() public {
    //     // Assuming SIR start is controlled by a vaultState variable or similar mechanism
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    //     // Ensure SIR has not started
    //     vm.expectRevert(); // Expect specific revert message for SIR not started
    //     vault.mint(true, debtToken, collateralToken, validLeverageTier);
    // }

    // function testBurnAPE() public {
    //     // Setup and mint some APE
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    //     uint256 amountMinted = vault.mint(true, debtToken, collateralToken, validLeverageTier);
    //     // Burn a portion of the minted APE
    //     uint144 amountBurned = vault.burn(true, debtToken, collateralToken, validLeverageTier, amountMinted / 2);
    //     assertTrue(amountBurned > 0);
    //     // Additional checks for reserve updates can be added here
    // }

    function _boundExclude(int8 x, int8 lower, int8 upper) private pure returns (int8) {
        assert(lower != type(int8).min || upper != type(int8).max);
        if (x >= lower) {
            int16 delta;
            int256 y;
            do {
                delta = int16(x) - lower;
                y = int256(upper) + 1 + delta;
                do {
                    y -= 256;
                } while (y > type(int8).max);
                x = int8(y);
            } while (x >= lower && x <= upper);
        }
        return x;
    }
}

contract VaultTest is Test {
    error LeverageTierOutOfRange();
    error NoUniswapPool();

    struct SystemParams {
        uint16 baseFee;
        uint8 lpFee;
        uint8 tax;
    }

    uint48 constant VAULT_ID = 1;

    address public systemControl = vm.addr(1);
    address public sir = vm.addr(2);

    Vault public vault;
    IERC20 public ape;

    address public alice = vm.addr(3);

    address public debtToken = Addresses.ADDR_USDT;
    address public collateralToken = Addresses.ADDR_WETH;
    int8 public leverageTier = -1;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        address oracle = address(new Oracle());

        // Deploy vault
        vault = new Vault(systemControl, sir, oracle);

        // Initialize vault
        vault.initialize(VaultStructs.VaultParameters(debtToken, collateralToken, leverageTier));

        // Derive APE address
        ape = IERC20(SaltedAddress.getAddress(address(vault), 1));

        // Mint 2^128 WETH for testing
        deal(alice, 2 << 155);
        vm.prank(alice);
        IWETH9(collateralToken).deposit{value: 2 << 155}();
    }

    modifier SetFees(SystemParams calldata systemParams) {
        // Set base and LP fees
        vm.prank(systemControl);
        vault.updateSystemState(systemParams.baseFee, systemParams.lpFee, false);

        // Set tax
        vm.prank(systemControl);
        {
            uint48[] memory oldVaults = new uint48[](0);
            uint48[] memory newVaults = new uint48[](1);
            newVaults[0] = VAULT_ID;
            uint8[] memory newTaxes = new uint8[](1);
            newTaxes[0] = systemParams.tax;
            vault.updateVaults(oldVaults, newVaults, newTaxes, systemParams.tax);
        }

        _;
    }

    function testFuzz_mintAPE1stTime(
        SystemParams calldata systemParams,
        uint144 collateralDeposited
    ) public SetFees(systemParams) {
        // Minimum amount of reserves is 2
        // Max deposit is chosen so that tokenState.collectedFees is for sure not overflowed
        collateralDeposited = uint144(_bound(collateralDeposited, 2, uint256(10) * type(uint112).max));

        // Alice deposits WETH
        vm.prank(alice);
        IWETH9(collateralToken).transfer(address(vault), collateralDeposited);

        // Alice mints APE
        vm.prank(alice);
        uint256 amount = vault.mint(true, VaultStructs.VaultParameters(debtToken, collateralToken, leverageTier));

        // Verify amounts
        (uint144 collateralIn, uint144 collectedFee, uint144 lpersFee, uint144 polFee) = Fees.hiddenFeeAPE(
            collateralDeposited,
            systemParams.baseFee,
            leverageTier,
            systemParams.tax
        );

        // Check reserves
        VaultStructs.Reserves memory reserves = vault.getReserves(
            VaultStructs.VaultParameters(debtToken, collateralToken, leverageTier)
        );

        // To simplify the math, no reserve is allowed to be 0
        assertGt(reserves.reserveApes, 0);
        assertGt(reserves.reserveLPers, 0);

        // Error tolerance discovered by trial-and-error
        assertApproxEqAbs(reserves.reserveApes, collateralIn, 1 + (collateralDeposited - collectedFee) / 1e16);
        assertApproxEqAbs(reserves.reserveLPers, lpersFee + polFee, 1 + (collateralDeposited - collectedFee) / 1e16);

        // Verify Alice's balances
        if (collateralIn == 0) {
            assertEq(amount, 0);
            assertEq(ape.balanceOf(alice), 0);
        } else {
            assertGe(amount, 0);
            assertGe(ape.balanceOf(alice), 0);
        }
        assertEq(vault.balanceOf(alice, VAULT_ID), 0);

        // Verify POL's balances
        assertEq(ape.balanceOf(address(vault)), 0);
        if (lpersFee + polFee == 0) {
            assertEq(vault.balanceOf(address(vault), VAULT_ID), 0);
        } else {
            assertGe(vault.balanceOf(address(vault), VAULT_ID), 0);
        }
    }

    function testFuzz_mintTEA1stTime(
        SystemParams calldata systemParams,
        uint144 collateralDeposited
    ) public SetFees(systemParams) {
        // Minimum amount of reserves is 2
        // Max deposit is chosen so that tokenState.collectedFees is for sure not overflowed
        collateralDeposited = uint144(_bound(collateralDeposited, 2, uint256(10) * type(uint112).max));

        // Alice deposits WETH
        vm.prank(alice);
        IWETH9(collateralToken).transfer(address(vault), collateralDeposited);

        // Alice mints APE
        vm.prank(alice);
        uint256 amount = vault.mint(false, VaultStructs.VaultParameters(debtToken, collateralToken, leverageTier));

        // Verify amounts
        (uint144 collateralIn, uint144 collectedFee, uint144 lpersFee, uint144 polFee) = Fees.hiddenFeeTEA(
            collateralDeposited,
            systemParams.lpFee,
            systemParams.tax
        );

        // Check reserves
        VaultStructs.Reserves memory reserves = vault.getReserves(
            VaultStructs.VaultParameters(debtToken, collateralToken, leverageTier)
        );

        // To simplify the math, no reserve is allowed to be 0
        assertGt(reserves.reserveLPers, 0);
        assertGt(reserves.reserveApes, 0);

        // Error tolerance discovered by trial-and-error
        assertApproxEqAbs(
            reserves.reserveLPers,
            collateralIn + lpersFee + polFee - 1,
            1 + (collateralDeposited - collectedFee) / 1e16
        );
        assertApproxEqAbs(reserves.reserveApes, 1, 1 + (collateralDeposited - collectedFee) / 1e16);

        // Verify Alice's balances
        if (collateralIn == 0) {
            assertEq(amount, 0);
            assertEq(vault.balanceOf(alice, VAULT_ID), 0);
        } else {
            assertGe(amount, 0);
            assertGe(vault.balanceOf(alice, VAULT_ID), 0);
        }
        assertEq(ape.balanceOf(alice), 0);

        // Verify POL's balances
        if (lpersFee + polFee == 0) {
            assertEq(vault.balanceOf(address(vault), VAULT_ID), 0);
        } else {
            assertGe(vault.balanceOf(address(vault), VAULT_ID), 0);
        }
        assertEq(ape.balanceOf(address(vault)), 0);
    }

    // MAKE TESTS THAT CHECK THE RESERVES WHEN PRICE FLUCTUATES, WITHOUT MINTING OR BURNING
}

// INVARIANT TEST USING REAL DATA AND USING CONSTANT PRICE

// INVARIANT TEST WITH EXTREME PRICES
