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
import {MockERC20} from "src/test/MockERC20.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";

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

    address public systemControl = vm.addr(1);
    address public sir = vm.addr(2);
    address public oracle;

    Vault public vault;
    IERC20 public ape;

    address public alice = vm.addr(3);

    VaultStructs.VaultParameters public vaultParams;

    function setUp() public {
        vaultParams.debtToken = address(new MockERC20("Debt Token", "DBT", 6));
        vaultParams.collateralToken = address(new MockERC20("Collateral", "COL", 18));

        // vm.createSelectFork("mainnet", 18128102);

        // Deploy oracle
        oracle = address(new Oracle());

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

    modifier Initialize(SystemParams calldata systemParams) {
        vaultParams.leverageTier = int8(
            _bound(systemParams.leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER)
        );

        // Initialize vault
        vault.initialize(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Mock oracle prices
        int64 tickPriceX42 = int64(
            _bound(systemParams.tickPriceX42, int64(TickMath.MIN_TICK) << 42, int64(TickMath.MAX_TICK) << 42)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(Oracle.getPrice.selector, vaultParams.collateralToken, vaultParams.debtToken),
            abi.encode(tickPriceX42)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                Oracle.updateOracleState.selector,
                vaultParams.collateralToken,
                vaultParams.debtToken
            ),
            abi.encode(tickPriceX42)
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

    modifier ConstraintAmounts(
        bool isFirst,
        bool isMint,
        InputsOutputs memory inputsOutputs,
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) {
        // Constraint vault paramereters
        vaultState.vaultId = VAULT_ID;
        vaultState.reserve = uint144(_bound(vaultState.reserve, isFirst ? 0 : 2, type(uint144).max));

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

        _;
    }

    function testFuzz_mintAPE1stTime(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs
    )
        public
        Initialize(systemParams)
        ConstraintAmounts(true, true, inputsOutputs, VaultStructs.VaultState(0, 0, 0), Balances(0, 0, 0, 0, 0))
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
        Initialize(systemParams)
        ConstraintAmounts(true, true, inputsOutputs, VaultStructs.VaultState(0, 0, 0), Balances(0, 0, 0, 0, 0))
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
        Initialize(systemParams)
        ConstraintAmounts(true, true, inputsOutputs, VaultStructs.VaultState(0, 0, 0), Balances(0, 0, 0, 0, 0))
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

    function testFuzz_mintAPE(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) public Initialize(systemParams) ConstraintAmounts(false, true, inputsOutputs, vaultState, balances) {
        // Set state
        _setState(vaultState, balances);

        // Get reserves before minting
        VaultStructs.Reserves memory reservesPre = vault.getReserves(
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
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) public Initialize(systemParams) ConstraintAmounts(false, true, inputsOutputs, vaultState, balances) {
        // Set state
        _setState(vaultState, balances);

        // Get reserves before minting
        VaultStructs.Reserves memory reservesPre = vault.getReserves(
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
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) public Initialize(systemParams) ConstraintAmounts(false, false, inputsOutputs, vaultState, balances) {
        // Set state
        _setState(vaultState, balances);

        // Get reserves before minting
        VaultStructs.Reserves memory reservesPre = vault.getReserves(
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
            uint144 collateralOut = _constraintReserveBurnAPE(
                systemParams,
                reservesPre,
                inputsOutputs,
                vaultState,
                balances
            );

            // Sufficient condition to ensure the POL minting does not overflow the TEA max supply
            vm.assume(
                FullMath.mulDiv(collateralOut, balances.teaSupply, uint(10) * reservesPre.reserveLPers) <=
                    SystemConstants.TEA_MAX_SUPPLY - balances.teaSupply
            );
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
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) public Initialize(systemParams) ConstraintAmounts(false, false, inputsOutputs, vaultState, balances) {
        // Set state
        _setState(vaultState, balances);

        // Get reserves before burning
        VaultStructs.Reserves memory reservesPre = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Constraint so it doesn't underflow its balance
        inputsOutputs.amount = _bound(inputsOutputs.amount, 0, balances.teaAlice);

        {
            // Constraint so the collected fees doesn't overflow
            (bool success, uint256 amountToBurnUpperbound) = FullMath.tryMulDiv(
                uint256(10) * type(uint112).max,
                balances.teaSupply,
                reservesPre.reserveLPers
            );
            if (success) inputsOutputs.amount = _bound(inputsOutputs.amount, 0, amountToBurnUpperbound);
        }

        // Constraint so it leaves at least 2 units in the reserve
        {
            uint144 collateralWidthdrawn;
            uint144 collectedFee;
            (collateralWidthdrawn, collectedFee) = _constraintReserveBurnTEA(
                systemParams,
                reservesPre,
                inputsOutputs,
                balances
            );
            vm.assume(vaultState.reserve >= uint256(2) + collateralWidthdrawn + collectedFee);
        }

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

    function testFuzz_wrongVaultParameters(
        bool isFirst,
        bool isMint,
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        VaultStructs.VaultState memory vaultState,
        Balances memory balances,
        VaultStructs.VaultParameters memory vaultParams_
    ) public Initialize(systemParams) ConstraintAmounts(isFirst, isMint, inputsOutputs, vaultState, balances) {
        vm.assume( // Ensure the vault does not exist
            vaultParams.debtToken != vaultParams_.debtToken ||
                vaultParams.collateralToken != vaultParams_.collateralToken ||
                vaultParams.leverageTier != vaultParams_.leverageTier
        );

        // Set state
        _setState(vaultState, balances);

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

        // Alice tries to burn non-existant APE or TEA
        vm.expectRevert(VaultDoesNotExist.selector);
        if (isMint) {
            vault.mint(isAPE, vaultParams_);
        } else {
            vault.burn(isAPE, vaultParams_, inputsOutputs.amount);
        }
    }

    // TEST RESERVES BEFORE AND AFTER MINTING / BURNING

    // TEST RESERVES UPON PRICE FLUCTUATIONS

    function _constraintReserveBurnAPE(
        SystemParams calldata systemParams,
        VaultStructs.Reserves memory reservesPre,
        InputsOutputs memory inputsOutputs,
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) private view returns (uint144 collateralOut) {
        collateralOut = uint144(FullMath.mulDiv(reservesPre.reserveApes, inputsOutputs.amount, balances.apeSupply));
        (uint144 collateralWidthdrawn_, uint144 collectedFee, , ) = Fees.hiddenFeeAPE(
            collateralOut,
            systemParams.baseFee,
            vaultParams.leverageTier,
            systemParams.tax
        );

        vm.assume(vaultState.reserve >= uint256(2) + collateralWidthdrawn_ + collectedFee);
    }

    function _constraintReserveBurnTEA(
        SystemParams calldata systemParams,
        VaultStructs.Reserves memory reservesPre,
        InputsOutputs memory inputsOutputs,
        Balances memory balances
    ) private pure returns (uint144 collateralWidthdrawn_, uint144 collectedFee) {
        uint144 collateralOut = uint144(
            FullMath.mulDiv(reservesPre.reserveLPers, inputsOutputs.amount, balances.teaSupply)
        );
        (collateralWidthdrawn_, collectedFee, , ) = Fees.hiddenFeeTEA(
            collateralOut,
            systemParams.lpFee,
            systemParams.tax
        );
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
            assertEq(total, reservesPre.reserveLPers + reservesPre.reserveApes + inputsOutputs.collateral);
        }

        // Verify Alice's balances
        if (balances.apeSupply == 0) {
            assertEq(inputsOutputs.amount, collateralIn + reservesPre.reserveApes);
        } else if (reservesPre.reserveApes > 0) {
            assertEq(inputsOutputs.amount, FullMath.mulDiv(balances.apeSupply, collateralIn, reservesPre.reserveApes));
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
        assertApproxEqAbs(
            reservesPost.reserveLPers,
            reservesPre.reserveLPers + collateralIn + lpersFee + polFee,
            1 + reserve / 1e11,
            "LPers's reserve is wrong"
        );
        assertApproxEqAbs(
            reservesPost.reserveApes,
            reservesPre.reserveApes,
            1 + reserve / 1e11,
            "Apes's reserve has changed"
        );

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
        assertApproxEqAbs(
            reservesPost.reserveLPers,
            reservesPre.reserveLPers + polFee,
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

// TEST MULTIPLE MINTS ON DIFFERENT VAULTS WITH SAME COLLATERAL

// INVARIANT TEST USING REAL DATA AND USING CONSTANT RANDOM PRICES

// INVARIANT TEST WITH EXTREME PRICES
