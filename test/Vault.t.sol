// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Vault} from "src/Vault.sol";
import {Oracle} from "src/Oracle.sol";
import {APE} from "src/APE.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {Fees} from "src/libraries/Fees.sol";
import {AddressClone} from "src/libraries/AddressClone.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {FullMath} from "src/libraries/FullMath.sol";
import {MockERC20} from "src/test/MockERC20.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {ABDKMathQuad} from "abdk/ABDKMathQuad.sol";
import {TickMathPrecision} from "src/libraries/TickMathPrecision.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {TransferHelper} from "v3-core/libraries/TransferHelper.sol";

import "forge-std/Test.sol";

contract VaultInitializeTest is Test {
    error VaultAlreadyInitialized();
    error LeverageTierOutOfRange();
    error NoUniswapPool();

    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId,
        address ape
    );

    address public systemControl = vm.addr(1);
    address public sir = vm.addr(2);

    Vault public vault;

    address public debtToken = Addresses.ADDR_USDT;
    address public collateralToken = Addresses.ADDR_WETH;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

        address apeImplementation = address(new APE());

        // Deploy vault
        vault = new Vault(systemControl, sir, oracle, apeImplementation, Addresses.ADDR_WETH);
    }

    function testFuzz_InitializeVault(int8 leverageTier) public {
        // Stay within the allowed range
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER));

        // Check vault 1 does not exist
        vm.expectRevert();
        vault.paramsById(1);

        // _initialize vault 1
        vm.expectEmit();
        emit VaultInitialized(debtToken, collateralToken, leverageTier, 1, AddressClone.getAddress(address(vault), 1));
        vault.initialize(SirStructs.VaultParameters(debtToken, collateralToken, leverageTier));

        // Check vault 1 is initialized correctly
        SirStructs.VaultState memory vaultState = vault.vaultStates(
            SirStructs.VaultParameters(debtToken, collateralToken, leverageTier)
        );
        SirStructs.VaultParameters memory vaultParams_ = vault.paramsById(1);
        assertEq(vaultState.reserve, 0);
        assertEq(vaultState.tickPriceSatX42, 0);
        assertEq(vaultState.vaultId, 1);
        assertEq(debtToken, vaultParams_.debtToken);
        assertEq(collateralToken, vaultParams_.collateralToken);
        assertEq(leverageTier, vaultParams_.leverageTier);

        // Check vault 2 does not exist
        vm.expectRevert();
        vault.paramsById(2);

        // _initialize vault 2
        vm.expectEmit();
        emit VaultInitialized(collateralToken, debtToken, leverageTier, 2, AddressClone.getAddress(address(vault), 2));
        vault.initialize(SirStructs.VaultParameters(collateralToken, debtToken, leverageTier));

        // Check vault 2 is initialized correctly
        vaultState = vault.vaultStates(SirStructs.VaultParameters(collateralToken, debtToken, leverageTier));
        vaultParams_ = vault.paramsById(2);
        assertEq(vaultState.reserve, 0);
        assertEq(vaultState.tickPriceSatX42, 0);
        assertEq(vaultState.vaultId, 2);
        assertEq(debtToken, vaultParams_.collateralToken);
        assertEq(collateralToken, vaultParams_.debtToken);
        assertEq(leverageTier, vaultParams_.leverageTier);

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
        vault.initialize(SirStructs.VaultParameters(debtToken, collateralToken, leverageTier));
    }

    function testFuzz_InitializeVaultAlreadyInitialized(int8 leverageTier) public {
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER));

        testFuzz_InitializeVault(leverageTier);

        vm.expectRevert(VaultAlreadyInitialized.selector);
        vault.initialize(SirStructs.VaultParameters(debtToken, collateralToken, leverageTier));
    }

    function testFuzz_InitializeVaultNoUniswapPool(int8 leverageTier) public {
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER));

        vm.expectRevert(NoUniswapPool.selector);
        vault.initialize(SirStructs.VaultParameters(Addresses.ADDR_BNB, Addresses.ADDR_ALUSD, leverageTier));
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
    using ABDKMathQuad for bytes16;
    using ExtraABDKMathQuad for int64;
    using BonusABDKMathQuad for bytes16;

    error LeverageTierOutOfRange();
    error NoUniswapPool();
    error VaultDoesNotExist();

    uint256 constant smallErrorTolerance = 1e16;
    uint256 constant largeErrorTolerance = 1e4;

    struct SystemParams {
        uint16 baseFee;
        uint16 lpFee;
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

    uint256 constant SLOT_VAULT_STATE = 7;
    uint256 constant SLOT_TOTAL_RESERVES = 8;
    uint256 constant SLOT_TOTAL_SUPPLY_APE = 5;
    uint256 constant SLOT_APE_BALANCE_OF = 6;
    uint256 constant SLOT_TOTAL_SUPPLY_TEA = 4;
    uint256 constant SLOT_TEA_BALANCE_OF = 3;

    uint48 constant VAULT_ID = 1;
    bytes16 immutable ONE;

    address public systemControl = vm.addr(1);
    address public sir = vm.addr(2);
    address public oracle;

    MockERC20 public collateral;
    Vault public vault;
    IERC20 public ape;

    address public alice = vm.addr(3);

    SirStructs.VaultParameters public vaultParams;

    constructor() {
        ONE = ABDKMathQuad.fromUInt(1);
    }

    function setUp() public {
        vaultParams.debtToken = address(new MockERC20("Debt Token", "DBT", 6));
        collateral = new MockERC20("Collateral", "COL", 18);
        vaultParams.collateralToken = address(collateral);

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

        // Deploy APE implementation
        APE apeImplementation = new APE();

        // Deploy vault
        vault = new Vault(systemControl, sir, oracle, address(apeImplementation), Addresses.ADDR_WETH);

        // Derive APE address
        ape = IERC20(AddressClone.getAddress(address(vault), VAULT_ID));
    }

    function _initialize(SystemParams calldata systemParams, SirStructs.Reserves memory reservesPre) internal {
        {
            vaultParams.leverageTier = int8(
                _bound(systemParams.leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER)
            );

            // _initialize vault
            vault.initialize(
                SirStructs.VaultParameters(vaultParams.debtToken, vaultParams.collateralToken, vaultParams.leverageTier)
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
    }

    // modifier ConstraintReserves(
    //     bool isAPE,
    //     bool isFirstMint,
    //     SirStructs.Reserves memory reservesPre,
    //     Balances memory balances
    // ) {
    //     {
    //         // Even if it's the first time an ape mints, the reserves will be non-zero if there are LPers; and same when minting TEA.
    //         bool resevesAreEmpty;
    //         if (isFirstMint) {
    //             // Decide randomly whether we set the reserves empty or not.
    //             bytes32 rndHash = keccak256(abi.encode(isAPE, reservesPre, balances));
    //             resevesAreEmpty = uint256(rndHash) % 2 == 0;
    //         }

    //         // Constraint reserves
    //         if (resevesAreEmpty) {
    //             reservesPre.reserveApes = 0;
    //             reservesPre.reserveLPers = 0;
    //         } else {
    //             // Even if it is the first time to mint APE, because of the LPers, the reserves could be anything; and same when minting TEA

    //             // LP and APE reserves must be at least have 1 unit
    //             reservesPre.reserveApes = uint144(_bound(reservesPre.reserveApes, 1, type(uint144).max - 1));
    //             reservesPre.reserveLPers = uint144(
    //                 _bound(reservesPre.reserveLPers, 1, type(uint144).max - reservesPre.reserveApes)
    //             );

    //             // Combined reserves must be at least 1M
    //             vm.assume(reservesPre.reserveApes + reservesPre.reserveLPers >= 1e6);
    //         }

    //         // Constraint balance parameters
    //         if (resevesAreEmpty) {
    //             balances.apeSupply = 0;
    //             balances.apeAlice = 0;

    //             balances.teaSupply = 0;
    //             balances.teaVault = 0;
    //             balances.teaAlice = 0;
    //         } else if (isFirstMint && isAPE) {
    //             // No APE has been minted yet
    //             balances.apeSupply = 0;
    //             balances.apeAlice = 0;

    //             balances.teaSupply = uint128(_bound(balances.teaSupply, 1, SystemConstants.TEA_MAX_SUPPLY));
    //             balances.teaVault = uint128(_bound(balances.teaVault, 0, balances.teaSupply));
    //             balances.teaAlice = uint128(_bound(balances.teaAlice, 0, balances.teaSupply - balances.teaVault));
    //         } else if (isFirstMint && !isAPE) {
    //             // No TEA has been minted yet
    //             balances.apeSupply = _bound(balances.apeSupply, 1, type(uint256).max);
    //             balances.apeAlice = _bound(balances.apeAlice, 0, balances.apeSupply);

    //             balances.teaSupply = 0;
    //             balances.teaVault = 0;
    //             balances.teaAlice = 0;
    //         } else {
    //             balances.apeSupply = _bound(balances.apeSupply, 1, type(uint256).max);
    //             balances.apeAlice = _bound(balances.apeAlice, 0, balances.apeSupply);

    //             balances.teaSupply = uint128(_bound(balances.teaSupply, 1, SystemConstants.TEA_MAX_SUPPLY));
    //             balances.teaVault = uint128(_bound(balances.teaVault, 0, balances.teaSupply));
    //             balances.teaAlice = uint128(_bound(balances.teaAlice, 0, balances.teaSupply - balances.teaVault));
    //         }

    //         // Derive vault state
    //         SirStructs.VaultState memory vaultState = _deriveVaultState(reservesPre);

    //         // Set state
    //         _setState(vaultState, balances);

    //         // Update reserves
    //         reservesPre = vault.getReserves(vaultParams);
    //     }

    //     _;
    // }

    function _constraintBalances(
        bool isAPE,
        bool isFirstMint, // Whether it's the first mint of its type (APE mint or TEA mint)
        SirStructs.Reserves memory reservesPre,
        Balances memory balances
    ) internal {
        // Even if it is the first time to mint APE, because of the LPers, the reserves could be anything; and same when minting TEA
        reservesPre.reserveApes = uint144(_bound(reservesPre.reserveApes, 0, type(uint144).max - 1));
        reservesPre.reserveLPers = uint144(
            _bound(reservesPre.reserveLPers, 0, type(uint144).max - 1 - reservesPre.reserveApes)
        );

        // Combined reserves must be at least 1M
        vm.assume(reservesPre.reserveApes + reservesPre.reserveLPers >= 1e6);

        // Constraint balance parameters
        if (!isFirstMint) {
            balances.apeSupply = _bound(balances.apeSupply, 1, type(uint256).max);
            balances.apeAlice = _bound(balances.apeAlice, 0, balances.apeSupply);

            balances.teaSupply = uint128(_bound(balances.teaSupply, 1, SystemConstants.TEA_MAX_SUPPLY));
            balances.teaVault = uint128(_bound(balances.teaVault, 0, balances.teaSupply));
            balances.teaAlice = uint128(_bound(balances.teaAlice, 0, balances.teaSupply - balances.teaVault));
        } else if (isAPE) {
            // No APE has been minted yet
            balances.apeSupply = 0;
            balances.apeAlice = 0;

            balances.teaSupply = uint128(_bound(balances.teaSupply, 1, SystemConstants.TEA_MAX_SUPPLY));
            balances.teaVault = uint128(_bound(balances.teaVault, 0, balances.teaSupply));
            balances.teaAlice = uint128(_bound(balances.teaAlice, 0, balances.teaSupply - balances.teaVault));
        } else {
            // No TEA has been minted yet
            balances.apeSupply = _bound(balances.apeSupply, 1, type(uint256).max);
            balances.apeAlice = _bound(balances.apeAlice, 0, balances.apeSupply);

            balances.teaSupply = 0;
            balances.teaVault = 0;
            balances.teaAlice = 0;
        }

        // Derive vault state
        SirStructs.VaultState memory vaultState = _deriveVaultState(reservesPre);

        // Set state
        _setState(vaultState, balances);

        // Update reserves
        SirStructs.Reserves memory reservesPre_ = vault.getReserves(vaultParams);
        reservesPre.reserveApes = reservesPre_.reserveApes;
        reservesPre.reserveLPers = reservesPre_.reserveLPers;
    }

    function _makeFirstDepositEver(
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs
    ) internal {
        inputsOutputs.amount = 0;

        // If it is the 1st ever mint of APE and TEA, we must deposit at least 1M units of collateral
        // If it's APE, we mint 1.1M to account for the max 10% fee to stakers.
        inputsOutputs.collateral = uint144(_bound(inputsOutputs.collateral, isAPE ? 1.1e6 : 1e6, type(uint144).max));

        // Collateral supply must be larger than the deposited amount
        if (!isAPE) {
            (bool success, uint256 collateralSupplyUpperbound) = FullMath.tryMulDiv(
                SystemConstants.TEA_MAX_SUPPLY,
                inputsOutputs.collateral,
                1 +
                    FullMath.mulDivRoundingUp(
                        inputsOutputs.collateral,
                        1,
                        (uint256(inputsOutputs.collateral) * 10000) / (10000 + uint256(systemParams.lpFee))
                    )
            );

            // Check product did not overflow
            vm.assume(inputsOutputs.collateral <= collateralSupplyUpperbound);
            if (success) {
                inputsOutputs.collateralSupply = _bound(
                    inputsOutputs.collateralSupply,
                    uint256(inputsOutputs.collateral),
                    collateralSupplyUpperbound
                );
            }
        }

        // This conditions always holds
        inputsOutputs.collateralSupply = _bound(
            inputsOutputs.collateralSupply,
            inputsOutputs.collateral,
            type(uint256).max
        );

        // Mint collateral supply
        collateral.mint(alice, inputsOutputs.collateralSupply);
    }

    function _makeFirstDepositEverTooSmall(bool isAPE, InputsOutputs memory inputsOutputs) internal {
        inputsOutputs.amount = 0;

        if (!isAPE) {
            // Sufficient upperbound to ensure no TEA is minted
            uint256 collateralUpperbound = inputsOutputs.collateralSupply / SystemConstants.TEA_MAX_SUPPLY;

            inputsOutputs.collateral = uint144(
                _bound(inputsOutputs.collateral, 0, collateralUpperbound >= 1e6 ? collateralUpperbound : 1e6 - 1)
            );
        } else {
            // Ensure not enough collateral is deposited
            inputsOutputs.collateral = uint144(_bound(inputsOutputs.collateral, 0, 1e6 - 1));
        }

        // Mint collateral supply
        collateral.mint(alice, inputsOutputs.collateralSupply);
    }

    function _makeFirstTypeDeposit(
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre
    ) internal {
        uint144 reserveTotal = reservesPre.reserveApes + reservesPre.reserveLPers;

        inputsOutputs.amount = 0;

        if (isAPE) {
            // Any non-zero amount of collateral is fine when minting APE
            console.log(1, type(uint144).max - reserveTotal);
            inputsOutputs.collateral = uint144(_bound(inputsOutputs.collateral, 1, type(uint144).max - reserveTotal));
        } else {
            // Ensure first time minting TEA, gentleman receives at least 1 unit.
            // APE does not have this problem because it is always minted 1-to-1 to the amount of collateral, and does not use _amountFirstMint
            uint256 collateralLowerbound = (uint256(2) * reserveTotal - 1) / SystemConstants.TEA_MAX_SUPPLY + 1; // reserveTotal is the minimum collateral supply
            if (collateralLowerbound > reservesPre.reserveLPers) {
                collateralLowerbound -= reservesPre.reserveLPers + 1;

                vm.assume(collateralLowerbound <= type(uint144).max - reserveTotal);
                inputsOutputs.collateral = uint144(
                    _bound(inputsOutputs.collateral, collateralLowerbound, type(uint144).max - reserveTotal)
                );
            } else {
                inputsOutputs.collateral = uint144(
                    _bound(inputsOutputs.collateral, 1, type(uint144).max - reserveTotal)
                );
            }

            // Ensure that after substracting the fee, the gentleman is still receiving 1 unit
            vm.assume((uint256(inputsOutputs.collateral) * 10000) / (10000 + uint256(systemParams.lpFee)) > 0);
        }

        // Collateral supply must be larger than the deposited amount
        if (!isAPE) {
            (bool success, uint256 collateralSupplyUpperbound) = FullMath.tryMulDiv(
                SystemConstants.TEA_MAX_SUPPLY,
                (uint256(inputsOutputs.collateral) + reservesPre.reserveLPers),
                1 +
                    FullMath.mulDivRoundingUp(
                        (uint256(inputsOutputs.collateral) + reservesPre.reserveLPers),
                        1,
                        (uint256(inputsOutputs.collateral) * 10000) / (10000 + uint256(systemParams.lpFee))
                    )
            );

            // Check product did not overflow
            vm.assume(uint256(inputsOutputs.collateral) + reserveTotal <= collateralSupplyUpperbound);
            if (success) {
                inputsOutputs.collateralSupply = _bound(
                    inputsOutputs.collateralSupply,
                    uint256(inputsOutputs.collateral) + reserveTotal,
                    collateralSupplyUpperbound
                );
            }
        }

        // This conditions always holds
        inputsOutputs.collateralSupply = _bound(
            inputsOutputs.collateralSupply,
            uint256(inputsOutputs.collateral) + reserveTotal,
            type(uint256).max
        );

        // Mint collateral supply
        collateral.mint(alice, inputsOutputs.collateralSupply);

        // Fill up reserve
        vm.prank(alice);
        collateral.transfer(address(vault), reserveTotal);
    }

    function _makeFirstTypeDepositEverTooSmall(
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre
    ) internal {
        uint144 reserveTotal = reservesPre.reserveApes + reservesPre.reserveLPers;

        inputsOutputs.amount = 0;

        // This conditions always holds
        inputsOutputs.collateralSupply = _bound(inputsOutputs.collateralSupply, reserveTotal, type(uint256).max);

        if (isAPE) {
            // Any non-zero amount of collateral is fine when minting APE
            inputsOutputs.collateral = 0;
        } else {
            // Ensure minter receives no TEA
            (bool success, uint256 collateralUpperbound) = FullMath.tryMulDivRoundingUp(
                inputsOutputs.collateralSupply,
                uint256(10 ** 4) + systemParams.lpFee,
                uint256(10 ** 4) * SystemConstants.TEA_MAX_SUPPLY
            );

            if (success)
                inputsOutputs.collateral = uint144(_bound(inputsOutputs.collateral, 0, collateralUpperbound - 1));
        }

        // Mint collateral supply
        collateral.mint(alice, inputsOutputs.collateralSupply);

        // Fill up reserve
        vm.prank(alice);
        collateral.transfer(address(vault), reserveTotal);
    }

    function _makeDeposit(
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre,
        Balances memory balances
    ) internal {
        uint144 reserveTotal = reservesPre.reserveApes + reservesPre.reserveLPers;

        inputsOutputs.amount = 0;

        // Ensure user gets at least 1 unit of APE or TEA
        uint256 collateralLowerbound;
        bool success;
        if (isAPE) {
            // Compute lowerbound on collateral in
            collateralLowerbound = (reservesPre.reserveApes - 1) / balances.apeSupply + 1;

            // Compute lowerbound on collateral deposited taking into account the fee
            uint256 temp;
            if (systemParams.leverageTier > 0) {
                (success, temp) = FullMath.tryMulDivRoundingUp(
                    collateralLowerbound,
                    2 ** uint256(int256(systemParams.leverageTier)) * systemParams.baseFee,
                    10000
                );
            } else {
                (success, temp) = FullMath.tryMulDivRoundingUp(
                    collateralLowerbound,
                    systemParams.baseFee,
                    2 ** uint256(-int256(systemParams.leverageTier)) * 10000
                );
            }

            vm.assume(!success || type(uint256).max - temp <= collateralLowerbound);
            collateralLowerbound += temp;
        } else {
            collateralLowerbound = FullMath.mulDivRoundingUp(
                reservesPre.reserveLPers,
                2 * uint256(10 ** 4) + systemParams.lpFee,
                uint256(10 ** 4) * balances.teaSupply
            );

            uint256 totalMintedTEALowerbound = FullMath.mulDivRoundingUp(
                balances.teaSupply,
                collateralLowerbound,
                reservesPre.reserveLPers
            );

            uint256 collateralLowerbound2 = FullMath.mulDivRoundingUp(
                totalMintedTEALowerbound,
                uint256(10 ** 4) + systemParams.lpFee,
                uint256(10 ** 4) * (totalMintedTEALowerbound - 1) - systemParams.lpFee
            );

            if (collateralLowerbound2 > collateralLowerbound) collateralLowerbound = collateralLowerbound2;
        }
        vm.assume(collateralLowerbound + reserveTotal <= type(uint144).max);

        // Ensure collateral does not overflow the supply of APE or TEA
        uint256 collateralUpperbound;
        if (isAPE) {
            (success, collateralUpperbound) = FullMath.tryMulDiv(
                type(uint256).max - balances.apeSupply,
                reservesPre.reserveApes,
                balances.apeSupply
            );
        } else {
            (success, collateralUpperbound) = FullMath.tryMulDiv(
                SystemConstants.TEA_MAX_SUPPLY - balances.teaSupply,
                reservesPre.reserveLPers,
                balances.teaSupply
            );
        }
        if (!success || collateralUpperbound > type(uint144).max - reserveTotal) {
            collateralUpperbound = type(uint144).max - reserveTotal;
        }

        vm.assume(collateralLowerbound <= collateralUpperbound);

        // Bound collateral by bounds
        inputsOutputs.collateral = uint144(
            _bound(inputsOutputs.collateral, collateralLowerbound, collateralUpperbound)
        );

        // This conditions always holds
        inputsOutputs.collateralSupply = _bound(
            inputsOutputs.collateralSupply,
            uint256(inputsOutputs.collateral) + reserveTotal,
            type(uint256).max
        );

        // Mint collateral supply
        collateral.mint(alice, inputsOutputs.collateralSupply);

        // Fill up reserve
        vm.prank(alice);
        collateral.transfer(address(vault), reserveTotal);
    }

    function _constrainAmount(
        bool isAPE,
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre,
        Balances memory balances
    ) internal {
        uint144 reserveTotal = reservesPre.reserveApes + reservesPre.reserveLPers;

        // Ensure not too much collateral is burned
        bool success;
        uint256 maxAmount;
        if (isAPE)
            (success, maxAmount) = FullMath.tryMulDiv(balances.apeSupply, reserveTotal - 1e6, reservesPre.reserveApes);
        else
            (success, maxAmount) = FullMath.tryMulDiv(balances.teaSupply, reserveTotal - 1e6, reservesPre.reserveLPers);

        if (success) {
            vm.assume(maxAmount > 0);
            inputsOutputs.amount = _bound(inputsOutputs.amount, 1, maxAmount);
        }

        // We cannot exceed balance
        uint256 balance = isAPE ? balances.apeAlice : balances.teaAlice;
        vm.assume(balance > 0);
        inputsOutputs.amount = _bound(inputsOutputs.amount, 1, balance);

        inputsOutputs.collateral = 0;

        // This conditions always holds
        inputsOutputs.collateralSupply = _bound(
            inputsOutputs.collateralSupply,
            uint256(inputsOutputs.collateral) + reserveTotal,
            type(uint256).max
        );

        // Mint collateral supply
        collateral.mint(alice, inputsOutputs.collateralSupply);

        // Fill up reserve
        vm.prank(alice);
        collateral.transfer(address(vault), reserveTotal);
    }

    function testFuzz_mint1stEver(
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs
    ) public {
        SirStructs.Reserves memory reservesPre = SirStructs.Reserves(0, 0, 0);

        _initialize(systemParams, reservesPre);
        _makeFirstDepositEver(isAPE, systemParams, inputsOutputs);

        // Alice mints APE
        vm.startPrank(alice);
        collateral.approve(address(vault), inputsOutputs.collateral);

        inputsOutputs.amount = vault.mint(isAPE, vaultParams, inputsOutputs.collateral);

        // Check reserves
        SirStructs.Reserves memory reserves = vault.getReserves(vaultParams);

        // No reserve is allowed to be 0
        assertGt(reserves.reserveApes, 0);
        assertGt(reserves.reserveLPers, 0);

        // Ensure total reserve is larger than 1M
        assertGe(reserves.reserveApes + reserves.reserveLPers, 1e6);

        // Verify amounts
        Balances memory balances = Balances(0, 0, 0, 0, 0);
        isAPE
            ? _verifyAmountsMintAPE(systemParams, inputsOutputs, reservesPre, reserves, balances)
            : _verifyAmountsMintTEA(systemParams, inputsOutputs, reservesPre, reserves, balances);
    }

    function testFuzz_mint1stEverDepositInsufficient(
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs
    ) public {
        SirStructs.Reserves memory reservesPre = SirStructs.Reserves(0, 0, 0);

        _initialize(systemParams, reservesPre);
        _makeFirstDepositEverTooSmall(isAPE, inputsOutputs);

        // Alice mints APE
        vm.startPrank(alice);
        collateral.approve(address(vault), inputsOutputs.collateral);
        vm.expectRevert();
        inputsOutputs.amount = vault.mint(isAPE, vaultParams, inputsOutputs.collateral);
    }

    function testFuzz_mint1stTimeType(
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre,
        Balances memory balances
    ) public {
        _initialize(systemParams, reservesPre);
        _constraintBalances(isAPE, true, reservesPre, balances);
        _makeFirstTypeDeposit(isAPE, systemParams, inputsOutputs, reservesPre);

        // Alice mints APE
        vm.startPrank(alice);
        collateral.approve(address(vault), inputsOutputs.collateral);
        inputsOutputs.amount = vault.mint(isAPE, vaultParams, inputsOutputs.collateral);

        // Check reserves
        SirStructs.Reserves memory reserves = vault.getReserves(vaultParams);

        // No reserve is allowed to be 0
        assertGt(reserves.reserveApes, 0);
        assertGt(reserves.reserveLPers, 0);

        // Ensure total reserve is larger than 1M
        assertGe(reserves.reserveApes + reserves.reserveLPers, 1e6);

        // Verify amounts
        isAPE
            ? _verifyAmountsMintAPE(systemParams, inputsOutputs, reservesPre, reserves, balances)
            : _verifyAmountsMintTEA(systemParams, inputsOutputs, reservesPre, reserves, balances);
    }

    function testFuzz_mint1stTimeTypeDepositInsufficient(
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre,
        Balances memory balances
    ) public {
        _initialize(systemParams, reservesPre);
        _constraintBalances(isAPE, true, reservesPre, balances);
        _makeFirstTypeDepositEverTooSmall(isAPE, systemParams, inputsOutputs, reservesPre);

        // Alice mints APE
        vm.startPrank(alice);
        collateral.approve(address(vault), inputsOutputs.collateral);
        vm.expectRevert();
        vault.mint(isAPE, vaultParams, inputsOutputs.collateral);
    }

    function testFuzz_recursiveStateSave(
        SystemParams calldata systemParams,
        SirStructs.Reserves memory reservesPre,
        Balances memory balances
    ) public {
        _initialize(systemParams, reservesPre);
        _constraintBalances(false, false, reservesPre, balances);

        // Derive and set vault state
        SirStructs.VaultState memory vaultState = _deriveVaultState(reservesPre);
        _setState(vaultState, balances);

        // Retrieve new reserves
        SirStructs.Reserves memory reservesPost = vault.getReserves(vaultParams);

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
                1 + vaultState.reserve / smallErrorTolerance,
                "Rounding error in reserveApes too large"
            );
            assertApproxEqAbs(
                reservesPre.reserveLPers,
                reservesPost.reserveLPers,
                1 + vaultState.reserve / smallErrorTolerance,
                "Rounding error in reserveLPers too large"
            );

            if (reservesPre.tickPriceX42 < vaultState.tickPriceSatX42) {
                assertLe(reservesPre.reserveApes, reservesPost.reserveApes, "In power zone apes should increase");
                assertGe(reservesPre.reserveLPers, reservesPost.reserveLPers, "In power zone LPers should decrease");
            } else if (reservesPre.tickPriceX42 > vaultState.tickPriceSatX42) {
                assertGe(reservesPre.reserveApes, reservesPost.reserveApes, "In saturation zone apes should decrease");
                assertLe(
                    reservesPre.reserveLPers,
                    reservesPost.reserveLPers,
                    "In saturation zone LPers should increase"
                );
            }
        } else {
            assertApproxEqAbs(
                reservesPre.reserveApes,
                reservesPost.reserveApes,
                1 + vaultState.reserve / largeErrorTolerance,
                "Reserve apes is wrong"
            );
            assertApproxEqAbs(
                reservesPre.reserveLPers,
                reservesPost.reserveLPers,
                1 + vaultState.reserve / largeErrorTolerance,
                "Reserve LPers is wrong"
            );
        }
    }

    function testFuzz_mint(
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre,
        Balances memory balances
    ) public {
        _initialize(systemParams, reservesPre);
        _constraintBalances(isAPE, false, reservesPre, balances);
        _makeDeposit(isAPE, systemParams, inputsOutputs, reservesPre, balances);

        // Alice mints APE
        vm.startPrank(alice);
        collateral.approve(address(vault), inputsOutputs.collateral);
        inputsOutputs.amount = vault.mint(isAPE, vaultParams, inputsOutputs.collateral);

        // Retrieve reserves after minting
        SirStructs.Reserves memory reservesPost = vault.getReserves(vaultParams);

        // Verify amounts
        if (isAPE) {
            _verifyAmountsMintAPE(systemParams, inputsOutputs, reservesPre, reservesPost, balances);
        } else {
            _verifyAmountsMintTEA(systemParams, inputsOutputs, reservesPre, reservesPost, balances);
        }
    }

    function testFuzz_burn(
        bool isAPE,
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre,
        Balances memory balances
    ) public {
        _initialize(systemParams, reservesPre);
        _constraintBalances(isAPE, false, reservesPre, balances);
        _constrainAmount(isAPE, inputsOutputs, reservesPre, balances);

        // Alice burns APE
        vm.prank(alice);
        inputsOutputs.collateral = vault.burn(isAPE, vaultParams, inputsOutputs.amount);

        // Retrieve reserves after minting
        SirStructs.Reserves memory reservesPost = vault.getReserves(vaultParams);

        // Verify amounts
        isAPE
            ? _verifyAmountsBurnAPE(systemParams, inputsOutputs, reservesPre, reservesPost, balances)
            : _verifyAmountsBurnTEA(inputsOutputs, reservesPre, reservesPost, balances);
    }

    function testFuzz_mintWrongVaultParameters(
        bool isAPE,
        SystemParams calldata systemParams,
        uint144 collateralAmount,
        SirStructs.Reserves memory reservesPre,
        Balances memory balances,
        SirStructs.VaultParameters memory vaultParams_
    ) public {
        _initialize(systemParams, reservesPre);
        _constraintBalances(isAPE, false, reservesPre, balances);

        // At least 1 unit of collateral to avoid triggering AmountTooLow error
        collateralAmount = uint144(_bound(collateralAmount, 1, type(uint144).max));

        // Ensure the vault does not exist
        vm.assume(
            vaultParams.debtToken != vaultParams_.debtToken ||
                vaultParams.collateralToken != vaultParams_.collateralToken ||
                vaultParams.leverageTier != vaultParams_.leverageTier
        );

        // Mock oracle prices for fake vault, so it does not revert beacause of inexisting Uniswap pool
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

        // Alice mints APE
        vm.startPrank(alice);
        collateral.approve(address(vault), collateralAmount);
        vm.expectRevert(VaultDoesNotExist.selector);
        vault.mint(isAPE, vaultParams_, collateralAmount);
    }

    function testFuzz_burnWrongVaultParameters(
        bool isAPE,
        SystemParams calldata systemParams,
        uint256 tokenAmount,
        SirStructs.Reserves memory reservesPre,
        Balances memory balances,
        SirStructs.VaultParameters memory vaultParams_
    ) public {
        _initialize(systemParams, reservesPre);
        _constraintBalances(isAPE, false, reservesPre, balances);

        // At least 1 token unit to avoid triggering AmountTooLow error
        tokenAmount = _bound(tokenAmount, 1, type(uint256).max);

        // Ensure the vault does not exist
        vm.assume( // Ensure the vault does not exist
                vaultParams.debtToken != vaultParams_.debtToken ||
                    vaultParams.collateralToken != vaultParams_.collateralToken ||
                    vaultParams.leverageTier != vaultParams_.leverageTier
            );

        // Mock oracle prices for fake vault, so it does not revert beacause of inexisting Uniswap pool
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

        // Alice mints APE
        vm.startPrank(alice);
        collateral.approve(address(vault), tokenAmount);
        vm.expectRevert(VaultDoesNotExist.selector);
        vault.burn(isAPE, vaultParams_, tokenAmount);
    }

    function testFuzz_priceFluctuation(
        SystemParams calldata systemParams,
        SirStructs.Reserves memory reservesPre,
        int64 newTickPriceX42
    ) public {
        _initialize(systemParams, reservesPre);

        // Ensure we have enough reserves to not introduce truncation error when price fluctuates
        reservesPre.reserveApes = uint144(_bound(reservesPre.reserveApes, 0, type(uint144).max));
        reservesPre.reserveLPers = uint144(
            _bound(reservesPre.reserveLPers, 0, type(uint144).max - reservesPre.reserveApes)
        );
        vm.assume(reservesPre.reserveApes + reservesPre.reserveLPers >= 1e18);
        SirStructs.VaultState memory vaultState = _deriveVaultState(reservesPre);
        _setState(vaultState, Balances(0, 0, 0, 0, 0));

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
        SirStructs.Reserves memory reservesPost = vault.getReserves(vaultParams);

        // Get vault state
        vaultState = vault.vaultStates(vaultParams);

        if (tickPriceX42 < vaultState.tickPriceSatX42 && newTickPriceX42 < vaultState.tickPriceSatX42) {
            // Price remains in the Power Zone
            console.log("Price remains in the Power Zone");
            assertInPowerZone(vaultState, reservesPre, reservesPost, tickPriceX42, newTickPriceX42);
        } else if (tickPriceX42 > vaultState.tickPriceSatX42 && newTickPriceX42 >= vaultState.tickPriceSatX42) {
            // Price remains in the Saturation Zone
            console.log("Price remains in the Saturation Zone");
            assertInSaturationZone(vaultState, reservesPre, reservesPost, tickPriceX42, newTickPriceX42);
        } else if (tickPriceX42 < vaultState.tickPriceSatX42 && newTickPriceX42 >= vaultState.tickPriceSatX42) {
            // Price goes from the Power Zone to the Saturation Zone
            console.log("Price goes from the Power Zone to the Saturation Zone");
            assertPowerToSaturationZone(vaultState, reservesPre, reservesPost, tickPriceX42, newTickPriceX42);
        } else if (tickPriceX42 > vaultState.tickPriceSatX42 && newTickPriceX42 < vaultState.tickPriceSatX42) {
            // Price goes from the Saturation Zone to the Power Zone
            console.log("Price goes from the Saturation Zone to the Power Zone");
            assertSaturationToPowerZone(vaultState, reservesPre, reservesPost, tickPriceX42, newTickPriceX42);
        }
    }

    /////////////////////////////////////////////////////////////////////////

    function assertInPowerZone(
        SirStructs.VaultState memory vaultState,
        SirStructs.Reserves memory reservesPre,
        SirStructs.Reserves memory reservesPost,
        int64 tickPriceX42,
        int64 newTickPriceX42
    ) internal view {
        bytes16 leverageRatioSub1 = ABDKMathQuad.fromInt(vaultParams.leverageTier).pow_2();
        bytes16 leveragedGain = newTickPriceX42.tickToFP().div(tickPriceX42.tickToFP()).pow(leverageRatioSub1);
        uint256 newReserveApes = ABDKMathQuad.fromUInt(reservesPre.reserveApes).mul(leveragedGain).toUInt();

        uint256 err;
        if (
            // Condition to avoid OF/UFing tickPriceSatX42
            vaultState.tickPriceSatX42 != type(int64).min && vaultState.tickPriceSatX42 != type(int64).max
        ) {
            console.log("Small error");
            err = 2 + vaultState.reserve / smallErrorTolerance;
        } else {
            console.log("Large error");
            err = 3 + vaultState.reserve / largeErrorTolerance;
        }

        assertApproxEqAbs(vaultState.reserve - newReserveApes, reservesPost.reserveLPers, err);
        assertApproxEqAbs(newReserveApes, reservesPost.reserveApes, err);
    }

    function assertInSaturationZone(
        SirStructs.VaultState memory vaultState,
        SirStructs.Reserves memory reservesPre,
        SirStructs.Reserves memory reservesPost,
        int64 tickPriceX42,
        int64 newTickPriceX42
    ) internal pure {
        uint256 newReserveLPers = ABDKMathQuad
            .fromUInt(reservesPre.reserveLPers)
            .mul(tickPriceX42.tickToFP())
            .div(newTickPriceX42.tickToFP())
            .toUInt();

        uint256 err;
        if (
            // Condition to avoid OF/UFing tickPriceSatX42
            vaultState.tickPriceSatX42 != type(int64).min && vaultState.tickPriceSatX42 != type(int64).max
        ) err = 2 + vaultState.reserve / smallErrorTolerance;
        else err = 2 + vaultState.reserve / largeErrorTolerance;

        assertApproxEqAbs(vaultState.reserve - newReserveLPers, reservesPost.reserveApes, err);
        assertApproxEqAbs(newReserveLPers, reservesPost.reserveLPers, err);
    }

    function assertPowerToSaturationZone(
        SirStructs.VaultState memory vaultState,
        SirStructs.Reserves memory reservesPre,
        SirStructs.Reserves memory reservesPost,
        int64 tickPriceX42,
        int64 newTickPriceX42
    ) internal view {
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
        ) {
            console.log("Small error");
            err = 2 + vaultState.reserve / smallErrorTolerance;
        } else {
            console.log("Large error");
            err = 2 + vaultState.reserve / largeErrorTolerance;
        }

        assertApproxEqAbs(newReserveLPers, reservesPost.reserveLPers, err);
        assertApproxEqAbs(newReserveApes, reservesPost.reserveApes, err);
    }

    function assertSaturationToPowerZone(
        SirStructs.VaultState memory vaultState,
        SirStructs.Reserves memory reservesPre,
        SirStructs.Reserves memory reservesPost,
        int64 tickPriceX42,
        int64 newTickPriceX42
    ) internal view {
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
        ) {
            err = 2 + vaultState.reserve / smallErrorTolerance;
        } else {
            err = 2 + vaultState.reserve / largeErrorTolerance;
        }

        assertApproxEqAbs(newReserveLPers, reservesPost.reserveLPers, err);
        assertApproxEqAbs(newReserveApes, reservesPost.reserveApes, err);
    }

    function _deriveVaultState(
        SirStructs.Reserves memory reserves
    ) private view returns (SirStructs.VaultState memory vaultState) {
        unchecked {
            vaultState.vaultId = VAULT_ID;
            vaultState.reserve = reserves.reserveApes + reserves.reserveLPers;

            // To ensure division by 0 does not occur when recoverying the reserves
            require(vaultState.reserve >= 1e6);

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
        SirStructs.Reserves memory reservesPre,
        InputsOutputs memory inputsOutputs,
        Balances memory balances
    ) private view returns (uint144 collateralOut) {
        collateralOut = uint144(FullMath.mulDiv(reservesPre.reserveApes, inputsOutputs.amount, balances.apeSupply));
        SirStructs.Fees memory fees = Fees.feeAPE(
            collateralOut,
            systemParams.baseFee,
            vaultParams.leverageTier,
            systemParams.tax
        );

        SirStructs.VaultState memory vaultState = vault.vaultStates(vaultParams);

        vm.assume(vaultState.reserve >= uint256(1e6) + fees.collateralInOrWithdrawn + fees.collateralFeeToStakers);
    }

    function _constraintReserveBurnTEA(
        SirStructs.Reserves memory reservesPre,
        InputsOutputs memory inputsOutputs,
        Balances memory balances
    ) private view {
        uint144 collateralOut = uint144(
            FullMath.mulDiv(reservesPre.reserveLPers, inputsOutputs.amount, balances.teaSupply)
        );

        SirStructs.VaultState memory vaultState = vault.vaultStates(vaultParams);

        vm.assume(vaultState.reserve >= uint256(1e6) + collateralOut);
    }

    function _verifyAmountsMintAPE(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre,
        SirStructs.Reserves memory reservesPost,
        Balances memory balances
    ) private view {
        // Verify amounts
        SirStructs.Fees memory fees = Fees.feeAPE(
            inputsOutputs.collateral,
            systemParams.baseFee,
            vaultParams.leverageTier,
            systemParams.tax
        );

        // Get collateralState.total reserve
        SirStructs.VaultState memory vaultState = vault.vaultStates(vaultParams);
        assertEq(vaultState.reserve, reservesPost.reserveLPers + reservesPost.reserveApes);

        // No reserve is allowed to be 0
        assertGt(reservesPost.reserveApes, 0);
        assertGt(reservesPost.reserveLPers, 0);
        assertGe(reservesPost.reserveApes + reservesPost.reserveLPers, 1e6);

        // Error tolerance discovered by trial-and-error
        {
            uint256 err;
            if (
                // Condition to avoid OF/UFing tickPriceSatX42
                reservesPre.reserveApes > 1 &&
                reservesPost.reserveApes > 1 &&
                reservesPre.reserveLPers > 1 &&
                reservesPost.reserveLPers > 1
            ) err = 1 + vaultState.reserve / smallErrorTolerance;
            else err = 1 + vaultState.reserve / largeErrorTolerance;

            assertApproxEqAbs(
                reservesPost.reserveApes,
                reservesPre.reserveApes + fees.collateralInOrWithdrawn,
                err,
                "Ape's reserve is wrong"
            );
            assertApproxEqAbs(
                reservesPost.reserveLPers,
                reservesPre.reserveLPers + fees.collateralFeeToLPers,
                err,
                "LPers's reserve is wrong"
            );
        }

        // Verify token state
        uint256 totalReserves = vault.totalReserves(vaultParams.collateralToken);
        assertEq(collateral.balanceOf(address(vault)) - totalReserves, fees.collateralFeeToStakers);
        assertEq(
            collateral.balanceOf(address(vault)),
            reservesPre.reserveLPers + reservesPre.reserveApes + inputsOutputs.collateral,
            "Total reserves does not match"
        );

        // Verify Alice's balances
        if (balances.apeSupply == 0) {
            assertEq(
                inputsOutputs.amount,
                fees.collateralInOrWithdrawn + reservesPre.reserveApes,
                "Minted amount is wrong when APE supply is 0"
            );
        } else if (reservesPre.reserveApes > 0) {
            assertEq(
                inputsOutputs.amount,
                FullMath.mulDiv(balances.apeSupply, fees.collateralInOrWithdrawn, reservesPre.reserveApes),
                "Minted amount is wrong"
            );
        } else {
            revert("Invalid state");
        }
        assertEq(inputsOutputs.amount, ape.balanceOf(alice) - balances.apeAlice);
        assertEq(vault.balanceOf(alice, VAULT_ID), balances.teaAlice);

        // Verify POL TEA balance stays the same
        assertEq(ape.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(address(vault), VAULT_ID), balances.teaVault);
    }

    function _verifyAmountsBurnAPE(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre,
        SirStructs.Reserves memory reservesPost,
        Balances memory balances
    ) private view {
        // Compute amount of collateral
        uint144 collateralOut = uint144(
            FullMath.mulDiv(reservesPre.reserveApes, inputsOutputs.amount, balances.apeSupply)
        );

        // Verify amounts
        SirStructs.Fees memory fees = Fees.feeAPE(
            collateralOut,
            systemParams.baseFee,
            vaultParams.leverageTier,
            systemParams.tax
        );
        reservesPre.reserveApes -= collateralOut;

        assertEq(inputsOutputs.collateral, fees.collateralInOrWithdrawn);

        // Get collateralState.total reserve
        SirStructs.VaultState memory vaultState = vault.vaultStates(vaultParams);
        assertEq(vaultState.reserve, reservesPost.reserveLPers + reservesPost.reserveApes);

        // No reserve is allowed to be 0
        assertGt(reservesPost.reserveApes, 0);
        assertGt(reservesPost.reserveLPers, 0);
        assertGe(reservesPost.reserveApes + reservesPost.reserveLPers, 1e6);

        // Error tolerance discovered by trial-and-error
        {
            uint256 err;
            if (
                // Condition to avoid OF/UFing tickPriceSatX42
                reservesPre.reserveApes > 1 &&
                reservesPost.reserveApes > 1 &&
                reservesPre.reserveLPers > 1 &&
                reservesPost.reserveLPers > 1
            ) err = 1 + vaultState.reserve / smallErrorTolerance;
            else err = 1 + vaultState.reserve / largeErrorTolerance;

            assertApproxEqAbs(reservesPost.reserveApes, reservesPre.reserveApes, err, "Ape's reserve is wrong");
            assertApproxEqAbs(
                reservesPost.reserveLPers,
                reservesPre.reserveLPers + fees.collateralFeeToLPers,
                err,
                "LPers's reserve is wrong"
            );
        }

        // Verify token state
        uint256 totalReserves = vault.totalReserves(vaultParams.collateralToken);
        assertEq(collateral.balanceOf(address(vault)) - totalReserves, fees.collateralFeeToStakers);
        assertEq(
            collateral.balanceOf(address(vault)),
            reservesPre.reserveLPers +
                fees.collateralFeeToLPers +
                reservesPre.reserveApes +
                fees.collateralFeeToStakers,
            "Total reserves does not match"
        );

        // Verify Alice's balances
        assertEq(inputsOutputs.amount, balances.apeAlice - ape.balanceOf(alice));
        assertEq(vault.balanceOf(alice, VAULT_ID), balances.teaAlice);

        // Verify POL's balances
        assertEq(ape.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(address(vault), VAULT_ID), balances.teaVault);
    }

    function _verifyAmountsMintTEA(
        SystemParams calldata systemParams,
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre,
        SirStructs.Reserves memory reservesPost,
        Balances memory balances
    ) private view {
        // Verify amounts
        SirStructs.Fees memory fees = Fees.feeMintTEA(inputsOutputs.collateral, systemParams.lpFee);

        // Get collateralState.total reserve
        SirStructs.VaultState memory vaultState = vault.vaultStates(vaultParams);
        assertEq(vaultState.reserve, reservesPost.reserveLPers + reservesPost.reserveApes);

        // No reserve is allowed to be 0
        assertGt(reservesPost.reserveApes, 0);
        assertGt(reservesPost.reserveLPers, 0);
        assertGe(reservesPost.reserveApes + reservesPost.reserveLPers, 1e6);

        // Error tolerance discovered by trial-and-error
        {
            uint256 err;
            if (
                // Condition to avoid OF/UFing tickPriceSatX42
                reservesPre.reserveApes > 1 &&
                reservesPost.reserveApes > 1 &&
                reservesPre.reserveLPers > 1 &&
                reservesPost.reserveLPers > 1
            ) err = 1 + vaultState.reserve / smallErrorTolerance;
            else err = 1 + vaultState.reserve / largeErrorTolerance;

            assertApproxEqAbs(
                reservesPost.reserveLPers,
                reservesPre.reserveLPers + fees.collateralInOrWithdrawn + fees.collateralFeeToLPers,
                err,
                "LPers's reserve is wrong"
            );
            assertApproxEqAbs(reservesPost.reserveApes, reservesPre.reserveApes, err, "Apes's reserve has changed");
        }

        // Verify token state
        uint256 totalReserves = vault.totalReserves(vaultParams.collateralToken);
        assertEq(collateral.balanceOf(address(vault)), totalReserves);
        assertEq(
            collateral.balanceOf(address(vault)),
            reservesPre.reserveLPers + reservesPre.reserveApes + inputsOutputs.collateral
        );

        // Verify POL's balances
        uint128 amountPol = uint128(vault.balanceOf(address(vault), VAULT_ID) - balances.teaVault);
        if (balances.teaSupply == 0) {
            if (fees.collateralFeeToLPers + reservesPre.reserveLPers == 0) {
                assertEq(amountPol, 0, "Amount of POL is not 0");
            }
        } else if (reservesPre.reserveLPers == 0) {
            revert("Invalid state");
        } else {
            uint256 amountPOL_ = FullMath.mulDiv(
                balances.teaSupply,
                fees.collateralFeeToLPers,
                reservesPre.reserveLPers
            );
            assertApproxEqAbs(amountPol, amountPOL_, 1, "TEA minted for POL is wrong"); // Due to the different way it's computed in the contract, the results can differ by 1
        }
        assertEq(ape.balanceOf(address(vault)), 0, "Vault's APE balance is not 0");

        // Verify Alice's balances
        if (fees.collateralInOrWithdrawn == 0) {
            assertEq(inputsOutputs.amount, 0, "Minted amount is not 0");
        } else if (balances.teaSupply > 0) {
            uint256 amount_ = FullMath.mulDiv(
                balances.teaSupply,
                fees.collateralInOrWithdrawn,
                reservesPre.reserveLPers
            );
            assertApproxEqAbs(inputsOutputs.amount, amount_, 1, "Minted amount is wrong"); // Due to the different way it's computed in the contract, the results can differ by 1
        }

        assertEq(inputsOutputs.amount, vault.balanceOf(alice, VAULT_ID) - balances.teaAlice, "Minted amount is wrong");
        assertEq(ape.balanceOf(alice), balances.apeAlice, "Alice's APE balance is wrong");
    }

    function _verifyAmountsBurnTEA(
        InputsOutputs memory inputsOutputs,
        SirStructs.Reserves memory reservesPre,
        SirStructs.Reserves memory reservesPost,
        Balances memory balances
    ) private view {
        // Compute amount of collateral
        uint144 collateralOut = uint144(
            FullMath.mulDiv(reservesPre.reserveLPers, inputsOutputs.amount, balances.teaSupply)
        );

        // Verify amounts
        assertEq(inputsOutputs.collateral, collateralOut);

        // Get collateralState.total reserve
        SirStructs.VaultState memory vaultState = vault.vaultStates(vaultParams);
        assertEq(vaultState.reserve, reservesPost.reserveLPers + reservesPost.reserveApes);

        // No reserve is allowed to be 0
        assertGt(reservesPost.reserveApes, 0);
        assertGt(reservesPost.reserveLPers, 0);
        assertGe(reservesPost.reserveApes + reservesPost.reserveLPers, 1e6);

        // Error tolerance discovered by trial-and-error
        {
            uint256 err;
            if (
                // Condition to avoid OF/UFing tickPriceSatX42
                reservesPre.reserveApes > 1 &&
                reservesPre.reserveLPers > 1 &&
                reservesPost.reserveApes > 1 &&
                reservesPost.reserveLPers > 1
            ) err = 1 + vaultState.reserve / smallErrorTolerance;
            else err = 1 + vaultState.reserve / largeErrorTolerance;

            assertApproxEqAbs(
                reservesPost.reserveLPers,
                reservesPre.reserveLPers - collateralOut,
                err,
                "LPers's reserve is wrong"
            );
            assertApproxEqAbs(reservesPost.reserveApes, reservesPre.reserveApes, err, "Apes's reserve has changed");
        }

        // Verify token state
        uint256 totalReserves = vault.totalReserves(vaultParams.collateralToken);
        assertEq(collateral.balanceOf(address(vault)), totalReserves);
        assertEq(
            collateral.balanceOf(address(vault)),
            reservesPre.reserveLPers - collateralOut + reservesPre.reserveApes
        );

        // Verify Alice's balances
        assertEq(inputsOutputs.amount, balances.teaAlice - vault.balanceOf(alice, VAULT_ID));
        assertEq(ape.balanceOf(alice), balances.apeAlice);

        // Verify POL balance hasn not changed
        assertEq(vault.balanceOf(address(vault), VAULT_ID), balances.teaVault);
        assertEq(ape.balanceOf(address(vault)), 0, "Vault's APE balance is not 0");
    }

    function _setState(SirStructs.VaultState memory vaultState, Balances memory balances) private {
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
                                SLOT_VAULT_STATE // slot of vaultStates
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
        SirStructs.VaultState memory vaultState_ = vault.vaultStates(vaultParams);

        assertEq(vaultState_.reserve, vaultState.reserve, "Wrong slot used by vm.store");
        assertEq(vaultState_.tickPriceSatX42, vaultState.tickPriceSatX42, "Wrong slot used by vm.store");
        assertEq(vaultState_.vaultId, VAULT_ID, "Wrong slot used by vm.store");

        // Set total reserves
        slot = keccak256(abi.encode(vaultParams.collateralToken, SLOT_TOTAL_RESERVES));
        vm.store(address(vault), slot, bytes32(uint256(vaultState.reserve)));
        uint256 totalReserves = vault.totalReserves(vaultParams.collateralToken);
        assertEq(vaultState.reserve, totalReserves, "Wrong slot used by vm.store");

        // Set the total supply of APE
        vm.store(address(ape), bytes32(SLOT_TOTAL_SUPPLY_APE), bytes32(balances.apeSupply));
        assertEq(ape.totalSupply(), balances.apeSupply, "Wrong slot used by vm.store");

        // Set the Alice's APE balance
        slot = keccak256(
            abi.encode(
                alice,
                SLOT_APE_BALANCE_OF // slot of balanceOf
            )
        );
        vm.store(address(ape), slot, bytes32(balances.apeAlice));
        assertEq(ape.balanceOf(alice), balances.apeAlice, "Wrong slot used by vm.store");

        // Set the total supply of TEA and the vault balance
        slot = keccak256(
            abi.encode(
                uint256(VAULT_ID),
                SLOT_TOTAL_SUPPLY_TEA // Slot of totalSupplyAndBalanceVault
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
                        SLOT_TEA_BALANCE_OF // slot of balances
                    )
                )
            )
        );
        vm.store(address(vault), slot, bytes32(uint256(balances.teaAlice)));
        assertEq(vault.balanceOf(alice, VAULT_ID), balances.teaAlice, "Wrong slot used by vm.store");
    }
}

contract VaultTestWithETH is Test {
    error NotAWETHVault();

    Vault public vault;
    IWETH9 public weth = IWETH9(Addresses.ADDR_WETH);

    address public alice = vm.addr(3);

    SirStructs.VaultParameters public vaultParams =
        SirStructs.VaultParameters(Addresses.ADDR_USDC, Addresses.ADDR_WETH, -1);

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        // Deploy oracle
        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

        // Deploy APE implementation
        APE apeImplementation = new APE();

        // Deploy vault
        vault = new Vault(vm.addr(1), vm.addr(2), oracle, address(apeImplementation), Addresses.ADDR_WETH);

        // _initialize vault
        vault.initialize(vaultParams);
    }

    function test_mint(bool isAPE, uint256 amountETH, uint144 falseAmountETH) public {
        // Constraint the amount of ETH
        amountETH = _bound(amountETH, 2, 2 ** 96);

        // Alice mints APE
        deal(alice, amountETH);
        vm.prank(alice);
        vault.mint{value: amountETH}(isAPE, vaultParams, falseAmountETH);

        // Check the total reserve
        assertEq(weth.balanceOf(address(vault)), amountETH, "Wrong total reserve");
    }

    function test_mintTooLittle(bool isAPE, uint256 amountETH, uint144 falseAmountETH) public {
        // Constraint the amount of ETH
        amountETH = _bound(amountETH, 0, 1);

        // Alice mints APE
        deal(alice, amountETH);
        vm.prank(alice);
        vm.expectRevert();
        vault.mint{value: amountETH}(isAPE, vaultParams, falseAmountETH);
    }

    function test_mintNotAWETHVault(bool isAPE, uint256 amountETH, uint144 falseAmountETH) public {
        // _initialize a non-WETH vault
        SirStructs.VaultParameters memory vaultParams2 = SirStructs.VaultParameters(
            Addresses.ADDR_WETH,
            Addresses.ADDR_USDC,
            -1
        );
        vault.initialize(vaultParams2);

        // Constraint the amount of ETH
        amountETH = _bound(amountETH, 2, 2 ** 96);

        // Alice mints APE
        deal(alice, amountETH);
        vm.prank(alice);
        vm.expectRevert(NotAWETHVault.selector);
        vault.mint{value: amountETH}(isAPE, vaultParams2, falseAmountETH);
    }
}

contract VaultControlTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    IWETH9 private constant WETH = IWETH9(Addresses.ADDR_WETH);

    uint256 constant SLOT_TOTAL_RESERVES = 8;
    uint96 constant ETH_SUPPLY = 120e6 * 10 ** 18;

    address public systemControl = vm.addr(1);
    address public sir = vm.addr(2);

    Vault public vault;

    struct TokenFees {
        uint256 fees;
        uint256 total;
    }

    struct BuggyERC20 {
        bool balanceOfReverts;
        bool balanceOfReturnsWrongLength;
        bool transferReverts;
        bool transferReturnsFalse;
    }

    struct Balances4Tokens {
        uint256 balanceOfWETH;
        uint256 balanceOfBNB;
        uint256 balanceOfUSDT;
        uint256 balanceOfUSDC;
    }

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        // Deploy APE implementation
        APE apeImplementation = new APE();

        // Deploy vault
        vault = new Vault(systemControl, sir, vm.addr(3), address(apeImplementation), Addresses.ADDR_WETH);
    }

    function testFuzz_withdrawFeesFailsCuzNotSIR(address user, TokenFees memory tokenFees) public {
        // Add fees to vault
        _setFees(Addresses.ADDR_WETH, tokenFees);

        // Withdraw WETH
        vm.expectRevert();
        vm.prank(user);
        vault.withdrawFees(Addresses.ADDR_WETH);
    }

    function testFuzz_withdrawWETH(TokenFees memory tokenFees) public {
        // Add fees to vault
        _setFees(Addresses.ADDR_WETH, tokenFees);

        // Withdraw WETH
        if (tokenFees.fees != 0) {
            vm.expectEmit();
            emit Transfer(address(vault), sir, tokenFees.fees);
        }
        vm.prank(sir);
        uint256 totalFeesToStakers = vault.withdrawFees(Addresses.ADDR_WETH);

        // Assert balances
        assertEq(totalFeesToStakers, tokenFees.fees);
        assertEq(WETH.balanceOf(sir), tokenFees.fees);
        assertEq(WETH.balanceOf(address(vault)), tokenFees.total);
    }

    function testFuzz_withdrawBNB(TokenFees memory tokenFees) public {
        // Add fees to vault
        _setFees(Addresses.ADDR_BNB, tokenFees);

        // Withdraw BNB
        if (tokenFees.fees != 0) {
            vm.expectEmit();
            emit Transfer(address(vault), sir, tokenFees.fees);
        }
        vm.prank(sir);
        uint256 totalFeesToStakers = vault.withdrawFees(Addresses.ADDR_BNB);

        // Assert balances
        assertEq(totalFeesToStakers, tokenFees.fees, "Wrong total fees to stakers");
        assertEq(IERC20(Addresses.ADDR_BNB).balanceOf(sir), tokenFees.fees, "Wrong BNB balance of SIR contract");
        assertEq(IERC20(Addresses.ADDR_BNB).balanceOf(address(vault)), tokenFees.total, "Wrong BNB balance of vault");
    }

    function testFuzz_withdrawUSDT(TokenFees memory tokenFees) public {
        // Add fees to vault
        _setFees(Addresses.ADDR_USDT, tokenFees);

        // Withdraw USDT
        if (tokenFees.fees != 0) {
            vm.expectEmit();
            emit Transfer(address(vault), sir, tokenFees.fees);
        }
        vm.prank(sir);
        uint256 totalFeesToStakers = vault.withdrawFees(Addresses.ADDR_USDT);

        // Assert balances
        assertEq(totalFeesToStakers, tokenFees.fees);
        assertEq(IERC20(Addresses.ADDR_USDT).balanceOf(sir), tokenFees.fees);
        assertEq(IERC20(Addresses.ADDR_USDT).balanceOf(address(vault)), tokenFees.total);
    }

    function testFuzz_withdrawUSDC(TokenFees memory tokenFees) public {
        // Add fees to vault
        _setFees(Addresses.ADDR_USDC, tokenFees);

        // Withdraw USDC
        if (tokenFees.fees != 0) {
            vm.expectEmit();
            emit Transfer(address(vault), sir, tokenFees.fees);
        }
        vm.prank(sir);
        uint256 totalFeesToStakers = vault.withdrawFees(Addresses.ADDR_USDC);

        // Assert balances
        assertEq(totalFeesToStakers, tokenFees.fees);
        assertEq(IERC20(Addresses.ADDR_USDC).balanceOf(sir), tokenFees.fees);
        assertEq(IERC20(Addresses.ADDR_USDC).balanceOf(address(vault)), tokenFees.total);
    }

    function testFuzz_withdrawToSaveSystemFailsCuzNotSystemControl(
        address user,
        TokenFees memory tokenFeesWETH,
        TokenFees memory tokenFeesBNB,
        TokenFees memory tokenFeesUSDT,
        TokenFees memory tokenFeesUSDC
    ) public {
        // Add fees to vault
        _setFees(Addresses.ADDR_WETH, tokenFeesWETH);
        _setFees(Addresses.ADDR_BNB, tokenFeesBNB);
        _setFees(Addresses.ADDR_USDT, tokenFeesUSDT);
        _setFees(Addresses.ADDR_USDC, tokenFeesUSDC);

        // Use the encoded calldata in a low-level call or another contract interaction
        address[] memory tokens = new address[](4);
        tokens[0] = Addresses.ADDR_WETH;
        tokens[1] = Addresses.ADDR_BNB;
        tokens[2] = Addresses.ADDR_USDT;
        tokens[3] = Addresses.ADDR_USDC;

        // Fails to save system
        vm.prank(user);
        vm.expectRevert();
        vault.withdrawToSaveSystem(tokens, address(this));
    }

    function testFuzz_withdrawToSaveSystem(
        address to,
        TokenFees memory tokenFeesWETH,
        TokenFees memory tokenFeesBNB,
        TokenFees memory tokenFeesUSDT,
        TokenFees memory tokenFeesUSDC
    ) public {
        to = address(uint160(_bound(uint160(to), 1, type(uint160).max)));

        Balances4Tokens memory preBalances4Tokens = _computeBalances(to);

        // Add fees to vault
        _setFees(Addresses.ADDR_WETH, tokenFeesWETH);
        _setFees(Addresses.ADDR_BNB, tokenFeesBNB);
        _setFees(Addresses.ADDR_USDT, tokenFeesUSDT);
        _setFees(Addresses.ADDR_USDC, tokenFeesUSDC);

        // Use the encoded calldata in a low-level call or another contract interaction
        address[] memory tokens = new address[](4);
        tokens[0] = Addresses.ADDR_WETH;
        tokens[1] = Addresses.ADDR_BNB;
        tokens[2] = Addresses.ADDR_USDT;
        tokens[3] = Addresses.ADDR_USDC;
        if (tokenFeesWETH.total + tokenFeesWETH.fees > 0) {
            vm.expectEmit();
            emit Transfer(address(vault), to, tokenFeesWETH.total + tokenFeesWETH.fees);
        }
        if (tokenFeesBNB.total + tokenFeesBNB.fees > 0) {
            vm.expectEmit();
            emit Transfer(address(vault), to, tokenFeesBNB.total + tokenFeesBNB.fees);
        }
        if (tokenFeesUSDT.total + tokenFeesUSDT.fees > 0) {
            vm.expectEmit();
            emit Transfer(address(vault), to, tokenFeesUSDT.total + tokenFeesUSDT.fees);
        }
        if (tokenFeesUSDC.total + tokenFeesUSDC.fees > 0) {
            vm.expectEmit();
            emit Transfer(address(vault), to, tokenFeesUSDC.total + tokenFeesUSDC.fees);
        }
        vm.prank(systemControl);
        uint256[] memory amounts = vault.withdrawToSaveSystem(tokens, to);

        // Assert balances
        assertEq(amounts[0], tokenFeesWETH.total + tokenFeesWETH.fees, "Wrong amounts[0]");
        assertEq(amounts[1], tokenFeesBNB.total + tokenFeesBNB.fees, "Wrong amounts[1]");
        assertEq(amounts[2], tokenFeesUSDT.total + tokenFeesUSDT.fees, "Wrong amounts[2]");
        assertEq(amounts[3], tokenFeesUSDC.total + tokenFeesUSDC.fees, "Wrong amounts[3]");

        Balances4Tokens memory balances4Tokens = _computeBalances(to);
        assertEq(
            balances4Tokens.balanceOfWETH - preBalances4Tokens.balanceOfWETH,
            tokenFeesWETH.total + tokenFeesWETH.fees,
            "Wrong WETH balance"
        );
        assertEq(
            balances4Tokens.balanceOfBNB - preBalances4Tokens.balanceOfBNB,
            tokenFeesBNB.total + tokenFeesBNB.fees,
            "Wrong BNB balance"
        );
        assertEq(
            balances4Tokens.balanceOfUSDT - preBalances4Tokens.balanceOfUSDT,
            tokenFeesUSDT.total + tokenFeesUSDT.fees,
            "Wrong USDT balance"
        );
        assertEq(
            balances4Tokens.balanceOfUSDC - preBalances4Tokens.balanceOfUSDC,
            tokenFeesUSDC.total + tokenFeesUSDC.fees,
            "Wrong USDC balance"
        );
    }

    function testFuzz_withdrawToSaveSystemBuggyERC20(
        address to,
        TokenFees memory tokenFeesWETH,
        BuggyERC20 calldata buggyWETH,
        TokenFees memory tokenFeesBNB,
        BuggyERC20 calldata buggyBNB,
        TokenFees memory tokenFeesUSDT,
        BuggyERC20 calldata buggyUSDT,
        TokenFees memory tokenFeesUSDC,
        BuggyERC20 calldata buggyUSDC
    ) public {
        to = address(uint160(_bound(uint160(to), 1, type(uint160).max)));

        Balances4Tokens memory preBalances4Tokens = _computeBalances(to);

        // Add fees to vault
        _setFees(Addresses.ADDR_WETH, tokenFeesWETH);
        _setFees(Addresses.ADDR_BNB, tokenFeesBNB);
        _setFees(Addresses.ADDR_USDT, tokenFeesUSDT);
        _setFees(Addresses.ADDR_USDC, tokenFeesUSDC);

        // Modify ERC20 behavior
        _modifyERC20(Addresses.ADDR_WETH, tokenFeesWETH, buggyWETH);
        _modifyERC20(Addresses.ADDR_BNB, tokenFeesBNB, buggyBNB);
        _modifyERC20(Addresses.ADDR_USDT, tokenFeesUSDT, buggyUSDT);
        _modifyERC20(Addresses.ADDR_USDC, tokenFeesUSDC, buggyUSDC);

        // Use the encoded calldata in a low-level call or another contract interaction
        address[] memory tokens = new address[](4);
        tokens[0] = Addresses.ADDR_WETH;
        tokens[1] = Addresses.ADDR_BNB;
        tokens[2] = Addresses.ADDR_USDT;
        tokens[3] = Addresses.ADDR_USDC;
        vm.prank(systemControl);
        uint256[] memory amounts = vault.withdrawToSaveSystem(tokens, to);

        // Set amounts to 0 if buggy ERC20
        if (
            buggyWETH.balanceOfReverts ||
            buggyWETH.balanceOfReturnsWrongLength ||
            buggyWETH.transferReverts ||
            buggyWETH.transferReturnsFalse
        ) {
            tokenFeesWETH.total = 0;
            tokenFeesWETH.fees = 0;
        }
        if (
            buggyBNB.balanceOfReverts ||
            buggyBNB.balanceOfReturnsWrongLength ||
            buggyBNB.transferReverts ||
            buggyBNB.transferReturnsFalse
        ) {
            tokenFeesBNB.total = 0;
            tokenFeesBNB.fees = 0;
        }
        if (
            buggyUSDT.balanceOfReverts ||
            buggyUSDT.balanceOfReturnsWrongLength ||
            buggyUSDT.transferReverts ||
            buggyUSDT.transferReturnsFalse
        ) {
            tokenFeesUSDT.total = 0;
            tokenFeesUSDT.fees = 0;
        }
        if (
            buggyUSDC.balanceOfReverts ||
            buggyUSDC.balanceOfReturnsWrongLength ||
            buggyUSDC.transferReverts ||
            buggyUSDC.transferReturnsFalse
        ) {
            tokenFeesUSDC.total = 0;
            tokenFeesUSDC.fees = 0;
        }

        // Assert balances
        vm.clearMockedCalls();
        assertEq(amounts[0], tokenFeesWETH.total + tokenFeesWETH.fees, "Wrong amounts[0]");
        assertEq(amounts[1], tokenFeesBNB.total + tokenFeesBNB.fees, "Wrong amounts[1]");
        assertEq(amounts[2], tokenFeesUSDT.total + tokenFeesUSDT.fees, "Wrong amounts[2]");
        assertEq(amounts[3], tokenFeesUSDC.total + tokenFeesUSDC.fees, "Wrong amounts[3]");

        Balances4Tokens memory balances4Tokens = _computeBalances(to);
        assertEq(
            balances4Tokens.balanceOfWETH - preBalances4Tokens.balanceOfWETH,
            tokenFeesWETH.total + tokenFeesWETH.fees,
            "Wrong WETH balance"
        );
        assertEq(
            balances4Tokens.balanceOfBNB - preBalances4Tokens.balanceOfBNB,
            tokenFeesBNB.total + tokenFeesBNB.fees,
            "Wrong BNB balance"
        );
        assertEq(
            balances4Tokens.balanceOfUSDT - preBalances4Tokens.balanceOfUSDT,
            tokenFeesUSDT.total + tokenFeesUSDT.fees,
            "Wrong USDT balance"
        );
        assertEq(
            balances4Tokens.balanceOfUSDC - preBalances4Tokens.balanceOfUSDC,
            tokenFeesUSDC.total + tokenFeesUSDC.fees,
            "Wrong USDC balance"
        );
    }

    //////////////////////////////////////////////////////////////////

    function _computeBalances(address to) private view returns (Balances4Tokens memory) {
        return
            Balances4Tokens({
                balanceOfWETH: WETH.balanceOf(to),
                balanceOfBNB: IERC20(Addresses.ADDR_BNB).balanceOf(to),
                balanceOfUSDT: IERC20(Addresses.ADDR_USDT).balanceOf(to),
                balanceOfUSDC: IERC20(Addresses.ADDR_USDC).balanceOf(to)
            });
    }

    function _modifyERC20(address token, TokenFees memory tokenFees, BuggyERC20 calldata buggy) internal {
        if (buggy.balanceOfReverts) {
            vm.mockCallRevert(token, abi.encodeWithSelector(IERC20.balanceOf.selector, address(vault)), "");
        } else if (buggy.balanceOfReturnsWrongLength) {
            vm.mockCall(
                token,
                abi.encodeWithSelector(IERC20.balanceOf.selector, address(vault)),
                abi.encode(uint8(1), tokenFees.total + tokenFees.fees) // Longer than 1 word
            );
        }

        if (buggy.transferReverts) {
            vm.mockCallRevert(token, abi.encodeWithSelector(IERC20.transfer.selector), "");
        } else if (buggy.transferReturnsFalse) {
            vm.mockCall(token, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(false));
        }
    }

    function _setFees(address token, TokenFees memory tokenFees) internal {
        // Bound variables
        tokenFees.fees = _bound(tokenFees.fees, 0, type(uint256).max - IERC20(token).totalSupply());
        tokenFees.total = _bound(tokenFees.total, 0, type(uint256).max - IERC20(token).totalSupply() - tokenFees.fees);
        if (token == Addresses.ADDR_WETH) {
            tokenFees.total = _bound(tokenFees.total, 0, ETH_SUPPLY);
        } else {
            // Each vault can have at most 2^144 tokens and there are at most 2^48 vaults
            tokenFees.total = _bound(tokenFees.total, 0, 2 ** (144 + 48));
        }

        // Send tokens to Vault
        if (token == Addresses.ADDR_WETH) _dealWETH(address(vault), tokenFees.total + tokenFees.fees);
        else _dealToken(token, address(vault), tokenFees.total + tokenFees.fees);

        // Set total reserves
        bytes32 slot = keccak256(abi.encode(token, SLOT_TOTAL_RESERVES));
        vm.store(address(vault), slot, bytes32(tokenFees.total));
        uint256 totalReserves = vault.totalReserves(token);
        assertEq(vault.totalReserves(token), tokenFees.total, "Wrong token total reserves");
        assertEq(
            tokenFees.fees,
            IERC20(token).balanceOf(address(vault)) - totalReserves,
            "Wrong token fees to stakers"
        );
    }

    function _dealWETH(address to, uint256 amount) internal {
        vm.deal(vm.addr(2), amount);
        vm.prank(vm.addr(2));
        WETH.deposit{value: amount}();
        vm.prank(vm.addr(2));
        WETH.transfer(address(to), amount);
    }

    function _dealToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        deal(token, vm.addr(2), amount, true);
        vm.prank(vm.addr(2));
        TransferHelper.safeTransfer(token, to, amount);
    }
}

contract RegimeEnum {
    enum Regime {
        Any,
        Power,
        Saturation
    }
}

// contract VaultHandler is Test, RegimeEnum {
//     using ABDKMathQuad for bytes16;
//     using ExtraABDKMathQuad for int64;
//     using BonusABDKMathQuad for bytes16;

//     struct InputOutput {
//         bool advanceBlock;
//         uint48 vaultId;
//         uint256 userId;
//         uint144 amountCollateral;
//     }

//     uint256 constant smallErrorTolerance = 1e16;

//     uint256 public constant TIME_ADVANCE = 5 minutes;
//     Regime immutable regime;

//     IWETH9 private constant _WETH = IWETH9(Addresses.ADDR_WETH);
//     Vault public vault;
//     Oracle public oracle;
//     address public apeImplementation;

//     uint256 public blockNumber;
//     uint256 public iterations;

//     SirStructs.Reserves public reserves;
//     uint256 public supplyAPE;
//     uint256 public supplyTEA;
//     int64 public priceTick;

//     SirStructs.Reserves public reservesOld;
//     uint256 public supplyAPEOld;
//     uint256 public supplyTEAOld;
//     int64 public priceTickOld;

//     // Dummy variables
//     address public user;
//     address public ape;
//     SirStructs.VaultParameters public vaultParameters;

//     SirStructs.VaultParameters public vaultParameters1 =
//         SirStructs.VaultParameters({
//             debtToken: Addresses.ADDR_USDT,
//             collateralToken: Addresses.ADDR_WETH,
//             leverageTier: int8(1)
//         });

//     SirStructs.VaultParameters public vaultParameters2 =
//         SirStructs.VaultParameters({
//             debtToken: Addresses.ADDR_USDC,
//             collateralToken: Addresses.ADDR_WETH,
//             leverageTier: int8(-2)
//         });

//     modifier advanceBlock(InputOutput memory inputOutput) {
//         console.log("------Advance--Block------");

//         if (regime != Regime.Any || inputOutput.advanceBlock) {
//             blockNumber += TIME_ADVANCE / 12 seconds;
//         }

//         // Fork mainnet
//         vm.createSelectFork("mainnet", blockNumber);
//         if (regime != Regime.Any) {
//             inputOutput.vaultId = 1;
//         }
//         console.log("Block number", blockNumber);

//         // Get vault parameters
//         inputOutput.vaultId = uint48(idToVault(inputOutput.vaultId));

//         // Get reserves
//         reserves = vault.getReserves(vaultParameters);
//         supplyAPE = IERC20(ape).totalSupply();
//         supplyTEA = vault.totalSupply(inputOutput.vaultId);
//         priceTick = oracle.getPrice(vaultParameters.collateralToken, vaultParameters.debtToken);
//         console.log("Reserve LPers", reserves.reserveLPers, ", Reserve Apes", reserves.reserveApes);

//         _;

//         // Get reserves
//         reserves = vault.getReserves(vaultParameters);
//         supplyAPE = IERC20(ape).totalSupply();
//         supplyTEA = vault.totalSupply(inputOutput.vaultId);
//         priceTick = oracle.getPrice(vaultParameters.collateralToken, vaultParameters.debtToken);

//         // Check regime
//         _checkRegime();
//         console.log("Reserve LPers", reserves.reserveLPers, ", Reserve Apes", reserves.reserveApes);
//         console.log(string.concat("Leverage tier: ", vm.toString(vaultParameters.leverageTier)));

//         if (regime != Regime.Any || inputOutput.advanceBlock) iterations++;

//         _invariantTotalCollateral();
//         if (regime == Regime.Power) _invariantPowerZone();
//         else if (regime == Regime.Saturation) _invariantSaturationZone();

//         if (regime == Regime.Saturation || (regime == Regime.Power && supplyAPEOld == 0)) {
//             // Update storage
//             reservesOld = reserves;
//             supplyAPEOld = supplyAPE;
//             supplyTEAOld = supplyTEA;
//             priceTickOld = priceTick;
//         }
//     }

//     constructor(uint256 blockNumber_, Regime regime_) {
//         // vm.writeFile("./gains.log", "");
//         blockNumber = blockNumber_;
//         regime = regime_;

//         oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);
//         apeImplementation = address(new APE());
//         vault = new Vault(vm.addr(100), vm.addr(101), address(oracle), apeImplementation, Addresses.ADDR_WETH);

//         // Set tax between 2 vaults
//         vm.prank(vm.addr(100));
//         {
//             uint48[] memory oldVaults = new uint48[](0);
//             uint48[] memory newVaults = new uint48[](2);
//             newVaults[0] = 1;
//             newVaults[1] = 2;
//             uint8[] memory newTaxes = new uint8[](2);
//             newTaxes[0] = 228;
//             newTaxes[1] = 114; // Ensure 114^2+228^2 <= (2^8-1)^2
//             vault.updateVaults(oldVaults, newVaults, newTaxes, 342);
//         }

//         // Intialize vault 2xETH/USDT
//         vault.initialize(vaultParameters1);

//         // Intialize vault 1.25xETH/USDC
//         vault.initialize(vaultParameters2);
//     }

//     function mint(bool isAPE, InputOutput memory inputOutput) external advanceBlock(inputOutput) {
//         console.log("Mint after advancedBlock");

//         // Sufficient condition to not overflow the reserve
//         uint256 totalReserves = vault.totalReserves(vaultParameters.collateralToken);
//         inputOutput.amountCollateral = uint144(
//             _bound(inputOutput.amountCollateral, 1, type(uint144).max - totalReserves)
//         );

//         bool success;
//         uint256 maxCollateralAmount;
//         if (isAPE) {
//             // Sufficient condition to not overflow APE supply
//             (success, maxCollateralAmount) = FullMath.tryMulDiv(
//                 reserves.reserveApes,
//                 type(uint256).max - supplyAPE,
//                 supplyAPE
//             );
//             if (success) {
//                 inputOutput.amountCollateral = uint144(_bound(inputOutput.amountCollateral, 0, maxCollateralAmount));
//             }

//             if (regime == Regime.Power) {
//                 // Do not mint too much APE that it changes to Saturation
//                 maxCollateralAmount = vaultParameters.leverageTier < 0
//                     ? uint256(reserves.reserveLPers) << uint8(-vaultParameters.leverageTier)
//                     : reserves.reserveLPers >> uint8(vaultParameters.leverageTier);

//                 if (maxCollateralAmount < reserves.reserveApes) revert("Saturation zone");

//                 maxCollateralAmount -= reserves.reserveApes;

//                 inputOutput.amountCollateral = uint144(_bound(inputOutput.amountCollateral, 0, maxCollateralAmount));
//             }
//         }

//         {
//             // Sufficient condition to not overflow TEA supply
//             (success, maxCollateralAmount) = FullMath.tryMulDiv(
//                 (isAPE ? uint256(10) : 1) * reserves.reserveLPers,
//                 SystemConstants.TEA_MAX_SUPPLY - supplyTEA,
//                 supplyTEA
//             );
//             if (success) {
//                 inputOutput.amountCollateral = uint144(_bound(inputOutput.amountCollateral, 0, maxCollateralAmount));
//             }
//         }

//         if (regime == Regime.Saturation && !isAPE) {
//             // Do not mint too much TEA that it changes to Power
//             maxCollateralAmount = vaultParameters.leverageTier > 0
//                 ? uint256(reserves.reserveApes) << uint8(vaultParameters.leverageTier)
//                 : reserves.reserveApes >> uint8(-vaultParameters.leverageTier);

//             console.log("Max collateral amount", maxCollateralAmount, "reserveLPers", reserves.reserveLPers);
//             if (maxCollateralAmount < reserves.reserveLPers) revert("Power zone");

//             maxCollateralAmount -= reserves.reserveLPers;

//             inputOutput.amountCollateral = uint144(
//                 _bound(inputOutput.amountCollateral, 0, (isAPE ? uint256(10) : 1) * maxCollateralAmount)
//             );
//         }

//         // Cannot mint 1 single unit of collateral if TEA supply is 0
//         if (
//             (reserves.reserveApes + reserves.reserveLPers > 0 || inputOutput.amountCollateral >= 2) &&
//             inputOutput.amountCollateral != 0
//         ) {
//             // User
//             user = _idToAddr(inputOutput.userId);

//             // Deal ETH
//             vm.deal(user, inputOutput.amountCollateral);

//             console.log("------Mint--Attempt------");
//             console.log(inputOutput.amountCollateral, "collateral");

//             // Mint with WETH
//             vm.startPrank(user);
//             _WETH.deposit{value: inputOutput.amountCollateral}();
//             _WETH.approve(address(vault), inputOutput.amountCollateral);
//             _checkRegime();
//             vault.mint(isAPE, vaultParameters, inputOutput.amountCollateral);
//             vm.stopPrank();
//         }
//     }

//     function burn(bool isAPE, InputOutput memory inputOutput, uint256 amount) external advanceBlock(inputOutput) {
//         console.log("------Burn--Attempt------");
//         console.log(amount, isAPE ? "APE" : "TEA");

//         // User
//         user = _idToAddr(inputOutput.userId);

//         // Ensure user has enough balance
//         uint256 balance = isAPE ? IERC20(ape).balanceOf(user) : vault.balanceOf(user, inputOutput.vaultId);
//         amount = _bound(amount, 0, balance);
//         if (amount != 0) {
//             uint256 maxAmount = type(uint256).max;
//             if (regime == Regime.Power) {
//                 if (isAPE) {
//                     // Keep at least 1 ETH in the apes reserve to make sure gain comptuations are preturbed by small numbers numeric approximation
//                     // Do not burn too much TEA that it changes to Saturation
//                     uint256 reserveMin = 10 ** 18;

//                     if (reserves.reserveApes >= reserveMin) {
//                         uint256 maxCollateralAmount = reserves.reserveApes - reserveMin;
//                         maxAmount = FullMath.mulDiv(supplyAPE, maxCollateralAmount, reserves.reserveApes);
//                     }
//                 } else {
//                     // Do not burn too much TEA that it changes to Saturation
//                     uint256 reserveMin = vaultParameters.leverageTier >= 0
//                         ? uint256(reserves.reserveApes) << uint8(vaultParameters.leverageTier)
//                         : reserves.reserveApes >> uint8(-vaultParameters.leverageTier);

//                     if (reserves.reserveLPers < reserveMin) revert("Saturation zone");
//                     uint256 maxCollateralAmount = reserves.reserveLPers - reserveMin;

//                     maxAmount = FullMath.mulDiv(supplyTEA, maxCollateralAmount, reserves.reserveLPers);
//                 }
//             } else if (regime == Regime.Saturation) {
//                 if (!isAPE) {
//                     // Keep at least 1 ETH in the LPers reserve
//                     uint256 reserveMin = 10 ** 18;

//                     if (reserves.reserveLPers >= reserveMin) {
//                         uint256 maxCollateralAmount = reserves.reserveLPers - reserveMin;
//                         maxAmount = FullMath.mulDiv(supplyTEA, maxCollateralAmount, reserves.reserveLPers);
//                     }
//                 } else {
//                     // Do not burn too much APE that it changes to Power, sufficient condition
//                     uint256 reserveMin = vaultParameters.leverageTier < 0
//                         ? uint256(reserves.reserveLPers) << uint8(-vaultParameters.leverageTier)
//                         : reserves.reserveLPers >> uint8(vaultParameters.leverageTier);

//                     if (reserves.reserveApes < reserveMin) revert("Saturation zone");

//                     // Sufficient condition to change to Power
//                     uint256 maxCollateralAmount = vaultParameters.leverageTier < 0
//                         ? (reserves.reserveApes - reserveMin) / (1 + 2 ** uint8(-vaultParameters.leverageTier))
//                         : ((reserves.reserveApes - reserveMin) << uint8(vaultParameters.leverageTier)) /
//                             (1 + 2 ** uint8(vaultParameters.leverageTier));

//                     maxAmount = FullMath.mulDiv(supplyAPE, maxCollateralAmount, reserves.reserveApes);
//                 }
//             }
//             amount = _bound(amount, 0, maxAmount);

//             if (amount != 0) {
//                 // Sufficient condition to not underflow collateralState.total collateral
//                 uint256 collateralOutApprox = isAPE
//                     ? FullMath.mulDiv(reserves.reserveApes, amount, supplyAPE)
//                     : FullMath.mulDiv(reserves.reserveLPers, amount, supplyTEA);

//                 if (reserves.reserveApes + reserves.reserveLPers - collateralOutApprox >= 1e6) {
//                     // Burn
//                     vm.startPrank(user);
//                     console.log("Burning", amount, isAPE ? "of APE" : "of TEA ");
//                     console.log("Reserve LPers", reserves.reserveLPers, ", Reserve Apes", reserves.reserveApes);
//                     _checkRegime();
//                     inputOutput.amountCollateral = vault.burn(isAPE, vaultParameters, amount);

//                     // Unwrap ETH
//                     _WETH.withdraw(inputOutput.amountCollateral);
//                     vm.stopPrank();
//                 }
//             }
//         }
//     }

//     /////////////////////////////////////////////////////////
//     ///////////////////// PRIVATE FUNCTIONS /////////////////

//     function _idToAddr(uint256 userId) private pure returns (address) {
//         userId = _bound(userId, 1, 3);
//         return vm.addr(userId);
//     }

//     function idToVault(uint48 vaultId) public returns (uint256) {
//         vaultId = uint48(_bound(vaultId, 1, 2));
//         vaultParameters = vault.paramsById(vaultId);
//         ape = AddressClone.getAddress(address(vault), vaultId);
//         return vaultId;
//     }

//     function _checkRegime() private view {
//         if (regime == Regime.Any) return;

//         if (
//             regime == Regime.Power &&
//             (
//                 vaultParameters.leverageTier >= 0
//                     ? reserves.reserveLPers < uint256(reserves.reserveApes) << uint8(vaultParameters.leverageTier)
//                     : reserves.reserveApes > uint256(reserves.reserveLPers) << uint8(vaultParameters.leverageTier)
//             )
//         ) {
//             revert("Saturation");
//         }

//         if (
//             regime == Regime.Saturation &&
//             (
//                 vaultParameters.leverageTier >= 0
//                     ? reserves.reserveLPers > uint256(reserves.reserveApes) << uint8(vaultParameters.leverageTier)
//                     : reserves.reserveApes < uint256(reserves.reserveLPers) << uint8(vaultParameters.leverageTier)
//             )
//         ) {
//             revert("Power zone");
//         }
//     }

//     function _invariantTotalCollateral() private view {
//         uint256 totalReserves = vault.totalReserves(address(_WETH));
//         assertLe(totalReserves, _WETH.balanceOf(address(vault)), "Total collateral is wrong");

//         SirStructs.Reserves memory reserves1 = vault.getReserves(vaultParameters1);
//         SirStructs.Reserves memory reserves2 = vault.getReserves(vaultParameters2);
//         assertEq(
//             reserves1.reserveApes + reserves1.reserveLPers + reserves2.reserveApes + reserves2.reserveLPers,
//             totalReserves,
//             "Total collateral minus fees is wrong"
//         );
//     }

//     function _invariantPowerZone() private view {
//         if (supplyAPEOld == 0) return;

//         // Compute theoretical leveraged gain
//         bytes16 gainIdeal = priceTick.tickToFP().div(priceTickOld.tickToFP()).pow(
//             ABDKMathQuad.fromUInt(2 ** uint8(vaultParameters.leverageTier))
//         );

//         // Compute actual leveraged gain
//         bytes16 gainActual = ABDKMathQuad
//             .fromUInt(reserves.reserveApes)
//             .div(ABDKMathQuad.fromUInt(reservesOld.reserveApes))
//             .mul(ABDKMathQuad.fromUInt(supplyAPEOld))
//             .div(ABDKMathQuad.fromUInt(supplyAPE));

//         // vm.writeLine(
//         //     "./gains.log",
//         //     string.concat(
//         //         "Block number: ",
//         //         vm.toString(blockNumber),
//         //         ", Ideal leveraged gain: ",
//         //         vm.toString(gainIdeal.mul(ABDKMathQuad.fromUInt(1e20)).toUInt()),
//         //         ", Actual gain: ",
//         //         vm.toString(gainActual.mul(ABDKMathQuad.fromUInt(1e20)).toUInt())
//         //     )
//         // );

//         bytes16 relErr = ABDKMathQuad.fromUInt(iterations).div(ABDKMathQuad.fromInt(-1e19));
//         console.log(
//             gainActual.mul(ABDKMathQuad.fromUInt(1e20)).toUInt(),
//             gainIdeal.mul(ABDKMathQuad.fromUInt(1e20)).toUInt()
//         );
//         assertGe(
//             gainActual.div(gainIdeal).sub(ABDKMathQuad.fromUInt(1)).cmp(relErr),
//             0,
//             "Actual gain is smaller than the ideal gain"
//         );

//         // bytes16 relErr = ABDKMathQuad.fromUInt(1).div(ABDKMathQuad.fromUInt(1e15));
//         relErr = ABDKMathQuad.fromUInt(iterations).div(ABDKMathQuad.fromUInt(smallErrorTolerance));
//         assertLe(
//             gainActual.div(gainIdeal).sub(ABDKMathQuad.fromUInt(1)).cmp(relErr),
//             0,
//             "Difference between ideal and actual gain is too large"
//         );
//     }

//     function _invariantSaturationZone() private view {
//         if (supplyAPEOld == 0) return;

//         // Compute theoretical margin gain
//         bytes16 one = ABDKMathQuad.fromUInt(1);

//         bytes16 gainIdeal = one
//             .sub(priceTickOld.tickToFP().div(priceTick.tickToFP()))
//             .mul(ABDKMathQuad.fromUInt(reservesOld.reserveLPers))
//             .div(ABDKMathQuad.fromUInt(reservesOld.reserveApes))
//             .add(one);

//         // Compute actual margin gain
//         bytes16 gainActual = ABDKMathQuad
//             .fromUInt(reserves.reserveApes)
//             .div(ABDKMathQuad.fromUInt(reservesOld.reserveApes))
//             .mul(ABDKMathQuad.fromUInt(supplyAPEOld))
//             .div(ABDKMathQuad.fromUInt(supplyAPE));

//         // vm.writeLine(
//         //     "./gains.log",
//         //     string.concat(
//         //         "Block number: ",
//         //         vm.toString(blockNumber),
//         //         ", Ideal gain: ",
//         //         vm.toString(gainIdeal.mul(ABDKMathQuad.fromUInt(1e20)).toUInt()),
//         //         ", Actual gain: ",
//         //         vm.toString(gainActual.mul(ABDKMathQuad.fromUInt(1e20)).toUInt())
//         //     )
//         // );

//         bytes16 relErr = one.div(ABDKMathQuad.fromUInt(smallErrorTolerance));
//         assertLe(
//             one
//                 .sub(gainActual.cmp(gainIdeal) < 0 ? gainActual.div(gainIdeal) : gainActual.div(gainIdeal))
//                 .div(relErr)
//                 .toUInt(),
//             1,
//             "Difference between ideal and actual gain is too large"
//         );
//     }
// }

// contract VaultInvariantTest is Test, RegimeEnum {
//     uint256 constant BLOCK_NUMBER_START = 18128302;
//     IWETH9 private constant _WETH = IWETH9(Addresses.ADDR_WETH);

//     VaultHandler public vaultHandler;
//     Vault public vault;

//     constructor() {
//         vm.createSelectFork("mainnet", BLOCK_NUMBER_START);
//     }

//     function setUp() public {
//         // Deploy the vault handler
//         vaultHandler = new VaultHandler(BLOCK_NUMBER_START, Regime.Any);
//         targetContract(address(vaultHandler));

//         address apeImplementation = vaultHandler.apeImplementation();

//         vaultHandler.idToVault(1);
//         address ape1 = vaultHandler.ape();
//         vaultHandler.idToVault(2);
//         address ape2 = vaultHandler.ape();

//         bytes4[] memory selectors = new bytes4[](2);
//         selectors[0] = vaultHandler.mint.selector;
//         selectors[1] = vaultHandler.burn.selector;
//         targetSelector(FuzzSelector({addr: address(vaultHandler), selectors: selectors}));

//         vault = vaultHandler.vault();
//         vm.makePersistent(address(Addresses.ADDR_WETH));
//         vm.makePersistent(address(vaultHandler));
//         vm.makePersistent(address(vault));
//         vm.makePersistent(address(vaultHandler.oracle()));
//         vm.makePersistent(ape1);
//         vm.makePersistent(ape2);
//         vm.makePersistent(apeImplementation);
//     }

//     /// forge-config: default.invariant.runs = 1
//     /// forge-config: default.invariant.depth = 10
//     function invariant_totalCollateral() public view {
//         uint256 totalReserves = vault.totalReserves(address(_WETH));
//         assertLe(totalReserves, _WETH.balanceOf(address(vault)), "Total collateral is wrong");
//     }
// }

// contract PowerZoneInvariantTest is Test, RegimeEnum {
//     uint256 constant BLOCK_NUMBER_START = 15210000; // July 25, 2022
//     IWETH9 private constant _WETH = IWETH9(Addresses.ADDR_WETH);

//     VaultHandler public vaultHandler;
//     Vault public vault;

//     constructor() {
//         vm.createSelectFork("mainnet", BLOCK_NUMBER_START);
//     }

//     function setUp() public {
//         // vm.writeFile("./gains.log", "");

//         // Deploy the vault handler
//         vaultHandler = new VaultHandler(BLOCK_NUMBER_START, Regime.Power);
//         targetContract(address(vaultHandler));

//         address apeImplementation = vaultHandler.apeImplementation();

//         vaultHandler.idToVault(1);
//         address ape = vaultHandler.ape();

//         bytes4[] memory selectors = new bytes4[](2);
//         selectors[0] = vaultHandler.mint.selector;
//         selectors[1] = vaultHandler.burn.selector;
//         targetSelector(FuzzSelector({addr: address(vaultHandler), selectors: selectors}));

//         vault = vaultHandler.vault();
//         Oracle oracle = vaultHandler.oracle();
//         vm.makePersistent(address(Addresses.ADDR_WETH));
//         vm.makePersistent(address(vaultHandler));
//         vm.makePersistent(address(vault));
//         vm.makePersistent(address(oracle));
//         vm.makePersistent(ape);
//         vm.makePersistent(apeImplementation);

//         // Mint 8 ETH worth of TEA
//         vaultHandler.mint(
//             false,
//             VaultHandler.InputOutput({advanceBlock: false, vaultId: 1, userId: 1, amountCollateral: 8 * (10 ** 18)})
//         );

//         // Mint 2 ETH worth of APE
//         vaultHandler.mint(
//             true,
//             VaultHandler.InputOutput({advanceBlock: false, vaultId: 1, userId: 2, amountCollateral: 2 * (10 ** 18)})
//         );
//     }

//     /// forge-config: default.invariant.runs = 1
//     /// forge-config: default.invariant.depth = 10
//     function invariant_dummy() public view {
//         uint256 totalReserves = vault.totalReserves(address(_WETH));
//         assertLe(totalReserves, _WETH.balanceOf(address(vault)), "Total collateral is wrong");

//         (uint144 reserveApes, uint144 reserveLPers, ) = vaultHandler.reserves();
//         assertEq(reserveApes + reserveLPers, totalReserves, "Total collateral minus fees is wrong");
//     }
// }

// contract SaturationInvariantTest is Test, RegimeEnum {
//     uint256 constant BLOCK_NUMBER_START = 15210000; // July 25, 2022
//     IWETH9 private constant _WETH = IWETH9(Addresses.ADDR_WETH);

//     VaultHandler public vaultHandler;
//     Vault public vault;

//     constructor() {
//         vm.createSelectFork("mainnet", BLOCK_NUMBER_START);
//     }

//     function setUp() public {
//         // vm.writeFile("./gains.log", "");

//         // Deploy the vault handler
//         vaultHandler = new VaultHandler(BLOCK_NUMBER_START, Regime.Saturation);
//         targetContract(address(vaultHandler));

//         address apeImplementation = vaultHandler.apeImplementation();

//         vaultHandler.idToVault(1);
//         address ape = vaultHandler.ape();

//         bytes4[] memory selectors = new bytes4[](2);
//         selectors[0] = vaultHandler.mint.selector;
//         selectors[1] = vaultHandler.burn.selector;
//         targetSelector(FuzzSelector({addr: address(vaultHandler), selectors: selectors}));

//         vault = vaultHandler.vault();
//         Oracle oracle = vaultHandler.oracle();
//         vm.makePersistent(address(Addresses.ADDR_WETH));
//         vm.makePersistent(address(vaultHandler));
//         vm.makePersistent(address(vault));
//         vm.makePersistent(address(oracle));
//         vm.makePersistent(ape);
//         vm.makePersistent(apeImplementation);

//         // Mint 4 ETH worth of APE (Fees will also mint 2 ETH approx of TEA)
//         vaultHandler.mint(
//             true,
//             VaultHandler.InputOutput({advanceBlock: false, vaultId: 1, userId: 2, amountCollateral: 4e18})
//         );
//     }

//     /// forge-config: default.invariant.runs = 3
//     /// forge-config: default.invariant.depth = 10
//     function invariant_dummy() public view {
//         uint256 totalReserves = vault.totalReserves(address(_WETH));
//         // console.log(totalReserves, _WETH.balanceOf(address(vault)));
//         assertLe(totalReserves, _WETH.balanceOf(address(vault)), "Total collateral is wrong");

//         (uint144 reserveApes, uint144 reserveLPers, ) = vaultHandler.reserves();
//         assertEq(reserveApes + reserveLPers, totalReserves, "Total collateral minus fees is wrong");
//     }
// }

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
