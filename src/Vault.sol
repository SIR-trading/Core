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
    error VaultDoesNotExist();

    Oracle private immutable _ORACLE;

    mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => VaultStructs.State)))
        public states; // Do not use vaultId 0

    // Global parameters for each type of collateral that aggregates amounts from all vaults
    mapping(address collateral => VaultStructs.CollateralReserve) public collateralReserves;

    // Used to pass parameters to the APE token constructor
    VaultStructs.TokenParameters private _transientTokenParameters;

    constructor(address systemControl, address sir, address oracle) TEA(systemControl, sir) {
        // Price _ORACLE
        _ORACLE = Oracle(oracle);

        // Push empty parameters to avoid vaultId 0
        paramsById.push(VaultStructs.Parameters(address(0), address(0), 0));
    }

    /** @notice Initialization is always necessary because we must deploy APE contracts, and possibly initialize the Oracle.
     */
    function initialize(address debtToken, address collateralToken, int8 leverageTier) external {
        VaultExternal.deployAPE(
            _ORACLE,
            states[debtToken][collateralToken][leverageTier],
            paramsById,
            _transientTokenParameters,
            debtToken,
            collateralToken,
            leverageTier
        );
    }

    function latestTokenParams()
        external
        view
        returns (
            string memory name,
            string memory symbol,
            uint8 decimals,
            address debtToken,
            address collateralToken,
            int8 leverageTier
        )
    {
        name = _transientTokenParameters.name;
        symbol = _transientTokenParameters.symbol;
        decimals = _transientTokenParameters.decimals;

        VaultStructs.Parameters memory params = paramsById[paramsById.length - 1];
        debtToken = params.debtToken;
        collateralToken = params.collateralToken;
        leverageTier = params.leverageTier;
    }

    /*////////////////////////////////////////////////////////////////
                            MINT/BURN FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @notice Function for minting APE or TEA
     */
    function mint(
        bool isAPE,
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external returns (uint256 amount) {
        unchecked {
            VaultStructs.SystemParameters memory systemParams_ = systemParams;
            require(!systemParams_.mintingStopped);

            // Until SIR is running, only LPers are allowed to mint (deposit collateral)
            if (isAPE) require(systemParams_.tsIssuanceStart > 0);

            // Get state and check it actually exists
            VaultStructs.State memory state = states[debtToken][collateralToken][leverageTier];
            if (state.vaultId == 0) revert VaultDoesNotExist();

            // Copy collateral reserves data
            VaultStructs.CollateralReserve memory collateralReserve = collateralReserves[collateralToken];

            // Get deposited collateral
            uint256 balance = IERC20(collateralToken).balanceOf(address(this));
            require(balance <= type(uint144).max); // Ensure it fits in a uint144
            uint144 collateralDeposited = uint144(balance - collateralReserve.total);

            // Get price from oracle
            VaultStructs.Reserves memory reserves;
            APE ape;
            {
                int64 tickPriceX42 = _ORACLE.updateOracleState(collateralToken, debtToken);

                // Compute reserves from states
                (reserves, ape) = VaultExternal.getReserves(isAPE, state, collateralToken, leverageTier, tickPriceX42);
            }

            uint256 collectedFee;
            {
                VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams[state.vaultId];
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
                        collateralToken,
                        address(this),
                        state.vaultId,
                        systemParams_,
                        vaultIssuanceParams_,
                        reserves,
                        polFee
                    );
                } else {
                    // Mint TEA for user and protocol owned liquidity (POL)
                    (amount, collectedFee) = mint(
                        collateralToken,
                        msg.sender,
                        state.vaultId,
                        systemParams_,
                        vaultIssuanceParams_,
                        reserves,
                        collateralDeposited
                    );
                }
            }

            // Update states from new reserves
            _updateState(state, reserves, leverageTier);
            states[debtToken][collateralToken][leverageTier] = state;

            // Update collateral params
            _updateCollateralReserve(collateralReserve, collectedFee, collateralDeposited, true);
            collateralReserves[collateralToken] = collateralReserve;
        }
    }

    function _updateCollateralReserve(
        VaultStructs.CollateralReserve memory collateralReserve,
        uint256 collectedFee,
        uint144 collateralDepositedOrWithdrawn,
        bool isMint
    ) private pure {
        uint256 collectedFeeNew = collateralReserve.collectedFees + collectedFee;
        require(collectedFeeNew < type(uint112).max); // Ensure it fits in a uint112
        collateralReserve = VaultStructs.CollateralReserve({
            collectedFees: uint112(collectedFeeNew),
            total: isMint
                ? collateralReserve.total + collateralDepositedOrWithdrawn
                : collateralReserve.total - collateralDepositedOrWithdrawn
        });
    }

    /** @notice Function for burning APE or TEA
     */
    function burn(
        bool isAPE,
        address debtToken,
        address collateralToken,
        int8 leverageTier,
        uint256 amount
    ) external returns (uint144 collateralWidthdrawn) {
        // Get state and check it actually exists
        VaultStructs.State memory state = states[debtToken][collateralToken][leverageTier];
        if (state.vaultId == 0) revert VaultDoesNotExist();

        // Copy collateral reserves data
        VaultStructs.CollateralReserve memory collateralReserve = collateralReserves[collateralToken];

        // Get price from oracle
        VaultStructs.Reserves memory reserves;
        APE ape;
        {
            int64 tickPriceX42 = _ORACLE.updateOracleState(collateralToken, debtToken);

            // Compute reserves from states
            (reserves, ape) = VaultExternal.getReserves(isAPE, state, collateralToken, leverageTier, tickPriceX42);
        }

        VaultStructs.SystemParameters memory systemParams_ = systemParams;
        VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams[state.vaultId];
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
            mint(collateralToken, address(this), state.vaultId, systemParams_, vaultIssuanceParams_, reserves, polFee);
        } else {
            // Burn TEA for user and mint TEA for protocol owned liquidity (POL)
            (collateralWidthdrawn, collectedFee) = burn(
                collateralToken,
                msg.sender,
                state.vaultId,
                systemParams_,
                vaultIssuanceParams_,
                reserves,
                amount
            );
        }

        // Update states from new reserves
        _updateState(state, reserves, leverageTier);
        states[debtToken][collateralToken][leverageTier] = state;

        // Update collateral params
        _updateCollateralReserve(collateralReserve, collectedFee, collateralWidthdrawn, false);
        collateralReserves[collateralToken] = collateralReserve;

        // Send collateral
        TransferHelper.safeTransfer(collateralToken, msg.sender, collateralWidthdrawn);
    }

    /*////////////////////////////////////////////////////////////////
                            READ ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    // TODO: Add simulateMint and simulateBurn functions to the periphery

    /** @dev Kick it to periphery if more space is needed
     */
    function getReserves(
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external view returns (VaultStructs.Reserves memory reserves) {
        // Get state and check it actually exists
        VaultStructs.State memory state = states[debtToken][collateralToken][leverageTier];
        if (state.vaultId == 0) revert VaultDoesNotExist();

        // Get price from oracle
        int64 tickPriceX42 = _ORACLE.getPrice(collateralToken, debtToken);

        (reserves, ) = VaultExternal.getReserves(false, state, collateralToken, leverageTier, tickPriceX42);
    }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * Connections Between State Variables (R,priceSat) & Reserves (A,L)
     *     where R = Total reserve, A = Apes reserve, L = LP reserve
     *     (R,priceSat) ⇔ (A,L)
     *     (R,  ∞  ) ⇔ (0,L)
     *     (R,  0  ) ⇔ (A,0)
     */
    function _updateState(
        VaultStructs.State memory state,
        VaultStructs.Reserves memory reserves,
        int8 leverageTier
    ) private {
        unchecked {
            state.reserve = reserves.reserveApes + reserves.reserveLPers;

            // To ensure division by 0 does not occur when recoverying the reserves
            require(state.reserve >= 2);

            // Compute tickPriceSatX42
            if (reserves.reserveApes == 0) {
                state.tickPriceSatX42 = type(int64).max;
            } else if (reserves.reserveLPers == 0) {
                state.tickPriceSatX42 = type(int64).min;
            } else {
                /**
                 * Decide if we are in the power or saturation zone
                 * Condition for power zone: A < (l-1) L where l=1+2^leverageTier
                 */
                uint8 absLeverageTier = leverageTier >= 0 ? uint8(leverageTier) : uint8(-leverageTier);
                bool isPowerZone;
                if (leverageTier > 0) {
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
                        leverageTier >= 0 ? state.reserve : uint256(state.reserve) << absLeverageTier, // Cannot OF cuz reserve is uint144, and |leverageTier|<=3
                        (uint256(reserves.reserveApes) << absLeverageTier) + reserves.reserveApes // Cannot OF cuz reserveApes is uint144, and |leverageTier|<=3
                    );

                    // Compute saturation price
                    int256 temptickPriceSatX42 = reserves.tickPriceX42 +
                        (leverageTier >= 0 ? tickRatioX42 >> absLeverageTier : tickRatioX42 << absLeverageTier);

                    // Check if overflow
                    if (temptickPriceSatX42 > type(int64).max) state.tickPriceSatX42 = type(int64).max;
                    else state.tickPriceSatX42 = int64(temptickPriceSatX42);
                } else {
                    /**
                     * PRICE IN SATURATION ZONE
                     * priceSat = r*price*L/R
                     */
                    int256 tickRatioX42 = TickMathPrecision.getTickAtRatio(
                        leverageTier >= 0 ? uint256(state.reserve) << absLeverageTier : state.reserve,
                        (uint256(reserves.reserveLPers) << absLeverageTier) + reserves.reserveLPers
                    );

                    // Compute saturation price
                    int256 temptickPriceSatX42 = reserves.tickPriceX42 - tickRatioX42;

                    // Check if underflow
                    if (temptickPriceSatX42 < type(int64).min) state.tickPriceSatX42 = type(int64).min;
                    else state.tickPriceSatX42 = int64(temptickPriceSatX42);
                }
            }
        }
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function withdrawFees(address token) external returns (uint112 collectedFees) {
        require(msg.sender == sir);

        VaultStructs.CollateralReserve memory collateralReserve = collateralReserves[token];
        collectedFees = collateralReserve.collectedFees;
        collateralReserves[token] = VaultStructs.CollateralReserve({
            collectedFees: 0,
            total: collateralReserve.total - collectedFees
        });

        if (collectedFees > 0) TransferHelper.safeTransfer(token, msg.sender, collectedFees);
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
