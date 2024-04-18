// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

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
import {MockERC20} from "src/test/MockERC20.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {ABDKMathQuad} from "abdk/ABDKMathQuad.sol";
import {TickMathPrecision} from "src/libraries/TickMathPrecision.sol";

import "forge-std/Test.sol";

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

        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

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

library ExtraABDKMathQuad {
    using ABDKMathQuad for bytes16;

    function tickToFP(int64 tickX42) internal pure returns (bytes16) {
        bytes16 log2Point0001 = ABDKMathQuad.fromUInt(10001).div(ABDKMathQuad.fromUInt(10000)).log_2();
        return ABDKMathQuad.fromInt(tickX42).div(ABDKMathQuad.fromUInt(1 << 42)).mul(log2Point0001).pow_2();
    }
}

library BonusABDKMathQuad {
    using ABDKMathQuad for bytes16;

    // x^y
    function pow(bytes16 x, bytes16 y) internal pure returns (bytes16) {
        return x.log_2().mul(y).pow_2();
    }
}

contract VaultTest is Test {
    using ABDKMathQuad for bytes16;
    using ExtraABDKMathQuad for int64;
    using BonusABDKMathQuad for bytes16;

    error LeverageTierOutOfRange();
    error NoUniswapPool();
    error VaultDoesNotExist();

    struct SystemParams {
        uint16 baseFee;
        uint8 lpFee;
        uint8 tax;
        int8 leverageTier;
        int64 tickPriceX42;
    }

    struct Balances {
        uint128 teaVault;
        uint128 teaAlice;
        uint128 teaSupply;
        uint256 apeAlice;
        uint256 apeSupply;
    }

    struct InputsOutputs {
        uint144 collateral;
        uint256 collateralSupply;
        uint256 amount;
    }

    uint48 constant VAULT_ID = 1;
    bytes16 immutable ONE;

    address public systemControl = vm.addr(1);
    address public sir = vm.addr(2);
    address public oracle;

    Vault public vault;
    IERC20 public ape;

    address public alice = vm.addr(3);

    VaultStructs.VaultParameters public vaultParams;

    constructor() {
        ONE = ABDKMathQuad.fromUInt(1);
    }

    function setUp() public {
        vaultParams.debtToken = address(new MockERC20("Debt Token", "DBT", 6));
        vaultParams.collateralToken = address(new MockERC20("Collateral", "COL", 18));

        // vm.createSelectFork("mainnet", 18128102);

        // Deploy oracle
        oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

        // Mock oracle initialization
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(Oracle.initialize.selector, vaultParams.collateralToken, vaultParams.debtToken),
            abi.encode()
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(Oracle.initialize.selector, vaultParams.debtToken, vaultParams.collateralToken),
            abi.encode()
        );

        // Deploy vault
        vault = new Vault(systemControl, sir, oracle);

        // Derive APE address
        ape = IERC20(SaltedAddress.getAddress(address(vault), VAULT_ID));
    }

    modifier Initialize(SystemParams calldata systemParams, VaultStructs.Reserves memory reservesPre) {
        {
            vaultParams.leverageTier = int8(
                _bound(systemParams.leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER)
            );

            // Initialize vault
            vault.initialize(
                VaultStructs.VaultParameters(
                    vaultParams.debtToken,
                    vaultParams.collateralToken,
                    vaultParams.leverageTier
                )
            );

            // Mock oracle prices
            reservesPre.tickPriceX42 = int64(
                _bound(systemParams.tickPriceX42, int64(TickMath.MIN_TICK) << 42, int64(TickMath.MAX_TICK) << 42)
            );
            vm.mockCall(
                oracle,
                abi.encodeWithSelector(Oracle.getPrice.selector, vaultParams.collateralToken, vaultParams.debtToken),
                abi.encode(reservesPre.tickPriceX42)
            );
            vm.mockCall(
                oracle,
                abi.encodeWithSelector(
                    Oracle.updateOracleState.selector,
                    vaultParams.collateralToken,
                    vaultParams.debtToken
                ),
                abi.encode(reservesPre.tickPriceX42)
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
        }

        _;
    }

    modifier ConstraintAmounts(
        bool isFirst,
        bool isMint,
        InputsOutputs memory inputsOutputs,
        VaultStructs.Reserves memory reservesPre,
        Balances memory balances
    ) {
        {
            VaultStructs.VaultState memory vaultState;
            if (!isFirst) {
                reservesPre.reserveApes = uint144(_bound(reservesPre.reserveApes, 1, type(uint144).max - 1));
                reservesPre.reserveLPers = uint144(
                    _bound(reservesPre.reserveLPers, 1, type(uint144).max - reservesPre.reserveApes)
                );

                // Derive vault state

                vaultState = _deriveVaultState(reservesPre);
            }

            if (isMint) {
                // Sufficient condition for the minting to not overflow the TEA max supply
                inputsOutputs.collateral = uint144(
                    _bound(inputsOutputs.collateral, isFirst ? 2 : 0, uint256(10) * type(uint112).max)
                );

                inputsOutputs.collateral = uint144(
                    _bound(inputsOutputs.collateral, 0, type(uint144).max - vaultState.reserve)
                );

                inputsOutputs.amount = 0;
            } else {
                inputsOutputs.collateral = 0;

                balances.apeSupply = _bound(balances.apeSupply, 1, type(uint256).max); // APE supply must be at least 1 for mintAPE to work
                balances.teaSupply = uint128(_bound(balances.teaSupply, 1, SystemConstants.TEA_MAX_SUPPLY)); // TEA supply must be at least 1 for mintTEA to work
            }

            // Constraint balance parameters
            balances.teaSupply = uint128(_bound(balances.teaSupply, 0, SystemConstants.TEA_MAX_SUPPLY));
            balances.teaVault = uint128(_bound(balances.teaVault, 0, balances.teaSupply));
            balances.teaAlice = uint128(_bound(balances.teaAlice, 0, balances.teaSupply - balances.teaVault));
            balances.apeAlice = _bound(balances.apeAlice, 0, balances.apeSupply);

            // Collateral supply must be larger than the deposited amount
            inputsOutputs.collateralSupply = _bound(
                inputsOutputs.collateralSupply,
                inputsOutputs.collateral + vaultState.reserve,
                type(uint256).max
            );

            // Mint collateral supply
            MockERC20(vaultParams.collateralToken).mint(alice, inputsOutputs.collateralSupply);

            // Fill up reserve
            vm.prank(alice);
            MockERC20(vaultParams.collateralToken).transfer(address(vault), vaultState.reserve);

            if (!isFirst) {
                // Set state
                _setState(vaultState, balances);
            }
        }

        _;
    }

    function testFuzz_mintAPE1stTime(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs
    )
        public
        Initialize(systemParams, VaultStructs.Reserves(0, 0, 0))
        ConstraintAmounts(true, true, inputsOutputs, VaultStructs.Reserves(0, 0, 0), Balances(0, 0, 0, 0, 0))
    {
        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), inputsOutputs.collateral);

        // Alice mints APE
        vm.prank(alice);
        inputsOutputs.amount = vault.mint(
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
            inputsOutputs,
            VaultStructs.Reserves(0, 0, 0),
            reserves,
            Balances(0, 0, 0, 0, 0)
        );
    }

    function testFuzz_mintTEA1stTime(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs
    )
        public
        Initialize(systemParams, VaultStructs.Reserves(0, 0, 0))
        ConstraintAmounts(true, true, inputsOutputs, VaultStructs.Reserves(0, 0, 0), Balances(0, 0, 0, 0, 0))
    {
        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), inputsOutputs.collateral);

        // Alice mints APE
        vm.prank(alice);
        inputsOutputs.amount = vault.mint(
            false,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Check reserves
        VaultStructs.Reserves memory reserves = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        _verifyAmountsMintTEA(
            systemParams,
            inputsOutputs,
            VaultStructs.Reserves(0, 0, 0),
            reserves,
            Balances(0, 0, 0, 0, 0)
        );
    }

    function testFuzz_mint1stTimeDepositInsufficient(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        bool isAPE
    )
        public
        Initialize(systemParams, VaultStructs.Reserves(0, 0, 0))
        ConstraintAmounts(true, true, inputsOutputs, VaultStructs.Reserves(0, 0, 0), Balances(0, 0, 0, 0, 0))
    {
        inputsOutputs.collateral = uint144(_bound(inputsOutputs.collateral, 0, 1));

        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), inputsOutputs.collateral);

        // Alice mints APE
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(
            isAPE,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );
    }

    function testFuzz_recursiveStateSave(
        SystemParams calldata systemParams,
        VaultStructs.Reserves memory reservesPre,
        Balances memory balances
    )
        public
        Initialize(systemParams, reservesPre)
        ConstraintAmounts(false, false, InputsOutputs(0, 0, 0), reservesPre, balances)
    {
        VaultStructs.Reserves memory reservesPost = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        assertEq(reservesPre.tickPriceX42, reservesPost.tickPriceX42);

        (uint144 reserve, int64 tickPriceSatX42, ) = vault.vaultStates(
            vaultParams.debtToken,
            vaultParams.collateralToken,
            vaultParams.leverageTier
        );

        // In power zone error favors apes and in saturation zone error favors LPers
        if (
            // Condition to avoid OF/UFing tickPriceSatX42
            reservesPre.reserveApes > 1 &&
            reservesPost.reserveApes > 1 &&
            reservesPre.reserveLPers > 1 &&
            reservesPost.reserveLPers > 1
        ) {
            assertApproxEqAbs(
                reservesPre.reserveApes,
                reservesPost.reserveApes,
                1 + reserve / 1e16,
                "Rounding error in reserveApes too large"
            );
            assertApproxEqAbs(
                reservesPre.reserveLPers,
                reservesPost.reserveLPers,
                1 + reserve / 1e16,
                "Rounding error in reserveLPers too large"
            );

            if (reservesPre.tickPriceX42 < tickPriceSatX42) {
                assertLe(reservesPre.reserveApes, reservesPost.reserveApes, "In power zone apes should increase");
                assertGe(reservesPre.reserveLPers, reservesPost.reserveLPers, "In power zone LPers should decrease");
            } else if (reservesPre.tickPriceX42 > tickPriceSatX42) {
                assertGe(reservesPre.reserveApes, reservesPost.reserveApes, "In saturation zone apes should decrease");
                assertLe(
                    reservesPre.reserveLPers,
                    reservesPost.reserveLPers,
                    "In saturation zone LPers should increase"
                );
            }
        } else {
            assertApproxEqAbs(reservesPre.reserveApes, reservesPost.reserveApes, 1 + reserve / 1e6);
            assertApproxEqAbs(reservesPre.reserveLPers, reservesPost.reserveLPers, 1 + reserve / 1e6);
        }
    }

    function testFuzz_mintAPE(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.Reserves memory reservesPre,
        Balances memory balances
    )
        public
        Initialize(systemParams, reservesPre)
        ConstraintAmounts(false, true, inputsOutputs, reservesPre, balances)
    {
        reservesPre = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        {
            // Constraint so it doesn't overflow TEA supply
            (bool success, uint256 collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reservesPre.reserveLPers,
                SystemConstants.TEA_MAX_SUPPLY - vault.totalSupply(VAULT_ID),
                vault.totalSupply(VAULT_ID)
            );
            if (success)
                inputsOutputs.collateral = uint144(_bound(inputsOutputs.collateral, 0, collateralDepositedUpperBound));

            // Constraint so it doesn't overflow APE supply
            (success, collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reservesPre.reserveApes,
                type(uint256).max - ape.totalSupply(),
                ape.totalSupply()
            );
            if (success)
                inputsOutputs.collateral = uint144(_bound(inputsOutputs.collateral, 0, collateralDepositedUpperBound));
        }

        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), inputsOutputs.collateral);

        // Alice mints APE
        vm.prank(alice);
        inputsOutputs.amount = vault.mint(
            true,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Retrieve reserves after minting
        VaultStructs.Reserves memory reservesPost = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Verify amounts
        _verifyAmountsMintAPE(systemParams, inputsOutputs, reservesPre, reservesPost, balances);
    }

    function testFuzz_mintTEA(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.Reserves memory reservesPre,
        Balances memory balances
    )
        public
        Initialize(systemParams, reservesPre)
        ConstraintAmounts(false, true, inputsOutputs, reservesPre, balances)
    {
        // Get reserves before minting
        reservesPre = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        {
            // Constraint so it doesn't overflow TEA supply
            (bool success, uint256 collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reservesPre.reserveLPers,
                SystemConstants.TEA_MAX_SUPPLY - vault.totalSupply(VAULT_ID),
                vault.totalSupply(VAULT_ID)
            );
            if (success)
                inputsOutputs.collateral = uint144(_bound(inputsOutputs.collateral, 0, collateralDepositedUpperBound));

            // Constraint so it doesn't overflow APE supply
            (success, collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reservesPre.reserveApes,
                type(uint256).max - ape.totalSupply(),
                ape.totalSupply()
            );
            if (success)
                inputsOutputs.collateral = uint144(_bound(inputsOutputs.collateral, 0, collateralDepositedUpperBound));
        }

        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), inputsOutputs.collateral);

        // Alice mints TEA
        vm.prank(alice);
        inputsOutputs.amount = vault.mint(
            false,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Retrieve reserves after minting
        VaultStructs.Reserves memory reservesPost = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Verify amounts
        _verifyAmountsMintTEA(systemParams, inputsOutputs, reservesPre, reservesPost, balances);
    }

    function testFuzz_burnAPE(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.Reserves memory reservesPre,
        Balances memory balances
    )
        public
        Initialize(systemParams, reservesPre)
        ConstraintAmounts(false, false, inputsOutputs, reservesPre, balances)
    {
        reservesPre = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Constraint so it doesn't underflow its balance
        inputsOutputs.amount = _bound(inputsOutputs.amount, 0, balances.apeAlice);

        {
            // Constraint so the collected fees doesn't overflow
            (bool success, uint256 amountToBurnUpperbound) = FullMath.tryMulDiv(
                uint256(10) * type(uint112).max,
                balances.apeSupply,
                reservesPre.reserveApes
            );
            if (success) inputsOutputs.amount = _bound(inputsOutputs.amount, 0, amountToBurnUpperbound);
        }

        // Constraint so it leaves at least 2 units in the reserve
        {
            uint144 collateralOut = _constraintReserveBurnAPE(systemParams, reservesPre, inputsOutputs, balances);

            // Sufficient condition to ensure the POL minting does not overflow the TEA max supply
            uint temp = FullMath.mulDiv(collateralOut, balances.teaSupply, uint(10) * reservesPre.reserveLPers);
            vm.assume(temp <= SystemConstants.TEA_MAX_SUPPLY - balances.teaSupply);
        }

        // Alice burns APE
        vm.prank(alice);
        inputsOutputs.collateral = vault.burn(
            true,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier),
            inputsOutputs.amount
        );

        // Retrieve reserves after minting
        VaultStructs.Reserves memory reservesPost = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Verify amounts
        _verifyAmountsBurnAPE(systemParams, inputsOutputs, reservesPre, reservesPost, balances);
    }

    function testFuzz_burnTEA(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.Reserves memory reservesPre,
        Balances memory balances
    )
        public
        Initialize(systemParams, reservesPre)
        ConstraintAmounts(false, false, inputsOutputs, reservesPre, balances)
    {
        reservesPre = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Constraint so it doesn't underflow its balance
        inputsOutputs.amount = _bound(inputsOutputs.amount, 0, balances.teaAlice);

        // Constraint so the collected fees doesn't overflow
        {
            (bool success, uint256 amountToBurnUpperbound) = FullMath.tryMulDiv(
                uint256(10) * type(uint112).max,
                balances.teaSupply,
                reservesPre.reserveLPers
            );
            if (success) inputsOutputs.amount = _bound(inputsOutputs.amount, 0, amountToBurnUpperbound);
        }

        // Constraint so it leaves at least 2 units in the reserve
        _constraintReserveBurnTEA(systemParams, reservesPre, inputsOutputs, balances);

        // Alice burns TEA
        vm.prank(alice);
        inputsOutputs.collateral = vault.burn(
            false,
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier),
            inputsOutputs.amount
        );

        // Retrieve reserves after minting
        VaultStructs.Reserves memory reservesPost = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Verify amounts
        _verifyAmountsBurnTEA(systemParams, inputsOutputs, reservesPre, reservesPost, balances);
    }

    function testFuzz_mintWrongVaultParameters(
        bool isFirst,
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.Reserves memory reservesPre,
        Balances memory balances,
        VaultStructs.VaultParameters memory vaultParams_
    )
        public
        Initialize(systemParams, reservesPre)
        ConstraintAmounts(isFirst, true, inputsOutputs, reservesPre, balances)
    {
        vm.assume( // Ensure the vault does not exist
            vaultParams.debtToken != vaultParams_.debtToken ||
                vaultParams.collateralToken != vaultParams_.collateralToken ||
                vaultParams.leverageTier != vaultParams_.leverageTier
        );

        // Mock oracle prices
        int64 tickPriceX42 = int64(
            _bound(systemParams.tickPriceX42, int64(TickMath.MIN_TICK) << 42, int64(TickMath.MAX_TICK) << 42)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(Oracle.getPrice.selector, vaultParams_.collateralToken, vaultParams_.debtToken),
            abi.encode(tickPriceX42)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                Oracle.updateOracleState.selector,
                vaultParams_.collateralToken,
                vaultParams_.debtToken
            ),
            abi.encode(tickPriceX42)
        );

        // Get reserves before minting
        reservesPre = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        {
            // Constraint so it doesn't overflow TEA supply
            (bool success, uint256 collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reservesPre.reserveLPers,
                SystemConstants.TEA_MAX_SUPPLY - vault.totalSupply(VAULT_ID),
                vault.totalSupply(VAULT_ID)
            );
            if (success)
                inputsOutputs.collateral = uint144(_bound(inputsOutputs.collateral, 0, collateralDepositedUpperBound));

            // Constraint so it doesn't overflow APE supply
            (success, collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reservesPre.reserveApes,
                type(uint256).max - ape.totalSupply(),
                ape.totalSupply()
            );
            if (success)
                inputsOutputs.collateral = uint144(_bound(inputsOutputs.collateral, 0, collateralDepositedUpperBound));
        }

        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), inputsOutputs.collateral);

        // Alice tries to mint/burn non-existant APE or TEA
        vm.expectRevert(VaultDoesNotExist.selector);
        vm.prank(alice);
        vault.mint(isAPE, vaultParams_);
    }

    function testFuzz_burnWrongVaultParameters(
        bool isFirst,
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.Reserves memory reservesPre,
        Balances memory balances,
        VaultStructs.VaultParameters memory vaultParams_
    )
        public
        Initialize(systemParams, reservesPre)
        ConstraintAmounts(isFirst, false, inputsOutputs, reservesPre, balances)
    {
        vm.assume( // Ensure the vault does not exist
            vaultParams.debtToken != vaultParams_.debtToken ||
                vaultParams.collateralToken != vaultParams_.collateralToken ||
                vaultParams.leverageTier != vaultParams_.leverageTier
        );

        // Mock oracle prices
        int64 tickPriceX42 = int64(
            _bound(systemParams.tickPriceX42, int64(TickMath.MIN_TICK) << 42, int64(TickMath.MAX_TICK) << 42)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(Oracle.getPrice.selector, vaultParams_.collateralToken, vaultParams_.debtToken),
            abi.encode(tickPriceX42)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                Oracle.updateOracleState.selector,
                vaultParams_.collateralToken,
                vaultParams_.debtToken
            ),
            abi.encode(tickPriceX42)
        );

        // Get reserves before minting
        reservesPre = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        if (isAPE) {
            // Constraint so it doesn't underflow its balance
            inputsOutputs.amount = _bound(inputsOutputs.amount, 0, balances.apeAlice);

            {
                // Constraint so the collected fees doesn't overflow
                (bool success, uint256 amountToBurnUpperbound) = FullMath.tryMulDiv(
                    uint256(10) * type(uint112).max,
                    balances.apeSupply,
                    reservesPre.reserveApes
                );
                if (success) inputsOutputs.amount = _bound(inputsOutputs.amount, 0, amountToBurnUpperbound);
            }

            // Constraint so it leaves at least 2 units in the reserve
            {
                uint144 collateralOut = _constraintReserveBurnAPE(systemParams, reservesPre, inputsOutputs, balances);

                // Sufficient condition to ensure the POL minting does not overflow the TEA max supply
                uint temp = FullMath.mulDiv(collateralOut, balances.teaSupply, uint(10) * reservesPre.reserveLPers);
                vm.assume(temp <= SystemConstants.TEA_MAX_SUPPLY - balances.teaSupply);
            }
        } else {
            // Constraint so it doesn't underflow its balance
            inputsOutputs.amount = _bound(inputsOutputs.amount, 0, balances.teaAlice);

            // Constraint so the collected fees doesn't overflow
            {
                (bool success, uint256 amountToBurnUpperbound) = FullMath.tryMulDiv(
                    uint256(10) * type(uint112).max,
                    balances.teaSupply,
                    reservesPre.reserveLPers
                );
                if (success) inputsOutputs.amount = _bound(inputsOutputs.amount, 0, amountToBurnUpperbound);
            }

            // Constraint so it leaves at least 2 units in the reserve
            _constraintReserveBurnTEA(systemParams, reservesPre, inputsOutputs, balances);
        }

        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), inputsOutputs.collateral);

        // Alice tries to mint/burn non-existant APE or TEA
        vm.expectRevert(VaultDoesNotExist.selector);
        vm.prank(alice);
        vault.mint(isAPE, vaultParams_);
    }

    function testFuzz_priceFluctuation(
        SystemParams calldata systemParams,
        VaultStructs.Reserves memory reservesPre,
        Balances memory balances,
        int64 newTickPriceX42
    )
        public
        Initialize(systemParams, reservesPre)
        ConstraintAmounts(false, true, InputsOutputs(0, 0, 0), reservesPre, balances)
    {
        // Starting price
        int64 tickPriceX42 = int64(
            _bound(systemParams.tickPriceX42, int64(TickMath.MIN_TICK) << 42, int64(TickMath.MAX_TICK) << 42)
        );

        // New price
        newTickPriceX42 = int64(
            _bound(newTickPriceX42, int64(TickMath.MIN_TICK) << 42, int64(TickMath.MAX_TICK) << 42)
        );

        // Mock oracle price
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(Oracle.getPrice.selector, vaultParams.collateralToken, vaultParams.debtToken),
            abi.encode(newTickPriceX42)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                Oracle.updateOracleState.selector,
                vaultParams.collateralToken,
                vaultParams.debtToken
            ),
            abi.encode(newTickPriceX42)
        );

        // Retrieve reserves after price fluctuation
        VaultStructs.Reserves memory reservesPost = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Get vault state
        VaultStructs.VaultState memory vaultState;
        {
            (uint144 reserve, int64 tickPriceSatX42, ) = vault.vaultStates(
                vaultParams.debtToken,
                vaultParams.collateralToken,
                vaultParams.leverageTier
            );

            vaultState = VaultStructs.VaultState(reserve, tickPriceSatX42, VAULT_ID);
        }

        if (tickPriceX42 < vaultState.tickPriceSatX42 && newTickPriceX42 < vaultState.tickPriceSatX42) {
            // Price remains in the Power Zone
            assertInPowerZone(vaultState, reservesPre, reservesPost, tickPriceX42, newTickPriceX42);
        } else if (tickPriceX42 > vaultState.tickPriceSatX42 && newTickPriceX42 >= vaultState.tickPriceSatX42) {
            // Price remains in the Saturation Zone
            assertInSaturationZone(vaultState, reservesPre, reservesPost, tickPriceX42, newTickPriceX42);
        } else if (tickPriceX42 < vaultState.tickPriceSatX42 && newTickPriceX42 >= vaultState.tickPriceSatX42) {
            // Price goes from the Power Zone to the Saturation Zone
            assertPowerToSaturationZone(vaultState, reservesPre, reservesPost, tickPriceX42, newTickPriceX42);
        } else if (tickPriceX42 > vaultState.tickPriceSatX42 && newTickPriceX42 < vaultState.tickPriceSatX42) {
            // Price goes from the Saturation Zone to the Power Zone
            assertSaturationToPowerZone(vaultState, reservesPre, reservesPost, tickPriceX42, newTickPriceX42);
        }
    }

    /////////////////////////////////////////////////////////////////////////

    function assertInPowerZone(
        VaultStructs.VaultState memory vaultState,
        VaultStructs.Reserves memory reservesPre,
        VaultStructs.Reserves memory reservesPost,
        int64 tickPriceX42,
        int64 newTickPriceX42
    ) internal {
        bytes16 leverageRatioSub1 = ABDKMathQuad.fromInt(vaultParams.leverageTier).pow_2();
        bytes16 leveragedGain = newTickPriceX42.tickToFP().div(tickPriceX42.tickToFP()).pow(leverageRatioSub1);
        uint256 newReserveApes = ABDKMathQuad.fromUInt(reservesPre.reserveApes).mul(leveragedGain).toUInt();

        console.log("Old tick price, new tick price, tick price sat:");
        console.logInt(tickPriceX42);
        console.logInt(newTickPriceX42);
        console.logInt(vaultState.tickPriceSatX42);
        uint256 err;
        if (
            // Condition to avoid OF/UFing tickPriceSatX42
            vaultState.tickPriceSatX42 != type(int64).min && vaultState.tickPriceSatX42 != type(int64).max
        ) err = 2 + vaultState.reserve / 1e16;
        else err = 2 + vaultState.reserve / 1e7;

        assertApproxEqAbs(vaultState.reserve - newReserveApes, reservesPost.reserveLPers, err);
        assertApproxEqAbs(newReserveApes, reservesPost.reserveApes, err);
    }

    function assertInSaturationZone(
        VaultStructs.VaultState memory vaultState,
        VaultStructs.Reserves memory reservesPre,
        VaultStructs.Reserves memory reservesPost,
        int64 tickPriceX42,
        int64 newTickPriceX42
    ) internal {
        uint256 newReserveLPers = ABDKMathQuad
            .fromUInt(reservesPre.reserveLPers)
            .mul(tickPriceX42.tickToFP())
            .div(newTickPriceX42.tickToFP())
            .toUInt();

        uint256 err;
        if (
            // Condition to avoid OF/UFing tickPriceSatX42
            vaultState.tickPriceSatX42 != type(int64).min && vaultState.tickPriceSatX42 != type(int64).max
        ) err = 2 + vaultState.reserve / 1e16;
        else err = 2 + vaultState.reserve / 1e7;

        assertApproxEqAbs(vaultState.reserve - newReserveLPers, reservesPost.reserveApes, err);
        assertApproxEqAbs(newReserveLPers, reservesPost.reserveLPers, err);
    }

    function assertPowerToSaturationZone(
        VaultStructs.VaultState memory vaultState,
        VaultStructs.Reserves memory reservesPre,
        VaultStructs.Reserves memory reservesPost,
        int64 tickPriceX42,
        int64 newTickPriceX42
    ) internal {
        bytes16 leverageRatioSub1 = ABDKMathQuad.fromInt(vaultParams.leverageTier).pow_2();
        bytes16 leveragedGain = vaultState.tickPriceSatX42.tickToFP().div(tickPriceX42.tickToFP()).pow(
            leverageRatioSub1
        );
        uint256 newReserveApes = ABDKMathQuad.fromUInt(reservesPre.reserveApes).mul(leveragedGain).toUInt();
        uint256 newReserveLPers = vaultState.reserve - newReserveApes;

        newReserveLPers = ABDKMathQuad
            .fromUInt(newReserveLPers)
            .mul(vaultState.tickPriceSatX42.tickToFP())
            .div(newTickPriceX42.tickToFP())
            .toUInt();
        newReserveApes = vaultState.reserve - newReserveLPers;

        uint256 err;
        if (
            // Condition to avoid OF/UFing tickPriceSatX42
            vaultState.tickPriceSatX42 != type(int64).min && vaultState.tickPriceSatX42 != type(int64).max
        ) err = 2 + vaultState.reserve / 1e16;
        else err = 2 + vaultState.reserve / 1e7;

        assertApproxEqAbs(newReserveLPers, reservesPost.reserveLPers, err);
        assertApproxEqAbs(newReserveApes, reservesPost.reserveApes, err);
    }

    function assertSaturationToPowerZone(
        VaultStructs.VaultState memory vaultState,
        VaultStructs.Reserves memory reservesPre,
        VaultStructs.Reserves memory reservesPost,
        int64 tickPriceX42,
        int64 newTickPriceX42
    ) internal {
        uint256 newReserveLPers = ABDKMathQuad
            .fromUInt(reservesPre.reserveLPers)
            .mul(tickPriceX42.tickToFP())
            .div(vaultState.tickPriceSatX42.tickToFP())
            .toUInt();
        uint256 newReserveApes = vaultState.reserve - newReserveLPers;

        bytes16 leverageRatioSub1 = ABDKMathQuad.fromInt(vaultParams.leverageTier).pow_2();
        bytes16 leveragedGain = newTickPriceX42.tickToFP().div(vaultState.tickPriceSatX42.tickToFP()).pow(
            leverageRatioSub1
        );
        newReserveApes = ABDKMathQuad.fromUInt(newReserveApes).mul(leveragedGain).toUInt();
        newReserveLPers = vaultState.reserve - newReserveApes;

        uint256 err;
        if (
            // Condition to avoid OF/UFing tickPriceSatX42
            vaultState.tickPriceSatX42 != type(int64).min && vaultState.tickPriceSatX42 != type(int64).max
        ) err = 2 + vaultState.reserve / 1e16;
        else err = 2 + vaultState.reserve / 1e7;

        assertApproxEqAbs(newReserveLPers, reservesPost.reserveLPers, err);
        assertApproxEqAbs(newReserveApes, reservesPost.reserveApes, err);
    }

    function _deriveVaultState(
        VaultStructs.Reserves memory reserves
    ) private view returns (VaultStructs.VaultState memory vaultState) {
        unchecked {
            vaultState.vaultId = VAULT_ID;
            vaultState.reserve = reserves.reserveApes + reserves.reserveLPers;
            console.log("reserve:", vaultState.reserve);

            // To ensure division by 0 does not occur when recoverying the reserves
            require(vaultState.reserve >= 2);

            // Compute tickPriceSatX42
            if (reserves.reserveApes == 0) {
                vaultState.tickPriceSatX42 = type(int64).max;
            } else if (reserves.reserveLPers == 0) {
                vaultState.tickPriceSatX42 = type(int64).min;
            } else {
                /**
                 * Decide if we are in the power or saturation zone
                 * Condition for power zone: A < (l-1) L where l=1+2^leverageTier
                 */
                uint8 absLeverageTier = vaultParams.leverageTier >= 0
                    ? uint8(vaultParams.leverageTier)
                    : uint8(-vaultParams.leverageTier);
                bool isPowerZone;
                if (vaultParams.leverageTier > 0) {
                    if (
                        uint256(reserves.reserveApes) << absLeverageTier < reserves.reserveLPers
                    ) // Cannot OF because reserveApes is an uint144, and |leverageTier|<=3
                    {
                        isPowerZone = true;
                    } else {
                        isPowerZone = false;
                    }
                } else {
                    if (
                        reserves.reserveApes < uint256(reserves.reserveLPers) << absLeverageTier
                    ) // Cannot OF because reserveApes is an uint144, and |leverageTier|<=3
                    {
                        isPowerZone = true;
                    } else {
                        isPowerZone = false;
                    }
                }

                if (isPowerZone) {
                    /**
                     * PRICE IN POWER ZONE
                     * priceSat = price*(R/(lA))^(r-1)
                     */

                    int256 tickRatioX42 = TickMathPrecision.getTickAtRatio(
                        vaultParams.leverageTier >= 0
                            ? vaultState.reserve
                            : uint256(vaultState.reserve) << absLeverageTier, // Cannot OF cuz reserve is uint144, and |leverageTier|<=3
                        (uint256(reserves.reserveApes) << absLeverageTier) + reserves.reserveApes // Cannot OF cuz reserveApes is uint144, and |leverageTier|<=3
                    );

                    // Compute saturation price
                    int256 tempTickPriceSatX42 = reserves.tickPriceX42 +
                        (
                            vaultParams.leverageTier >= 0
                                ? tickRatioX42 >> absLeverageTier
                                : tickRatioX42 << absLeverageTier
                        );

                    // Check if overflow
                    if (tempTickPriceSatX42 > type(int64).max) vaultState.tickPriceSatX42 = type(int64).max;
                    else vaultState.tickPriceSatX42 = int64(tempTickPriceSatX42);
                } else {
                    /**
                     * PRICE IN SATURATION ZONE
                     * priceSat = r*price*L/R
                     */
                    int256 tickRatioX42 = TickMathPrecision.getTickAtRatio(
                        vaultParams.leverageTier >= 0
                            ? uint256(vaultState.reserve) << absLeverageTier
                            : vaultState.reserve,
                        (uint256(reserves.reserveLPers) << absLeverageTier) + reserves.reserveLPers
                    );

                    // Compute saturation price
                    int256 tempTickPriceSatX42 = reserves.tickPriceX42 - tickRatioX42;

                    // Check if underflow
                    if (tempTickPriceSatX42 < type(int64).min) vaultState.tickPriceSatX42 = type(int64).min;
                    else vaultState.tickPriceSatX42 = int64(tempTickPriceSatX42);
                }
            }
        }
    }

    function _constraintReserveBurnAPE(
        SystemParams calldata systemParams,
        VaultStructs.Reserves memory reservesPre,
        InputsOutputs memory inputsOutputs,
        Balances memory balances
    ) private view returns (uint144 collateralOut) {
        collateralOut = uint144(FullMath.mulDiv(reservesPre.reserveApes, inputsOutputs.amount, balances.apeSupply));
        (uint144 collateralWidthdrawn_, uint144 collectedFee, , ) = Fees.hiddenFeeAPE(
            collateralOut,
            systemParams.baseFee,
            vaultParams.leverageTier,
            systemParams.tax
        );

        (uint144 reserve, , ) = vault.vaultStates(
            vaultParams.debtToken,
            vaultParams.collateralToken,
            vaultParams.leverageTier
        );

        vm.assume(reserve >= uint256(2) + collateralWidthdrawn_ + collectedFee);
    }

    function _constraintReserveBurnTEA(
        SystemParams calldata systemParams,
        VaultStructs.Reserves memory reservesPre,
        InputsOutputs memory inputsOutputs,
        Balances memory balances
    ) private view {
        uint144 collateralOut = uint144(
            FullMath.mulDiv(reservesPre.reserveLPers, inputsOutputs.amount, balances.teaSupply)
        );
        (uint144 collateralWidthdrawn_, uint144 collectedFee, , ) = Fees.hiddenFeeTEA(
            collateralOut,
            systemParams.lpFee,
            systemParams.tax
        );

        (uint144 reserve, , ) = vault.vaultStates(
            vaultParams.debtToken,
            vaultParams.collateralToken,
            vaultParams.leverageTier
        );

        vm.assume(reserve >= uint256(2) + collateralWidthdrawn_ + collectedFee);
    }

    function _verifyAmountsMintAPE(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.Reserves memory reservesPre,
        VaultStructs.Reserves memory reservesPost,
        Balances memory balances
    ) private {
        // Verify amounts
        (uint144 collateralIn, uint144 collectedFee, uint144 lpersFee, uint144 polFee) = Fees.hiddenFeeAPE(
            inputsOutputs.collateral,
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
        {
            uint256 err;
            if (
                // Condition to avoid OF/UFing tickPriceSatX42
                reservesPre.reserveApes > 1 &&
                reservesPost.reserveApes > 1 &&
                reservesPre.reserveLPers > 1 &&
                reservesPost.reserveLPers > 1
            ) err = 1 + reserve / 1e16;
            else err = 1 + reserve / 1e7;

            assertApproxEqAbs(
                reservesPost.reserveApes,
                reservesPre.reserveApes + collateralIn,
                err,
                "Ape's reserve is wrong"
            );
            assertApproxEqAbs(
                reservesPost.reserveLPers,
                reservesPre.reserveLPers + lpersFee + polFee,
                err,
                "LPers's reserve is wrong"
            );
        }

        // Verify token state
        {
            (uint112 collectedFees, uint144 total) = vault.tokenStates(vaultParams.collateralToken);
            assertEq(collectedFees, collectedFee);
            assertEq(
                total,
                reservesPre.reserveLPers + reservesPre.reserveApes + inputsOutputs.collateral,
                "Total reserves does not match"
            );
        }

        // Verify Alice's balances
        if (balances.apeSupply == 0) {
            assertEq(
                inputsOutputs.amount,
                collateralIn + reservesPre.reserveApes,
                "Minted amount is wrong when APE supply is 0"
            );
        } else if (reservesPre.reserveApes > 0) {
            assertEq(
                inputsOutputs.amount,
                FullMath.mulDiv(balances.apeSupply, collateralIn, reservesPre.reserveApes),
                "Minted amount is wrong"
            );
        } else {
            revert("Invalid state");
        }
        assertEq(inputsOutputs.amount, ape.balanceOf(alice) - balances.apeAlice);
        assertEq(vault.balanceOf(alice, VAULT_ID), balances.teaAlice);

        // Verify POL's balances
        assertEq(ape.balanceOf(address(vault)), 0);
        inputsOutputs.amount = vault.balanceOf(address(vault), VAULT_ID) - balances.teaVault;
        if (polFee == 0) {
            assertEq(inputsOutputs.amount, 0);
        } else if (balances.teaSupply > 0) {
            if (reservesPre.reserveLPers + lpersFee > 0) {
                assertEq(
                    inputsOutputs.amount,
                    FullMath.mulDiv(balances.teaSupply, polFee, reservesPre.reserveLPers + lpersFee)
                );
            } else {
                revert("Invalid state");
            }
        }
    }

    function _verifyAmountsBurnAPE(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.Reserves memory reservesPre,
        VaultStructs.Reserves memory reservesPost,
        Balances memory balances
    ) private {
        uint144 collateralWidthdrawn_;
        uint144 collectedFee;
        uint144 lpersFee;
        uint144 polFee;

        {
            // Compute amount of collateral
            uint144 collateralOut = uint144(
                FullMath.mulDiv(reservesPre.reserveApes, inputsOutputs.amount, balances.apeSupply)
            );

            // Verify amounts
            (collateralWidthdrawn_, collectedFee, lpersFee, polFee) = Fees.hiddenFeeAPE(
                collateralOut,
                systemParams.baseFee,
                vaultParams.leverageTier,
                systemParams.tax
            );
            reservesPre.reserveApes -= collateralOut;
        }
        assertEq(inputsOutputs.collateral, collateralWidthdrawn_);

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
        {
            uint256 err;
            if (
                // Condition to avoid OF/UFing tickPriceSatX42
                reservesPre.reserveApes > 1 &&
                reservesPost.reserveApes > 1 &&
                reservesPre.reserveLPers > 1 &&
                reservesPost.reserveLPers > 1
            ) err = 1 + reserve / 1e16;
            else err = 1 + reserve / 1e7;

            assertApproxEqAbs(reservesPost.reserveApes, reservesPre.reserveApes, err, "Ape's reserve is wrong");
            reservesPre.reserveLPers += lpersFee;
            assertApproxEqAbs(
                reservesPost.reserveLPers,
                reservesPre.reserveLPers + polFee,
                err,
                "LPers's reserve is wrong"
            );
        }

        // Verify token state
        {
            (uint112 collectedFees, uint144 total) = vault.tokenStates(vaultParams.collateralToken);
            assertEq(collectedFees, collectedFee);
            assertEq(total, reservesPre.reserveLPers + polFee + reservesPre.reserveApes + collectedFee, "1");
        }

        // Verify Alice's balances
        assertEq(inputsOutputs.amount, balances.apeAlice - ape.balanceOf(alice));
        assertEq(vault.balanceOf(alice, VAULT_ID), balances.teaAlice);

        // Verify POL's balances
        assertEq(ape.balanceOf(address(vault)), 0);
        inputsOutputs.amount = vault.balanceOf(address(vault), VAULT_ID) - balances.teaVault;
        if (polFee == 0) {
            assertEq(inputsOutputs.amount, 0);
        } else if (balances.teaSupply > 0) {
            if (reservesPre.reserveLPers > 0) {
                assertEq(inputsOutputs.amount, FullMath.mulDiv(balances.teaSupply, polFee, reservesPre.reserveLPers));
            } else {
                revert("Invalid state");
            }
        }
    }

    function _verifyAmountsMintTEA(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.Reserves memory reservesPre,
        VaultStructs.Reserves memory reservesPost,
        Balances memory balances
    ) private {
        // Verify amounts
        (uint144 collateralIn, uint144 collectedFee, uint144 lpersFee, uint144 polFee) = Fees.hiddenFeeTEA(
            inputsOutputs.collateral,
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
        {
            uint256 err;
            if (
                // Condition to avoid OF/UFing tickPriceSatX42
                reservesPre.reserveApes > 1 &&
                reservesPost.reserveApes > 1 &&
                reservesPre.reserveLPers > 1 &&
                reservesPost.reserveLPers > 1
            ) err = 1 + reserve / 1e16;
            else err = 1 + reserve / 1e7;

            assertApproxEqAbs(
                reservesPost.reserveLPers,
                reservesPre.reserveLPers + collateralIn + lpersFee + polFee,
                err,
                "LPers's reserve is wrong"
            );
            assertApproxEqAbs(reservesPost.reserveApes, reservesPre.reserveApes, err, "Apes's reserve has changed");
        }

        // Verify token state
        {
            (uint112 collectedFees, uint144 total) = vault.tokenStates(vaultParams.collateralToken);
            assertEq(collectedFees, collectedFee);
            assertEq(total, reservesPre.reserveLPers + reservesPre.reserveApes + inputsOutputs.collateral);
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
            assertEq(inputsOutputs.amount, 0, "1");
        } else if (balances.teaSupply > 0) {
            assertEq(inputsOutputs.amount, FullMath.mulDiv(balances.teaSupply, collateralIn, reservesPre.reserveLPers));
        }
        assertEq(inputsOutputs.amount, vault.balanceOf(alice, VAULT_ID) - balances.teaAlice, "3");
        assertEq(ape.balanceOf(alice) - balances.apeAlice, 0, "4");
    }

    function _verifyAmountsBurnTEA(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.Reserves memory reservesPre,
        VaultStructs.Reserves memory reservesPost,
        Balances memory balances
    ) private {
        uint144 collateralWidthdrawn_;
        uint144 collectedFee;
        uint144 lpersFee;
        uint144 polFee;

        {
            // Compute amount of collateral
            uint144 collateralOut = uint144(
                FullMath.mulDiv(reservesPre.reserveLPers, inputsOutputs.amount, balances.teaSupply)
            );

            // Verify amounts
            (collateralWidthdrawn_, collectedFee, lpersFee, polFee) = Fees.hiddenFeeTEA(
                collateralOut,
                systemParams.lpFee,
                systemParams.tax
            );
            reservesPre.reserveLPers -= collateralOut;
            reservesPre.reserveLPers += lpersFee;
        }
        assertEq(inputsOutputs.collateral, collateralWidthdrawn_);

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
        {
            uint256 err;
            if (
                // Condition to avoid OF/UFing tickPriceSatX42
                reservesPre.reserveApes > 1 &&
                reservesPost.reserveApes > 1 &&
                reservesPre.reserveLPers > 1 &&
                reservesPost.reserveLPers > 1
            ) err = 1 + reserve / 1e16;
            else err = 1 + reserve / 1e7;

            assertApproxEqAbs(
                reservesPost.reserveLPers,
                reservesPre.reserveLPers + polFee,
                err,
                "LPers's reserve is wrong"
            );
            assertApproxEqAbs(reservesPost.reserveApes, reservesPre.reserveApes, err, "Apes's reserve has changed");
        }

        // Verify token state
        {
            (uint112 collectedFees, uint144 total) = vault.tokenStates(vaultParams.collateralToken);
            assertEq(collectedFees, collectedFee);
            assertEq(total, reservesPre.reserveLPers + polFee + reservesPre.reserveApes + collectedFee);
        }

        // Verify Alice's balances
        assertEq(inputsOutputs.amount, balances.teaAlice - vault.balanceOf(alice, VAULT_ID));
        assertEq(ape.balanceOf(alice), balances.apeAlice);

        // Verify POL's balances
        balances.teaSupply -= uint128(inputsOutputs.amount);
        inputsOutputs.amount = uint128(vault.balanceOf(address(vault), VAULT_ID) - balances.teaVault);
        if (balances.teaSupply > 0) {
            if (reservesPre.reserveLPers == 0) {
                revert("Invalid state");
            } else {
                assertEq(inputsOutputs.amount, FullMath.mulDiv(balances.teaSupply, polFee, reservesPre.reserveLPers));
            }
        }
        assertEq(ape.balanceOf(address(vault)), 0, "Vault's APE balance is not 0");
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
        bytes32 vaultStatePacked = bytes32(abi.encodePacked(VAULT_ID, vaultState.tickPriceSatX42, vaultState.reserve));

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
        assertEq(vaultId, VAULT_ID, "Wrong slot used by vm.store");

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
                uint256(VAULT_ID),
                uint256(4) // Slot of totalSupplyAndBalanceVault
            )
        );
        vm.store(address(vault), slot, bytes32(abi.encodePacked(balances.teaVault, balances.teaSupply)));
        assertEq(vault.totalSupply(VAULT_ID), balances.teaSupply, "Wrong slot used by vm.store");
        assertEq(vault.balanceOf(address(vault), VAULT_ID), balances.teaVault, "Wrong slot used by vm.store");

        // Set the Alice's TEA balance
        slot = keccak256(
            abi.encode(
                uint256(VAULT_ID),
                keccak256(
                    abi.encode(
                        alice,
                        uint256(3) // slot of balances
                    )
                )
            )
        );
        vm.store(address(vault), slot, bytes32(uint256(balances.teaAlice)));
        assertEq(vault.balanceOf(alice, VAULT_ID), balances.teaAlice, "Wrong slot used by vm.store");
    }
}

// INVARIANT TEST USING A REAL DATA PAIR AND ITS REAL PRICE CHANGES
// TEST MULTIPLE MINTS ON DIFFERENT VAULTS WITH SAME COLLATERAL

contract VaultHandler is Test {
    struct InputOutput {
        bool advanceBlock;
        uint256 vaultId;
        uint256 userId;
        uint256 amountCollateral;
    }

    // NEED TO MAKE SURE TIME IS WORKING PROPERLY
    IWETH9 private constant _WETH = IWETH9(Addresses.ADDR_WETH);
    Vault public vault;
    Oracle public oracle;

    uint256 public blockNumber;

    modifier AdvanceBlock(InputOutput memory inputOutput) {
        if (inputOutput.advanceBlock) vm.createSelectFork("mainnet", ++blockNumber);
        _;
    }

    modifier WithdrawCollateral(InputOutput memory inputOutput) {
        _;

        // User
        address user = _idToAddr(inputOutput.userId);

        // Unwrap ETH
        vm.prank(user);
        _WETH.withdraw(inputOutput.amountCollateral);
    }

    constructor(uint256 blockNumber_) {
        blockNumber = blockNumber_;

        oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);
        vault = new Vault(vm.addr(100), vm.addr(101), address(oracle));

        // Set tax between 2 vaults
        vm.prank(vm.addr(100));
        {
            uint48[] memory oldVaults = new uint48[](0);
            uint48[] memory newVaults = new uint48[](2);
            newVaults[0] = 1;
            newVaults[1] = 2;
            uint8[] memory newTaxes = new uint8[](2);
            newTaxes[0] = 228;
            newTaxes[1] = 114; // Ensure 114^2+228^2 <= (2^8-1)^2
            vault.updateVaults(oldVaults, newVaults, newTaxes, 342);
        }

        // Intialize vault 1.25xETH/USDT
        vault.initialize(
            VaultStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDT,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: int8(-2)
            })
        );

        // Intialize vault 1.5xETH/USDC
        vault.initialize(
            VaultStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDC,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: int8(-1)
            })
        );
    }

    function mintAPE(InputOutput memory inputOutput) external AdvanceBlock(inputOutput) {
        // Get vault parameters
        (uint256 vaultId, VaultStructs.VaultParameters memory vaultParameters, address ape) = _idToVault(
            inputOutput.vaultId
        );

        // Get reserves
        VaultStructs.Reserves memory reserves = vault.getReserves(vaultParameters);

        // Sufficient condition to not overflow total collateral
        (uint112 collectedFees, uint144 total) = vault.tokenStates(vaultParameters.collateralToken);
        inputOutput.amountCollateral = _bound(inputOutput.amountCollateral, 1, type(uint144).max - total);

        // Sufficient condition to not overflow collected fees
        inputOutput.amountCollateral = _bound(inputOutput.amountCollateral, 1, type(uint112).max - collectedFees);

        // Sufficient condition to not overflow APE supply
        (bool success, uint256 maxCollateralAmount) = FullMath.tryMulDiv(
            reserves.reserveApes,
            type(uint256).max,
            IERC20(ape).totalSupply()
        );

        // Bound the collateral amount
        if (success) inputOutput.amountCollateral = _bound(inputOutput.amountCollateral, 1, maxCollateralAmount);

        // Sufficient condition to not overflow TEA supply
        uint256 teaSupply = vault.totalSupply(vaultId);
        if (teaSupply > 0) {
            (success, maxCollateralAmount) = FullMath.tryMulDiv(
                uint256(10) * reserves.reserveLPers,
                SystemConstants.TEA_MAX_SUPPLY,
                teaSupply
            );

            // Bound the collateral amount
            if (success) inputOutput.amountCollateral = _bound(inputOutput.amountCollateral, 1, maxCollateralAmount);
        } else {
            // Cannot mint 1 single unit of collateral if TEA supply is 0
            if (inputOutput.amountCollateral == 1) return;
        }

        // Deposit collateral
        console.log("-----------------------------------------");
        console.log("Minted with", inputOutput.amountCollateral, "WEI");
        address user = _depositCollateral(inputOutput);

        // Mint APE
        vm.prank(user);
        vault.mint(true, vaultParameters);
    }

    function mintTEA(InputOutput memory inputOutput) external AdvanceBlock(inputOutput) {
        // If supply of TEA is not 0, I need to make sure to not overflow the max supply
    }

    function burnAPE(
        InputOutput memory inputOutput,
        uint256 amountAPE
    ) external AdvanceBlock(inputOutput) WithdrawCollateral(inputOutput) {
        // BURN APE
        inputOutput.amountCollateral = 0;
    }

    function burnTEA(
        InputOutput memory inputOutput,
        uint256 amountTEA
    ) external AdvanceBlock(inputOutput) WithdrawCollateral(inputOutput) {
        // BURN TEA
        inputOutput.amountCollateral = 0;
    }

    /////////////////////////////////////////////////////////
    ///////////////////// PRIVATE FUNCTIONS /////////////////

    function _depositCollateral(InputOutput memory inputOutput) private returns (address user) {
        inputOutput.amountCollateral = _bound(inputOutput.amountCollateral, 1, (1 << 128) - _WETH.totalSupply());

        // User
        user = _idToAddr(inputOutput.userId);

        // Deal ETH
        if (user.balance < inputOutput.amountCollateral) vm.deal(user, inputOutput.amountCollateral - user.balance);

        // Wrap ETH and deposit to vault
        vm.startPrank(user);
        _WETH.deposit{value: inputOutput.amountCollateral}();
        _WETH.transfer(address(vault), inputOutput.amountCollateral);
        vm.stopPrank();
    }

    function _idToAddr(uint256 userId) private pure returns (address) {
        userId = _bound(userId, 1, 3);
        return vm.addr(userId);
    }

    function _idToVault(uint256 vaultId) private view returns (uint256, VaultStructs.VaultParameters memory, address) {
        vaultId = _bound(vaultId, 1, 2);
        (address debtToken, address collateralToken, int8 leverageTier) = vault.paramsById(vaultId);
        address ape = SaltedAddress.getAddress(address(vault), vaultId);
        return (vaultId, VaultStructs.VaultParameters(debtToken, collateralToken, leverageTier), ape);
    }

    // EVERY FUNCTION CALL MAY ADVANCED A BLOCK OR NOT

    // ADD HANDLE FOR MINT/BURN FUNCTIONS
}

contract VaultInvariantTest is Test {
    uint256 constant BLOCK_NUMBER_START = 18128102;
    IWETH9 private constant _WETH = IWETH9(Addresses.ADDR_WETH);

    VaultHandler public vaultHandler;
    Vault public vault;

    function setUp() public {
        vm.createSelectFork("mainnet", BLOCK_NUMBER_START);

        // Deploy the vault handler
        vaultHandler = new VaultHandler(BLOCK_NUMBER_START);

        targetContract(address(vaultHandler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = vaultHandler.mintAPE.selector;
        selectors[1] = vaultHandler.mintTEA.selector;
        selectors[2] = vaultHandler.burnAPE.selector;
        selectors[3] = vaultHandler.burnTEA.selector;
        targetSelector(FuzzSelector({addr: address(vaultHandler), selectors: selectors}));

        vault = vaultHandler.vault();
        vm.makePersistent(address(vaultHandler));
        vm.makePersistent(address(vault));
        vm.makePersistent(address(vaultHandler.oracle()));
        vm.makePersistent(SaltedAddress.getAddress(address(vault), 1));
        vm.makePersistent(SaltedAddress.getAddress(address(vault), 2));
    }

    /// forge-config: default.invariant.runs = 1
    /// forge-config: default.invariant.depth = 20
    function invariant_totalCollateral() public {
        (, uint144 total) = vault.tokenStates(address(_WETH));
        assertEq(total, _WETH.balanceOf(address(vault)), "Total collateral is wrong");
    }
}
