// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {ISIR} from "./interfaces/ISIR.sol";
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {VaultExternal} from "./libraries/VaultExternal.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {TickMathPrecision} from "./libraries/TickMathPrecision.sol";
import {VaultStructs} from "./libraries/VaultStructs.sol";

// Contracts
import {APE} from "./APE.sol";
import {Oracle} from "./Oracle.sol";
import {TEA} from "./TEA.sol";

import "forge-std/console.sol";

contract Vault is TEA {
    Oracle private immutable _ORACLE;

    mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => VaultStructs.VaultState)))
        public vaultStates; // Do not use vaultId 0

    // Global parameters for each type of collateral that aggregates amounts from all vaults
    mapping(address collateral => VaultStructs.TokenState) public tokenStates;

    // Used to pass parameters to the APE token constructor
    VaultStructs.TokenParameters private _transientTokenParameters;

    constructor(address systemControl, address sir, address oracle) TEA(systemControl, sir) {
        // Price _ORACLE
        _ORACLE = Oracle(oracle);

        // Push empty parameters to avoid vaultId 0
        paramsById.push(VaultStructs.VaultParameters(address(0), address(0), 0));
    }

    /** @notice Initialization is always necessary because we must deploy APE contracts, and possibly initialize the Oracle.
     */
    function initialize(VaultStructs.VaultParameters calldata vaultParams) external {
        VaultExternal.deployAPE(
            _ORACLE,
            vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier],
            paramsById,
            _transientTokenParameters,
            vaultParams
        );
    }

    function latestTokenParams()
        external
        view
        returns (VaultStructs.TokenParameters memory, VaultStructs.VaultParameters memory)
    {
        return (_transientTokenParameters, paramsById[paramsById.length - 1]);
    }

    /*////////////////////////////////////////////////////////////////
                            MINT/BURN FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @notice Function for minting APE or TEA
     */
    function mint(bool isAPE, VaultStructs.VaultParameters calldata vaultParams) external returns (uint256 amount) {
        unchecked {
            VaultStructs.SystemParameters memory systemParams_ = systemParams;
            require(!systemParams_.mintingStopped);

            // Get reserves
            (
                VaultStructs.TokenState memory tokenState,
                VaultStructs.VaultState memory vaultState,
                VaultStructs.Reserves memory reserves,
                APE ape,
                uint144 collateralDeposited
            ) = VaultExternal.getReserves(true, isAPE, tokenStates, vaultStates, _ORACLE, vaultParams);

            VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams[vaultState.vaultId];
            uint256 collectedFee;
            if (isAPE) {
                // Mint APE
                uint144 polFee;
                (reserves, collectedFee, polFee, amount) = ape.mint(
                    msg.sender,
                    systemParams_.baseFee,
                    vaultIssuanceParams_.tax,
                    reserves,
                    collateralDeposited
                );

                // Mint TEA for protocol owned liquidity (POL)
                mint(
                    vaultParams.collateralToken,
                    address(this),
                    vaultState.vaultId,
                    systemParams_,
                    vaultIssuanceParams_,
                    reserves,
                    polFee
                );
            } else {
                // Mint TEA for user and protocol owned liquidity (POL)
                (amount, collectedFee) = mint(
                    vaultParams.collateralToken,
                    msg.sender,
                    vaultState.vaultId,
                    systemParams_,
                    vaultIssuanceParams_,
                    reserves,
                    collateralDeposited
                );
            }

            // Update vaultStates from new reserves
            _updateVaultState(vaultState, reserves, vaultParams);

            // Update collateral params
            _updateTokenState(true, tokenState, collectedFee, vaultParams.collateralToken, collateralDeposited);
        }
    }

    /** @notice Function for burning APE or TEA
     */
    function burn(
        bool isAPE,
        VaultStructs.VaultParameters calldata vaultParams,
        uint256 amount
    ) external returns (uint144 collateralWidthdrawn) {
        VaultStructs.SystemParameters memory systemParams_ = systemParams;

        // Get reserves
        (
            VaultStructs.TokenState memory tokenState,
            VaultStructs.VaultState memory vaultState,
            VaultStructs.Reserves memory reserves,
            APE ape,

        ) = VaultExternal.getReserves(false, isAPE, tokenStates, vaultStates, _ORACLE, vaultParams);

        VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams[vaultState.vaultId];
        uint256 collectedFee;
        if (isAPE) {
            // Burn APE
            uint144 polFee;
            (reserves, collectedFee, polFee, collateralWidthdrawn) = ape.burn(
                msg.sender,
                systemParams_.baseFee,
                vaultIssuanceParams_.tax,
                reserves,
                amount
            );

            // Mint TEA for protocol owned liquidity (POL)
            mint(
                vaultParams.collateralToken,
                address(this),
                vaultState.vaultId,
                systemParams_,
                vaultIssuanceParams_,
                reserves,
                polFee
            );
        } else {
            // Burn TEA for user and mint TEA for protocol owned liquidity (POL)
            (collateralWidthdrawn, collectedFee) = burn(
                vaultParams.collateralToken,
                msg.sender,
                vaultState.vaultId,
                systemParams_,
                vaultIssuanceParams_,
                reserves,
                amount
            );
        }

        // Update vaultStates from new reserves
        _updateVaultState(vaultState, reserves, vaultParams);

        // Update collateral params
        _updateTokenState(false, tokenState, collectedFee, vaultParams.collateralToken, collateralWidthdrawn);

        // Send collateral
        TransferHelper.safeTransfer(vaultParams.collateralToken, msg.sender, collateralWidthdrawn);
    }

    /*////////////////////////////////////////////////////////////////
                            READ ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    // TODO: Add simulateMint and simulateBurn functions to the periphery

    /** @dev Kick it to periphery if more space is needed
     */
    function getReserves(
        VaultStructs.VaultParameters calldata vaultParams
    ) external view returns (VaultStructs.Reserves memory) {
        return VaultExternal.getReservesReadOnly(vaultStates, _ORACLE, vaultParams);
    }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * Connections Between VaultState Variables (R,priceSat) & Reserves (A,L)
     *     where R = Total reserve, A = Apes reserve, L = LP reserve
     *     (R,priceSat) ⇔ (A,L)
     *     (R,  ∞  ) ⇔ (0,L)
     *     (R,  0  ) ⇔ (A,0)
     */
    function _updateVaultState(
        VaultStructs.VaultState memory vaultState,
        VaultStructs.Reserves memory reserves,
        VaultStructs.VaultParameters calldata vaultParams
    ) private {
        unchecked {
            vaultState.reserve = reserves.reserveApes + reserves.reserveLPers;

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
                    int256 temptickPriceSatX42 = reserves.tickPriceX42 +
                        (
                            vaultParams.leverageTier >= 0
                                ? tickRatioX42 >> absLeverageTier
                                : tickRatioX42 << absLeverageTier
                        );

                    // Check if overflow
                    if (temptickPriceSatX42 > type(int64).max) vaultState.tickPriceSatX42 = type(int64).max;
                    else vaultState.tickPriceSatX42 = int64(temptickPriceSatX42);
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
                    int256 temptickPriceSatX42 = reserves.tickPriceX42 - tickRatioX42;

                    // Check if underflow
                    if (temptickPriceSatX42 < type(int64).min) vaultState.tickPriceSatX42 = type(int64).min;
                    else vaultState.tickPriceSatX42 = int64(temptickPriceSatX42);
                }
            }

            vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier] = vaultState;
        }
    }

    function _updateTokenState(
        bool isMint,
        VaultStructs.TokenState memory tokenState,
        uint256 collectedFee,
        address collateralToken,
        uint144 collateralDepositedOrWithdrawn
    ) private {
        uint256 collectedFees_ = tokenState.collectedFees + collectedFee;
        require(collectedFees_ <= type(uint112).max); // Ensure it fits in a uint112
        tokenState = VaultStructs.TokenState({
            collectedFees: uint112(collectedFees_),
            total: isMint
                ? tokenState.total + collateralDepositedOrWithdrawn
                : tokenState.total - collateralDepositedOrWithdrawn
        });

        tokenStates[collateralToken] = tokenState;
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function withdrawFees(address token) external {
        require(msg.sender == sir);

        VaultStructs.TokenState memory tokenState = tokenStates[token];
        uint112 collectedFees = tokenState.collectedFees;
        if (collectedFees == 0) return;

        tokenStates[token] = VaultStructs.TokenState({collectedFees: 0, total: tokenState.total - collectedFees});

        TransferHelper.safeTransfer(token, msg.sender, collectedFees);
    }

    /** @notice This function is only intended to be called as last recourse to save the system from a critical bug or hack
        @notice during the beta period. To execute it, the system must be in Shutdown status
        @notice which can only be activate after SHUTDOWN_WITHDRAWAL_DELAY since Emergency status was activated.
     */
    function withdrawToSaveSystem(
        address[] calldata tokens,
        address to
    ) external onlySystemControl returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);
        bool success;
        bytes memory data;
        for (uint256 i = 0; i < tokens.length; i++) {
            // We use the low-level call because we want to continue with the next token if balanceOf reverts
            (success, data) = tokens[i].call(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
            if (success && data.length == 32) {
                amounts[i] = abi.decode(data, (uint256));
                if (amounts[i] > 0) {
                    (success, data) = tokens[i].call(abi.encodeWithSelector(IERC20.transfer.selector, to, amounts[i]));
                    // If the transfer failed, set the amount of transfered tokens back to 0
                    if (!(success && (data.length == 0 || abi.decode(data, (bool))))) {
                        amounts[i] = 0;
                    }
                }
            }
        }
    }
}
