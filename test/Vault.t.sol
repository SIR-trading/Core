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

    struct SystemParams {
        uint16 baseFee;
        uint8 lpFee;
        uint8 tax;
        int8 leverageTier;
    }

    struct Balances {
        uint128 teaVault;
        uint128 teaAlice;
        uint128 teaSupply;
        uint256 apeAlice;
        uint256 apeSupply;
    }

    struct CollateralAmounts {
        uint144 collateralDeposited;
        uint256 collateralSupply;
        uint256 amountToBurn;
    }

    uint48 constant VAULT_ID = 1;

    address public systemControl = vm.addr(1);
    address public sir = vm.addr(2);

    Vault public vault;
    IERC20 public ape;

    address public alice = vm.addr(3);

    VaultStructs.VaultParameters public vaultParams;

    function setUp() public {
        vaultParams.debtToken = address(new MockERC20("Debt Token", "DBT", 6));
        vaultParams.collateralToken = address(new MockERC20("Collateral", "DBT", 18));

        // vm.createSelectFork("mainnet", 18128102);

        // Deploy oracle
        address oracle = address(new Oracle());

        // Mock oracle prices
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(Oracle.getPrice.selector, vaultParams.collateralToken, vaultParams.debtToken),
            abi.encode(int64(0))
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                Oracle.updateOracleState.selector,
                vaultParams.collateralToken,
                vaultParams.debtToken
            ),
            abi.encode(int64(0))
        );

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

    modifier InitializeCollateral(
        CollateralAmounts memory collateralAmounts,
        bool isFirst,
        bool isMint,
        VaultStructs.VaultState memory vaultState
    ) {
        // Constraint vault paramereters
        vaultState.vaultId = VAULT_ID;
        vaultState.reserve = uint144(_bound(vaultState.reserve, isFirst ? 0 : 2, type(uint144).max));

        if (isMint) {
            // Sufficient condition for the minting to not overflow the TEA max supply
            collateralAmounts.collateralDeposited = uint144(
                _bound(collateralAmounts.collateralDeposited, isFirst ? 2 : 0, uint256(10) * type(uint112).max)
            );

            collateralAmounts.collateralDeposited = uint144(
                _bound(collateralAmounts.collateralDeposited, 0, type(uint144).max - vaultState.reserve)
            );

            collateralAmounts.amountToBurn = 0;
        } else {
            collateralAmounts.collateralDeposited = 0;
        }

        // Collateral supply must be larger than the deposited amount
        collateralAmounts.collateralSupply = _bound(
            collateralAmounts.collateralSupply,
            collateralAmounts.collateralDeposited + vaultState.reserve,
            type(uint256).max
        );

        // Mint collateral supply
        MockERC20(vaultParams.collateralToken).mint(alice, collateralAmounts.collateralSupply);

        // Fill up reserve
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), vaultState.reserve);

        _;
    }

    function testFuzz_mintAPE1stTime(
        SystemParams calldata systemParams,
        CollateralAmounts memory collateralAmounts
    )
        public
        Initialize(systemParams)
        InitializeCollateral(collateralAmounts, true, true, VaultStructs.VaultState(0, 0, 0))
    {
        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), collateralAmounts.collateralDeposited);

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
            collateralAmounts.collateralDeposited,
            VaultStructs.Reserves(0, 0, 0),
            reserves,
            amount,
            Balances(0, 0, 0, 0, 0)
        );
    }

    function testFuzz_mintTEA1stTime(
        SystemParams calldata systemParams,
        CollateralAmounts memory collateralAmounts
    )
        public
        Initialize(systemParams)
        InitializeCollateral(collateralAmounts, true, true, VaultStructs.VaultState(0, 0, 0))
    {
        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), collateralAmounts.collateralDeposited);

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
            collateralAmounts.collateralDeposited,
            VaultStructs.Reserves(0, 0, 0),
            reserves,
            amount,
            Balances(0, 0, 0, 0, 0)
        );
    }

    function testFuzz_mint1stTimeDepositInsufficient(
        SystemParams calldata systemParams,
        CollateralAmounts memory collateralAmounts,
        bool isAPE
    )
        public
        Initialize(systemParams)
        InitializeCollateral(collateralAmounts, true, true, VaultStructs.VaultState(0, 0, 0))
    {
        collateralAmounts.collateralDeposited = uint144(_bound(collateralAmounts.collateralDeposited, 0, 1));

        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), collateralAmounts.collateralDeposited);

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
        CollateralAmounts memory collateralAmounts,
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) public Initialize(systemParams) InitializeCollateral(collateralAmounts, false, true, vaultState) {
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

        {
            // Constraint so it doesn't overflow TEA supply
            (bool success, uint256 collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reservesPre.reserveLPers,
                SystemConstants.TEA_MAX_SUPPLY - vault.totalSupply(vaultState.vaultId),
                vault.totalSupply(vaultState.vaultId)
            );
            if (success)
                collateralAmounts.collateralDeposited = uint144(
                    _bound(collateralAmounts.collateralDeposited, 0, collateralDepositedUpperBound)
                );

            // Constraint so it doesn't overflow APE supply
            (success, collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reservesPre.reserveApes,
                type(uint256).max - ape.totalSupply(),
                ape.totalSupply()
            );
            if (success)
                collateralAmounts.collateralDeposited = uint144(
                    _bound(collateralAmounts.collateralDeposited, 0, collateralDepositedUpperBound)
                );
        }

        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), collateralAmounts.collateralDeposited);

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
        _verifyAmountsMintAPE(
            systemParams,
            collateralAmounts.collateralDeposited,
            reservesPre,
            reservesPost,
            amount,
            balances
        );
    }

    function testFuzz_mintTEA(
        SystemParams calldata systemParams,
        CollateralAmounts memory collateralAmounts,
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) public Initialize(systemParams) InitializeCollateral(collateralAmounts, false, true, vaultState) {
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

        {
            // Constraint so it doesn't overflow TEA supply
            (bool success, uint256 collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reservesPre.reserveLPers,
                SystemConstants.TEA_MAX_SUPPLY - vault.totalSupply(vaultState.vaultId),
                vault.totalSupply(vaultState.vaultId)
            );
            if (success)
                collateralAmounts.collateralDeposited = uint144(
                    _bound(collateralAmounts.collateralDeposited, 0, collateralDepositedUpperBound)
                );

            // Constraint so it doesn't overflow APE supply
            (success, collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reservesPre.reserveApes,
                type(uint256).max - ape.totalSupply(),
                ape.totalSupply()
            );
            if (success)
                collateralAmounts.collateralDeposited = uint144(
                    _bound(collateralAmounts.collateralDeposited, 0, collateralDepositedUpperBound)
                );
        }

        // Alice deposits collateral
        vm.prank(alice);
        MockERC20(vaultParams.collateralToken).transfer(address(vault), collateralAmounts.collateralDeposited);

        // Alice mints TEA
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
        _verifyAmountsMintTEA(
            systemParams,
            collateralAmounts.collateralDeposited,
            reservesPre,
            reservesPost,
            amount,
            balances
        );
    }

    function testFuzz_burnAPE(
        SystemParams calldata systemParams,
        CollateralAmounts memory collateralAmounts,
        VaultStructs.VaultState memory vaultState,
        Balances memory balances
    ) public Initialize(systemParams) InitializeCollateral(collateralAmounts, false, false, vaultState) {
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
        collateralAmounts.amountToBurn = _bound(collateralAmounts.amountToBurn, 0, balances.apeAlice);

        {
            // Constraint so the collected fees doesn't overflow
            (bool success, uint256 amountToBurnUpperbound) = FullMath.tryMulDiv(
                uint256(10) * type(uint112).max,
                balances.apeSupply,
                reservesPre.reserveApes
            );
            if (success)
                collateralAmounts.amountToBurn = _bound(collateralAmounts.amountToBurn, 0, amountToBurnUpperbound);
        }

        // Constraint so it leaves at least 2 units in the reserve
        uint144 collateralOut = uint144(
            FullMath.mulDiv(reservesPre.reserveApes, collateralAmounts.amountToBurn, balances.apeSupply)
        );
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
            collateralAmounts.amountToBurn
        );

        // Retrieve reserves after minting
        VaultStructs.Reserves memory reservesPost = vault.getReserves(
            VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
        );

        // Verify amounts
        _verifyAmountsBurnAPE(
            systemParams,
            collateralAmounts.amountToBurn,
            reservesPre,
            reservesPost,
            collateralWidthdrawn,
            balances
        );
    }

    // function testFuzz_burnTEA(
    //     SystemParams calldata systemParams,
    //     uint256 amountToBurn,
    //     VaultStructs.VaultState memory vaultState,
    //     Balances memory balances
    // ) public Initialize(systemParams) {
    //     // Constraint vault paramereters
    //     vaultState.vaultId = VAULT_ID;
    //     vaultState.reserve = uint144(_bound(vaultState.reserve, 2, type(uint144).max));

    //     // Constraint balance parameters
    //     balances.teaSupply = uint128(_bound(balances.teaSupply, 1, SystemConstants.TEA_MAX_SUPPLY));
    //     balances.teaVault = uint128(_bound(balances.teaVault, 0, balances.teaSupply));
    //     balances.teaAlice = uint128(_bound(balances.teaAlice, 0, balances.teaSupply - balances.teaVault));
    //     balances.apeAlice = _bound(balances.apeAlice, 0, balances.apeSupply);

    //     // Set state
    //     _setState(vaultState, balances);

    //     // Get reserves before burning
    //     VaultStructs.Reserves memory reservesPre = vault.getReserves(
    //         VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
    //     );

    //     // Constraint so it doesn't underflow its balance
    //     amountToBurn = _bound(amountToBurn, 0, balances.teaAlice);

    //     {
    //         // Constraint so the collected fees doesn't overflow
    //         (bool success, uint256 amountToBurnUpperbound) = FullMath.tryMulDiv(
    //             uint256(10) * type(uint112).max,
    //             balances.teaSupply,
    //             reservesPre.reserveLPers
    //         );
    //         if (success) amountToBurn = _bound(amountToBurn, 0, amountToBurnUpperbound);
    //     }

    //     // Constraint so it leaves at least 2 units in the reserve
    //     uint144 collateralOut = uint144(FullMath.mulDiv(reservesPre.reserveLPers, amountToBurn, balances.teaSupply));
    //     (uint144 collateralWidthdrawn_, uint144 collectedFee, , ) = Fees.hiddenFeeTEA(
    //         collateralOut,
    //         systemParams.lpFee,
    //         systemParams.tax
    //     );
    //     vm.assume(vaultState.reserve >= uint256(2) + collateralWidthdrawn_ + collectedFee);

    //     // Alice burns TEA
    //     vm.prank(alice);
    //     uint144 collateralWidthdrawn = vault.burn(
    //         false,
    //         VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier),
    //         amountToBurn
    //     );

    //     // Retrieve reserves after minting
    //     VaultStructs.Reserves memory reservesPost = vault.getReserves(
    //         VaultStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
    //     );

    //     // Verify amounts
    //     _verifyAmountsBurnTEA(systemParams, amountToBurn, reservesPre, reservesPost, collateralWidthdrawn, balances);
    // }

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

    function _verifyAmountsBurnTEA(
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
            uint144 collateralOut = uint144(FullMath.mulDiv(reservesPre.reserveLPers, amount, balances.teaSupply));

            // Verify amounts
            (collateralWidthdrawn_, collectedFee, lpersFee, polFee) = Fees.hiddenFeeTEA(
                collateralOut,
                systemParams.lpFee,
                systemParams.tax
            );
            reservesPre.reserveLPers -= collateralOut;
            reservesPre.reserveLPers += lpersFee;
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
        assertEq(amount, balances.teaAlice - vault.balanceOf(alice, VAULT_ID));
        assertEq(ape.balanceOf(alice), balances.apeAlice);

        // Verify POL's balances
        balances.teaSupply -= uint128(amount);
        amount = uint128(vault.balanceOf(address(vault), VAULT_ID) - balances.teaVault);
        if (balances.teaSupply > 0) {
            if (reservesPre.reserveLPers == 0) {
                revert("Invalid state");
            } else {
                assertEq(amount, FullMath.mulDiv(balances.teaSupply, polFee, reservesPre.reserveLPers));
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
