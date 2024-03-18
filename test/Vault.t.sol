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
import {FullMath} from "src/libraries/FullMath.sol";

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

    struct Balances {
        uint128 teaVault;
        uint128 teaAlice;
        uint128 teaSupply;
        uint256 apeAlice;
        uint256 apeSupply;
    }

    uint48 constant VAULT_ID = 1;

    address public systemControl = vm.addr(1);
    address public sir = vm.addr(2);

    Vault public vault;
    IERC20 public ape;

    address public alice = vm.addr(3);

    VaultStructs.VaultParameters public vaultParams;

    function setUp() public {
        vaultParams.debtToken = Addresses.ADDR_USDT;
        vaultParams.collateralToken = Addresses.ADDR_WETH;

        vm.createSelectFork("mainnet", 18128102);

        address oracle = address(new Oracle());

        // Deploy vault
        vault = new Vault(systemControl, sir, oracle);

        // Derive APE address
        ape = IERC20(SaltedAddress.getAddress(address(vault), VAULT_ID));
    }

    function _depositWETH(uint144 amount) private {
        deal(alice, amount);
        vm.prank(alice);
        IWETH9(vaultParams.collateralToken).deposit{value: amount}();
        vm.prank(alice);
        IWETH9(vaultParams.collateralToken).transfer(address(vault), amount);
    }

    modifier Initialize(SystemParams calldata systemParams, int8 leverageTier) {
        vaultParams.leverageTier = int8(
            _bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER)
        );

        // Initialize vault
        vault.initialize(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

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
        uint144 collateralDeposited,
        int8 leverageTier
    ) public Initialize(systemParams, leverageTier) {
        // Minimum amount of reserves is 2
        // Max deposit is chosen so that tokenState.collectedFees is for sure not overflowed
        collateralDeposited = uint144(_bound(collateralDeposited, 2, uint256(10) * type(uint112).max));

        // Alice deposits WETH
        _depositWETH(collateralDeposited);

        // Alice mints APE
        vm.prank(alice);
        uint256 amount = vault.mint(
            true,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Check reserves
        VaultStructs.Reserves memory reserves = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // To simplify the math, no reserve is allowed to be 0
        assertGt(reserves.reserveApes, 0);
        assertGt(reserves.reserveLPers, 0);

        // Verify amounts
        _verifyAmountsMintAPE(
            systemParams,
            collateralDeposited,
            VaultStructs.Reserves(0, 0, 0),
            reserves,
            amount,
            Balances(0, 0, 0, 0, 0)
        );
    }

    function testFuzz_mintTEA1stTime(
        SystemParams calldata systemParams,
        uint144 collateralDeposited,
        int8 leverageTier
    ) public Initialize(systemParams, leverageTier) {
        // Minimum amount of reserves is 2
        // Max deposit is chosen so that tokenState.collectedFees is for sure not overflowed
        collateralDeposited = uint144(_bound(collateralDeposited, 2, uint256(10) * type(uint112).max));

        // Alice deposits WETH
        _depositWETH(collateralDeposited);

        // Alice mints APE
        vm.prank(alice);
        uint256 amount = vault.mint(
            false,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Check reserves
        VaultStructs.Reserves memory reserves = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        _verifyAmountsMintTEA(
            systemParams,
            collateralDeposited,
            VaultStructs.Reserves(0, 0, 0),
            reserves,
            amount,
            Balances(0, 0, 0, 0, 0)
        );
    }

    function testFuzz_mint1stTimeDepositInsufficient(
        SystemParams calldata systemParams,
        uint144 collateralDeposited,
        int8 leverageTier,
        bool isAPE
    ) public Initialize(systemParams, leverageTier) {
        collateralDeposited = uint144(_bound(collateralDeposited, 0, 1));

        // Alice deposits WETH
        _depositWETH(collateralDeposited);

        // Alice mints APE
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(
            isAPE,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );
    }

    function testFuzz_mintAPE(
        SystemParams calldata systemParams,
        uint144 collateralDeposited,
        int8 leverageTier,
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) public Initialize(systemParams, leverageTier) {
        // Constraint vault paramereters
        vaultState.vaultId = VAULT_ID;
        vaultState.reserve = uint144(_bound(vaultState.reserve, 2, type(uint144).max));

        // Constraint balance parameters
        balances.teaSupply = uint128(_bound(balances.teaSupply, 0, SystemConstants.TEA_MAX_SUPPLY));
        balances.teaVault = uint128(_bound(balances.teaVault, 0, balances.teaSupply));
        balances.teaAlice = uint128(_bound(balances.teaAlice, 0, balances.teaSupply - balances.teaVault));
        balances.apeAlice = _bound(balances.apeAlice, 0, balances.apeSupply);

        // Set state
        _setState(vaultState, balances);

        // Get reserves before minting
        VaultStructs.Reserves memory reservesPre = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Constraint so it doesn't overflow tokenState.collectedFees
        collateralDeposited = uint144(_bound(collateralDeposited, 0, uint256(10) * type(uint112).max));

        // Constraint so it doesn't overflow tokenState.total
        collateralDeposited = uint144(_bound(collateralDeposited, 0, type(uint144).max - vaultState.reserve));

        // Constraint so it doesn't overflow TEA supply
        (bool success, uint256 collateralDepositedUpperBound) = FullMath.tryMulDiv(
            reservesPre.reserveLPers,
            SystemConstants.TEA_MAX_SUPPLY - vault.totalSupply(vaultState.vaultId),
            vault.totalSupply(vaultState.vaultId)
        );
        if (success) collateralDeposited = uint144(_bound(collateralDeposited, 0, collateralDepositedUpperBound));

        // Constraint so it doesn't overflow APE supply
        (success, collateralDepositedUpperBound) = FullMath.tryMulDiv(
            reservesPre.reserveApes,
            type(uint256).max - ape.totalSupply(),
            ape.totalSupply()
        );
        if (success) collateralDeposited = uint144(_bound(collateralDeposited, 0, collateralDepositedUpperBound));

        // Alice deposits WETH
        _depositWETH(collateralDeposited);

        // Alice mints APE
        vm.prank(alice);
        uint256 amount = vault.mint(
            true,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Retrieve reserves after minting
        VaultStructs.Reserves memory reservesPost = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Verify amounts
        _verifyAmountsMintAPE(systemParams, collateralDeposited, reservesPre, reservesPost, amount, balances);
    }

    function testFuzz_mintTEA(
        SystemParams calldata systemParams,
        uint144 collateralDeposited,
        int8 leverageTier,
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) public Initialize(systemParams, leverageTier) {
        // Constraint vault paramereters
        vaultState.vaultId = VAULT_ID;
        vaultState.reserve = uint144(_bound(vaultState.reserve, 2, type(uint144).max));

        // Constraint balance parameters
        balances.teaSupply = uint128(_bound(balances.teaSupply, 0, SystemConstants.TEA_MAX_SUPPLY));
        balances.teaVault = uint128(_bound(balances.teaVault, 0, balances.teaSupply));
        balances.teaAlice = uint128(_bound(balances.teaAlice, 0, balances.teaSupply - balances.teaVault));
        balances.apeAlice = _bound(balances.apeAlice, 0, balances.apeSupply);

        // Set state
        _setState(vaultState, balances);

        // Get reserves before minting
        VaultStructs.Reserves memory reservesPre = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Constraint so it doesn't overflow tokenState.collectedFees
        collateralDeposited = uint144(_bound(collateralDeposited, 0, uint256(10) * type(uint112).max));

        // Constraint so it doesn't overflow tokenState.total
        collateralDeposited = uint144(_bound(collateralDeposited, 0, type(uint144).max - vaultState.reserve));

        // Constraint so it doesn't overflow TEA supply
        (bool success, uint256 collateralDepositedUpperBound) = FullMath.tryMulDiv(
            reservesPre.reserveLPers,
            SystemConstants.TEA_MAX_SUPPLY - vault.totalSupply(vaultState.vaultId),
            vault.totalSupply(vaultState.vaultId)
        );
        if (success) collateralDeposited = uint144(_bound(collateralDeposited, 0, collateralDepositedUpperBound));

        // Constraint so it doesn't overflow APE supply
        (success, collateralDepositedUpperBound) = FullMath.tryMulDiv(
            reservesPre.reserveApes,
            type(uint256).max - ape.totalSupply(),
            ape.totalSupply()
        );
        if (success) collateralDeposited = uint144(_bound(collateralDeposited, 0, collateralDepositedUpperBound));

        // Alice deposits WETH
        _depositWETH(collateralDeposited);

        // Alice mints APE
        vm.prank(alice);
        uint256 amount = vault.mint(
            false,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Retrieve reserves after minting
        VaultStructs.Reserves memory reservesPost = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Verify amounts
        _verifyAmountsMintTEA(systemParams, collateralDeposited, reservesPre, reservesPost, amount, balances);
    }

    function testFuzz_burnAPE(
        SystemParams calldata systemParams,
        uint256 amountToBurn,
        int8 leverageTier,
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) public Initialize(systemParams, leverageTier) {
        // Constraint vault paramereters
        vaultState.vaultId = VAULT_ID;
        vaultState.reserve = uint144(_bound(vaultState.reserve, 2, type(uint144).max));

        // Constraint balance parameters
        balances.teaSupply = uint128(_bound(balances.teaSupply, 0, SystemConstants.TEA_MAX_SUPPLY));
        balances.teaVault = uint128(_bound(balances.teaVault, 0, balances.teaSupply));
        balances.teaAlice = uint128(_bound(balances.teaAlice, 0, balances.teaSupply - balances.teaVault));
        balances.apeSupply = _bound(balances.apeAlice, 1, type(uint256).max);
        balances.apeAlice = _bound(balances.apeAlice, 0, balances.apeSupply);

        // Set state
        _setState(vaultState, balances);

        // Get reserves before minting
        VaultStructs.Reserves memory reservesPre = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Constraint so it doesn't underflow its balance
        amountToBurn = _bound(amountToBurn, 0, balances.apeAlice);

        {
            // Constraint so the collected fees doesn't overflow
            (bool success, uint256 temp) = FullMath.tryMulDiv(
                uint256(10) * type(uint112).max,
                balances.apeSupply,
                reservesPre.reserveApes
            );
            if (success) amountToBurn = _bound(amountToBurn, 0, temp);
        }

        // Constraint so it leaves at least 2 units in the reserve
        uint144 collateralOut = uint144(FullMath.mulDiv(reservesPre.reserveApes, amountToBurn, balances.apeSupply));
        (uint144 collateralWidthdrawn_, uint144 collectedFee, , ) = Fees.hiddenFeeAPE(
            collateralOut,
            systemParams.baseFee,
            vaultParams.leverageTier,
            systemParams.tax
        );
        vm.assume(vaultState.reserve >= uint256(2) + collateralWidthdrawn_ + collectedFee);

        // Sufficient condition to ensure the POL minting does not overflow the TEA max supply
        vm.assume(
            FullMath.mulDiv(collateralOut, balances.teaSupply, uint(10) * reservesPre.reserveLPers) <=
                SystemConstants.TEA_MAX_SUPPLY - balances.teaSupply
        );

        // Alice burns APE
        vm.prank(alice);
        uint144 collateralWidthdrawn = vault.burn(
            true,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier),
            amountToBurn
        );

        // Retrieve reserves after minting
        VaultStructs.Reserves memory reservesPost = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Verify amounts
        _verifyAmountsBurnAPE(systemParams, amountToBurn, reservesPre, reservesPost, collateralWidthdrawn, balances);
    }

    // TEST RESERVES BEFORE AND AFTER MINTING / BURNING

    // TEST RESERVES UPON PRICE FLUCTUATIONS

    function _verifyAmountsMintAPE(
        SystemParams calldata systemParams,
        uint144 collateralDeposited,
        VaultStructs.Reserves memory reservesPre,
        VaultStructs.Reserves memory reservesPost,
        uint256 amount,
        Balances memory balances
    ) private {
        // Verify amounts
        (uint144 collateralIn, uint144 collectedFee, uint144 lpersFee, uint144 polFee) = Fees.hiddenFeeAPE(
            collateralDeposited,
            systemParams.baseFee,
            vaultParams.leverageTier,
            systemParams.tax
        );

        // Get total reserve
        (uint144 reserve, , ) = vault.vaultStates(
            vaultParams.debtToken,
            vaultParams.collateralToken,
            vaultParams.leverageTier
        );
        assertEq(reserve, reservesPost.reserveLPers + reservesPost.reserveApes);

        // To simplify the math, no reserve is allowed to be 0
        assertGt(reservesPost.reserveApes, 0);
        assertGt(reservesPost.reserveLPers, 0);

        // Error tolerance discovered by trial-and-error
        assertApproxEqAbs(
            reservesPost.reserveApes,
            reservesPre.reserveApes + collateralIn,
            1 + reserve / 1e16,
            "Ape's reserve is wrong"
        );
        assertApproxEqAbs(
            reservesPost.reserveLPers,
            reservesPre.reserveLPers + lpersFee + polFee,
            1 + reserve / 1e16,
            "LPers's reserve is wrong"
        );

        // Verify token state
        {
            (uint112 collectedFees, uint144 total) = vault.tokenStates(vaultParams.collateralToken);
            assertEq(collectedFees, collectedFee);
            assertEq(total, reservesPre.reserveLPers + reservesPre.reserveApes + collateralDeposited);
        }

        // Verify Alice's balances
        if (balances.apeSupply == 0) {
            assertEq(amount, collateralIn + reservesPre.reserveApes);
        } else if (reservesPre.reserveApes > 0) {
            assertEq(amount, FullMath.mulDiv(balances.apeSupply, collateralIn, reservesPre.reserveApes));
        } else {
            revert("Invalid state");
        }
        assertEq(amount, ape.balanceOf(alice) - balances.apeAlice);
        assertEq(vault.balanceOf(alice, VAULT_ID), balances.teaAlice);

        // Verify POL's balances
        assertEq(ape.balanceOf(address(vault)), 0);
        amount = vault.balanceOf(address(vault), VAULT_ID) - balances.teaVault;
        if (polFee == 0) {
            assertEq(amount, 0);
        } else if (balances.teaSupply > 0) {
            if (reservesPre.reserveLPers + lpersFee > 0) {
                assertEq(amount, FullMath.mulDiv(balances.teaSupply, polFee, reservesPre.reserveLPers + lpersFee));
            } else {
                revert("Invalid state");
            }
        }
    }

    function _verifyAmountsBurnAPE(
        SystemParams calldata systemParams,
        uint256 amount,
        VaultStructs.Reserves memory reservesPre,
        VaultStructs.Reserves memory reservesPost,
        uint144 collateralWidthdrawn,
        Balances memory balances
    ) private {
        uint144 collateralWidthdrawn_;
        uint144 collectedFee;
        uint144 lpersFee;
        uint144 polFee;

        {
            // Compute amount of collateral
            uint144 collateralOut = uint144(FullMath.mulDiv(reservesPre.reserveApes, amount, balances.apeSupply));

            // Verify amounts
            (collateralWidthdrawn_, collectedFee, lpersFee, polFee) = Fees.hiddenFeeAPE(
                collateralOut,
                systemParams.baseFee,
                vaultParams.leverageTier,
                systemParams.tax
            );
            reservesPre.reserveApes -= collateralOut;
        }
        assertEq(collateralWidthdrawn, collateralWidthdrawn_);

        // Get total reserve
        (uint144 reserve, , ) = vault.vaultStates(
            vaultParams.debtToken,
            vaultParams.collateralToken,
            vaultParams.leverageTier
        );
        assertEq(reserve, reservesPost.reserveLPers + reservesPost.reserveApes);

        // To simplify the math, no reserve is allowed to be 0
        assertGt(reservesPost.reserveApes, 0);
        assertGt(reservesPost.reserveLPers, 0);

        // Error tolerance discovered by trial-and-error
        assertApproxEqAbs(
            reservesPost.reserveApes,
            reservesPre.reserveApes,
            1 + reserve / 1e12,
            "Ape's reserve is wrong"
        );
        reservesPre.reserveLPers += lpersFee;
        assertApproxEqAbs(
            reservesPost.reserveLPers,
            reservesPre.reserveLPers + polFee,
            1 + reserve / 1e12,
            "LPers's reserve is wrong"
        );

        // Verify token state
        {
            (uint112 collectedFees, uint144 total) = vault.tokenStates(vaultParams.collateralToken);
            assertEq(collectedFees, collectedFee);
            assertEq(total, reservesPre.reserveLPers + polFee + reservesPre.reserveApes + collectedFee, "1");
        }

        // Verify Alice's balances
        assertEq(amount, balances.apeAlice - ape.balanceOf(alice));
        assertEq(vault.balanceOf(alice, VAULT_ID), balances.teaAlice);

        // Verify POL's balances
        assertEq(ape.balanceOf(address(vault)), 0);
        amount = vault.balanceOf(address(vault), VAULT_ID) - balances.teaVault;
        if (polFee == 0) {
            assertEq(amount, 0);
        } else if (balances.teaSupply > 0) {
            if (reservesPre.reserveLPers > 0) {
                assertEq(amount, FullMath.mulDiv(balances.teaSupply, polFee, reservesPre.reserveLPers));
            } else {
                revert("Invalid state");
            }
        }
    }

    function _verifyAmountsMintTEA(
        SystemParams calldata systemParams,
        uint144 collateralDeposited,
        VaultStructs.Reserves memory reservesPre,
        VaultStructs.Reserves memory reservesPost,
        uint256 amount,
        Balances memory balances
    ) private {
        // Verify amounts
        (uint144 collateralIn, uint144 collectedFee, uint144 lpersFee, uint144 polFee) = Fees.hiddenFeeTEA(
            collateralDeposited,
            systemParams.lpFee,
            systemParams.tax
        );

        // Get total reserve
        (uint144 reserve, , ) = vault.vaultStates(
            vaultParams.debtToken,
            vaultParams.collateralToken,
            vaultParams.leverageTier
        );
        assertEq(reserve, reservesPost.reserveLPers + reservesPost.reserveApes);

        // To simplify the math, no reserve is allowed to be 0
        assertGt(reservesPost.reserveApes, 0);
        assertGt(reservesPost.reserveLPers, 0);

        // Error tolerance discovered by trial-and-error
        assertApproxEqAbs(
            reservesPost.reserveLPers,
            reservesPre.reserveLPers + collateralIn + lpersFee + polFee,
            1 + reserve / 1e12,
            "LPers's reserve is wrong"
        );
        assertApproxEqAbs(
            reservesPost.reserveApes,
            reservesPre.reserveApes,
            1 + reserve / 1e12,
            "Apes's reserve has changed"
        );

        // Verify token state
        {
            (uint112 collectedFees, uint144 total) = vault.tokenStates(vaultParams.collateralToken);
            assertEq(collectedFees, collectedFee);
            assertEq(total, reservesPre.reserveLPers + reservesPre.reserveApes + collateralDeposited);
        }

        // Verify POL's balances
        uint128 amountPol = uint128(vault.balanceOf(address(vault), VAULT_ID) - balances.teaVault);
        reservesPre.reserveLPers += lpersFee;
        if (balances.teaSupply == 0) {
            if (polFee + reservesPre.reserveLPers == 0) {
                assertEq(amountPol, 0, "Amount of POL is not 0");
            }
        } else if (reservesPre.reserveLPers == 0) {
            revert("Invalid state");
        } else {
            assertEq(amountPol, FullMath.mulDiv(balances.teaSupply, polFee, reservesPre.reserveLPers));
        }
        assertEq(ape.balanceOf(address(vault)), 0, "Vault's APE balance is not 0");

        // Verify Alice's balances
        balances.teaSupply += amountPol;
        reservesPre.reserveLPers += polFee;
        if (collateralIn == 0) {
            assertEq(amount, 0, "1");
        } else if (balances.teaSupply > 0) {
            assertEq(amount, FullMath.mulDiv(balances.teaSupply, collateralIn, reservesPre.reserveLPers));
        }
        assertEq(amount, vault.balanceOf(alice, VAULT_ID) - balances.teaAlice, "3");
        assertEq(ape.balanceOf(alice) - balances.apeAlice, 0, "4");
    }

    function _setState(VaultStructs.VaultState memory vaultState, Balances memory balances) private {
        // Find slot of the vaultStates mapping
        // vaultStates mapping is at slot 7
        bytes32 slot = keccak256(
            abi.encode(
                vaultParams.leverageTier,
                keccak256(
                    abi.encode(
                        vaultParams.collateralToken,
                        keccak256(
                            abi.encode(
                                vaultParams.debtToken,
                                uint256(7) // slot of vaultStates
                            )
                        )
                    )
                )
            )
        );

        // Pack the vault state
        bytes32 vaultStatePacked = bytes32(
            abi.encodePacked(vaultState.vaultId, vaultState.tickPriceSatX42, vaultState.reserve)
        );

        // Store the vault state
        vm.store(address(vault), slot, vaultStatePacked);

        // Verify the operation was correct
        (uint144 reserve, int64 tickPriceSatX42, uint48 vaultId) = vault.vaultStates(
            vaultParams.debtToken,
            vaultParams.collateralToken,
            vaultParams.leverageTier
        );

        assertEq(reserve, vaultState.reserve, "Wrong slot used by vm.store");
        assertEq(tickPriceSatX42, vaultState.tickPriceSatX42, "Wrong slot used by vm.store");
        assertEq(vaultId, vaultState.vaultId, "Wrong slot used by vm.store");

        // Set tokenStates
        slot = keccak256(
            abi.encode(
                vaultParams.collateralToken,
                uint256(8) // slot of tokenStates
            )
        );
        vm.store(address(vault), slot, bytes32(abi.encodePacked(vaultState.reserve, uint112(0))));
        (uint112 collectedFees, uint144 total) = vault.tokenStates(vaultParams.collateralToken);
        assertEq(collectedFees, 0, "Wrong slot used by vm.store");
        assertEq(total, vaultState.reserve, "Wrong slot used by vm.store");

        // Deposit the collateral
        deal(address(vault), vaultState.reserve);
        vm.prank(address(vault));
        IWETH9(vaultParams.collateralToken).deposit{value: vaultState.reserve}();

        // Set the total supply of APE
        vm.store(address(ape), bytes32(uint256(2)), bytes32(balances.apeSupply));
        assertEq(ape.totalSupply(), balances.apeSupply, "Wrong slot used by vm.store");

        // Set the Alice's APE balance
        slot = keccak256(
            abi.encode(
                alice,
                uint256(3) // slot of balanceOf
            )
        );
        vm.store(address(ape), slot, bytes32(balances.apeAlice));
        assertEq(ape.balanceOf(alice), balances.apeAlice, "Wrong slot used by vm.store");

        // Set the total supply of TEA and the vault balance
        slot = keccak256(
            abi.encode(
                uint256(vaultState.vaultId),
                uint256(4) // Slot of totalSupplyAndBalanceVault
            )
        );
        vm.store(address(vault), slot, bytes32(abi.encodePacked(balances.teaVault, balances.teaSupply)));
        assertEq(vault.totalSupply(vaultState.vaultId), balances.teaSupply, "Wrong slot used by vm.store");
        assertEq(vault.balanceOf(address(vault), vaultState.vaultId), balances.teaVault, "Wrong slot used by vm.store");

        // Set the Alice's TEA balance
        slot = keccak256(
            abi.encode(
                uint256(vaultState.vaultId),
                keccak256(
                    abi.encode(
                        alice,
                        uint256(3) // slot of balances
                    )
                )
            )
        );
        vm.store(address(vault), slot, bytes32(uint256(balances.teaAlice)));
        assertEq(vault.balanceOf(alice, vaultState.vaultId), balances.teaAlice, "Wrong slot used by vm.store");
    }
}

// TEST MULTIPLE MINTS ON DIFFERENT VAULTS WITH SAME COLLATERAL

// INVARIANT TEST USING REAL DATA AND USING CONSTANT RANDOM PRICES

// INVARIANT TEST WITH EXTREME PRICES
