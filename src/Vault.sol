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
        public state; // Do not use vaultId 0

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
            state[debtToken][collateralToken][leverageTier],
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

            // Get state
            VaultStructs.State memory state_ = _getState(debtToken, collateralToken, leverageTier);

            // Compute reserves from state
            (VaultStructs.Reserves memory reserves, APE ape, uint152 collateralDeposited) = VaultExternal.getReserves(
                true,
                isAPE,
                state_,
                collateralToken,
                leverageTier
            );

            VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams[state_.vaultId];
            if (isAPE) {
                // Mint APE
                uint152 polFee;
                (reserves, polFee, amount) = ape.mint(
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
                    state_.vaultId,
                    systemParams_,
                    vaultIssuanceParams_,
                    reserves,
                    polFee
                );
            } else {
                // Mint TEA for user and protocol owned liquidity (POL)
                amount = mint(
                    collateralToken,
                    msg.sender,
                    state_.vaultId,
                    systemParams_,
                    vaultIssuanceParams_,
                    reserves,
                    collateralDeposited
                );
            }

            // Update state from new reserves
            _updateState(state_, reserves, debtToken, collateralToken, leverageTier);
        }
    }

    /** @notice Function for burning APE or TEA
     */
    function burn(
        bool isAPE,
        address debtToken,
        address collateralToken,
        int8 leverageTier,
        uint256 amount
    ) external returns (uint152 collateralWidthdrawn) {
        // Get state
        VaultStructs.State memory state_ = _getState(debtToken, collateralToken, leverageTier);

        // Compute reserves from state
        (VaultStructs.Reserves memory reserves, APE ape, ) = VaultExternal.getReserves(
            false,
            isAPE,
            state_,
            collateralToken,
            leverageTier
        );

        VaultStructs.SystemParameters memory systemParams_ = systemParams;
        VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams[state_.vaultId];
        if (isAPE) {
            // Burn APE
            uint152 polFee;
            (reserves, polFee, collateralWidthdrawn) = ape.burn(
                msg.sender,
                systemParams_.baseFee,
                vaultIssuanceParams_.tax,
                reserves,
                amount
            );

            // Mint TEA for protocol owned liquidity (POL)
            mint(collateralToken, address(this), state_.vaultId, systemParams_, vaultIssuanceParams_, reserves, polFee);
        } else {
            // Burn TEA for user and mint TEA for protocol owned liquidity (POL)
            collateralWidthdrawn = burn(
                collateralToken,
                msg.sender,
                state_.vaultId,
                systemParams_,
                vaultIssuanceParams_,
                reserves,
                amount
            );
        }

        // Update state from new reserves
        _updateState(state_, reserves, debtToken, collateralToken, leverageTier);

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
        // Retrieve state and check it actually exists
        VaultStructs.State memory state_ = state[debtToken][collateralToken][leverageTier];
        if (state_.vaultId == 0) revert VaultDoesNotExist();

        // Retrieve price from _ORACLE if not retrieved in a previous tx in this block
        if (state_.timeStampPrice != block.timestamp) {
            state_.tickPriceX42 = _ORACLE.getPrice(collateralToken, debtToken);
            state_.timeStampPrice = uint40(block.timestamp);
        }

        (reserves, , ) = VaultExternal.getReserves(false, false, state_, collateralToken, leverageTier);
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

    function _getState(
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) private returns (VaultStructs.State memory state_) {
        // Retrieve state and check it actually exists
        state_ = state[debtToken][collateralToken][leverageTier];
        if (state_.vaultId == 0) revert VaultDoesNotExist();

        // Retrieve price from _ORACLE if not retrieved in a previous tx in this block
        if (state_.timeStampPrice != block.timestamp) {
            state_.tickPriceX42 = _ORACLE.updateOracleState(collateralToken, debtToken);
            state_.timeStampPrice = uint40(block.timestamp);
        }
    }

    function _updateState(
        VaultStructs.State memory state_,
        VaultStructs.Reserves memory reserves,
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) private {
        unchecked {
            state_.treasury = reserves.treasury;
            state_.totalReserves = reserves.apesReserve + reserves.lpReserve;

            // To ensure division by 0 does not occur when recoverying the reserves
            require(state_.totalReserves >= 2);

            // Compute tickPriceSatX42
            if (reserves.apesReserve == 0) {
                state_.tickPriceSatX42 = type(int64).max;
            } else if (reserves.lpReserve == 0) {
                state_.tickPriceSatX42 = type(int64).min;
            } else {
                /**
                 * Decide if we are in the power or saturation zone
                 * Condition for power zone: A < (l-1) L where l=1+2^leverageTier
                 */
                uint8 absLeverageTier = leverageTier >= 0 ? uint8(leverageTier) : uint8(-leverageTier);
                bool isPowerZone;
                if (leverageTier > 0) {
                    if (
                        uint256(reserves.apesReserve) << absLeverageTier < reserves.lpReserve
                    ) // Cannot OF because apesReserve is an uint152, and |leverageTier|<=3
                    {
                        isPowerZone = true;
                    } else {
                        isPowerZone = false;
                    }
                } else {
                    if (
                        reserves.apesReserve < uint256(reserves.lpReserve) << absLeverageTier
                    ) // Cannot OF because apesReserve is an uint152, and |leverageTier|<=3
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
                        leverageTier >= 0 ? state_.totalReserves : uint256(state_.totalReserves) << absLeverageTier, // Cannot OF cuz totalReserves is uint152, and |leverageTier|<=3
                        (uint256(reserves.apesReserve) << absLeverageTier) + reserves.apesReserve // Cannot OF cuz apesReserve is uint152, and |leverageTier|<=3
                    );

                    // Compute saturation price
                    int256 temptickPriceSatX42 = state_.tickPriceX42 +
                        (leverageTier >= 0 ? tickRatioX42 >> absLeverageTier : tickRatioX42 << absLeverageTier);

                    // Check if overflow
                    if (temptickPriceSatX42 > type(int64).max) state_.tickPriceSatX42 = type(int64).max;
                    else state_.tickPriceSatX42 = int64(temptickPriceSatX42);
                } else {
                    /**
                     * PRICE IN SATURATION ZONE
                     * priceSat = r*price*L/R
                     */
                    int256 tickRatioX42 = TickMathPrecision.getTickAtRatio(
                        leverageTier >= 0 ? uint256(state_.totalReserves) << absLeverageTier : state_.totalReserves,
                        (uint256(reserves.lpReserve) << absLeverageTier) + reserves.lpReserve
                    );

                    // Compute saturation price
                    int256 temptickPriceSatX42 = state_.tickPriceX42 - tickRatioX42;

                    // Check if underflow
                    if (temptickPriceSatX42 < type(int64).min) state_.tickPriceSatX42 = type(int64).min;
                    else state_.tickPriceSatX42 = int64(temptickPriceSatX42);
                }
            }

            // Store new state
            state[debtToken][collateralToken][leverageTier] = state_;
        }
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function withdrawFees(uint40 vaultId, address to) external onlySystemControl returns (address, uint256) {
        VaultStructs.Parameters memory params = paramsById[vaultId];

        uint256 treasury = state[params.debtToken][params.collateralToken][params.leverageTier].treasury;
        state[params.debtToken][params.collateralToken][params.leverageTier].treasury = 0; // Null balance to avoid reentrancy attack

        if (treasury > 0) TransferHelper.safeTransfer(params.collateralToken, to, treasury);

        return (params.collateralToken, treasury);
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
