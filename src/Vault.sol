// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {VaultExternal} from "./libraries/VaultExternal.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {TickMathPrecision} from "./libraries/TickMathPrecision.sol";
import {VaultStructs} from "./libraries/VaultStructs.sol";
import {VaultEvents} from "./interfaces/VaultEvents.sol";

// Contracts
import {APE} from "./APE.sol";
import {Oracle} from "./Oracle.sol";
import {TEA} from "./TEA.sol";

import "forge-std/console.sol";

contract Vault is TEA, VaultEvents {
    error VaultAlreadyInitialized();
    error VaultDoesNotExist();
    error LeverageTierOutOfRange();

    Oracle private immutable _ORACLE;

    mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => VaultStructs.State)))
        public state; // Do not use vaultId 0

    // Used to pass parameters to the APE token constructor
    VaultStructs.TokenParameters private _transientTokenParameters;

    constructor(address systemControl, address sir, address oracle) SystemState(systemControl, sir) {
        // Price _ORACLE
        _ORACLE = Oracle(oracle);

        // Push empty parameters to avoid vaultId 0
        paramsById.push(VaultStructs.Parameters(address(0), address(0), 0));
    }

    /**
        Initialization is always necessary because we must deploy APE contracts, and possibly initialize the Oracle.
        If I require initialization, the vaultId can be chosen sequentially,
        and stored in the state by squeezing out some bytes from the other state variables.
        Potentially we can have custom list of salts to allow for 7ea and a9e addresses.
     */
    function initialize(address debtToken, address collateralToken, int8 leverageTier) external {
        if (leverageTier > 2 || leverageTier < -3) revert LeverageTierOutOfRange();

        /**
         * 1. This will initialize the _ORACLE for this pair of tokens if it has not been initialized before.
         * 2. It also will revert if there are no pools with liquidity, which implicitly solves the case where the user
         *    tries to instantiate an invalid pair of tokens like address(0)
         */
        _ORACLE.initialize(debtToken, collateralToken);

        // Check the vault has not been initialized previously
        VaultStructs.State storage state_ = state[debtToken][collateralToken][leverageTier];
        if (state_.vaultId != 0) revert VaultAlreadyInitialized();

        // Deploy APE token, and initialize it
        uint256 vaultId = VaultExternal.deployAPE(
            paramsById,
            _transientTokenParameters,
            debtToken,
            collateralToken,
            leverageTier
        );

        // Save vaultId
        state_.vaultId = uint40(vaultId);

        emit VaultInitialized(debtToken, collateralToken, leverageTier, vaultId);
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
    ) external returns (uint256) {
        unchecked {
            VaultStructs.SystemParameters memory systemParams_ = systemParams_;
            require(!systemParams_.emergencyStop);

            // Until SIR is running, only LPers are allowed to mint (deposit collateral)
            if (isAPE) require(systemParams_.tsIssuanceStart > 0);

            // Get the state
            VaultStructs.State memory state_ = _getState(debtToken, collateralToken, leverageTier);

            // Compute reserves from state
            (VaultStructs.Reserves memory reserves, APE ape) = getReserves(isAPE, state_, leverageTier);

            /** COMPUTE AMOUNTS
                collateralIn  - The amount of collateral that has been sent to the contract
                collateralFee - The amount of collateral paid in fees
                amount        - The amount of APE/TEA minted for the user
                feeToPOL      - The amount of fees (collateral) diverged to protocol owned liquidity (POL)
                treasuryInc      - The amount of fees (collateral) diverged to the Treasury
                amountPOL     - The amount of TEA minted to protocol owned liquidity (POL)
            */

            // Get deposited collateral
            uint152 collateralIn = _getCollateralDeposited(state_, collateralToken);

            // Ensures we can do unchecked math for the entire function.
            uint256 temp = collateralIn + state_.totalReserves + state_.treasury;
            require(uint152(temp) == temp); // Sufficient condition to avoid overflow in the remaining operations.

            //////////////////////////////////////
            VaultStructs.SystemParameters memory systemParams_ = systemParams;
            VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_ = _vaultsIssuanceParams[state_.vaultId];
            uint152 treasuryInc;
            uint152 lpReserveInc;
            uint152 apesReserveInc;
            if (isAPE) {
                // Mint APE for user
                uint152 collateralPOL;
                (treasuryInc, collateralPOL, lpReserveInc, apesReserveInc) = ape.mint(
                    msg.sender,
                    systemParams.baseFee,
                    vaultIssuanceParams_.tax,
                    collateralIn,
                    reserves.apesReserve
                );

                // Mint TEA for POL
                mint(
                    address(this),
                    state_.vaultId,
                    systemParams_,
                    vaultIssuanceParams_,
                    collateralPOL,
                    reserves.lpReserve
                );
            } else {
                // Mint TEA for user and POL
                (treasuryInc, lpReserveInc) = mint(
                    msg.sender,
                    state_.vaultId,
                    systemParams_,
                    vaultIssuanceParams_,
                    collateralIn,
                    reserves.lpReserve
                );
            }

            // Update the reserves
            reserves.treasury += treasuryInc;
            reserves.lpReserve += lpReserveInc;
            if (isAPE) reserves.apesReserve += apesReserveInc;

            // Update state from new reserves
            VaultExternal.updateState(state_, reserves, leverageTier);

            // Store new state reserves
            state[debtToken][collateralToken][leverageTier] = state_;

            return amount;
        }
    }

    /** @notice Function for burning APE or TEA
     */
    function burn(
        bool isAPE,
        address debtToken,
        address collateralToken,
        int8 leverageTier,
        uint256 amountToken
    ) external returns (uint152) {
        // Get the state
        VaultStructs.State memory state_ = _getState(debtToken, collateralToken, leverageTier);

        // Compute reserves from state
        VaultStructs.Reserves memory reserves = _getReserves(state_, leverageTier);

        // Compute reserves from state
        (VaultStructs.Reserves memory reserves, APE ape) = getReserves(isAPE, state_, leverageTier);

        /** COMPUTE AMOUNTS
                collateralOut - The amount of collateral that is removed from the reserve
                collateralWidthdrawn - The amount of collateral that is actually withdrawn by the user
                collateralFee - The amount of collateral paid in fees
                feeToPOL      - The amount of fees (collateral) diverged to protocol owned liquidity (POL)
                treasuryInc      - The amount of fees (collateral) diverged to the Treasury
                amountPOL     - The amount of TEA minted to protocol owned liquidity (POL)
            */

        // Get collateralOut
        uint152 collateralOut = uint152(FullMath.mulDiv(syntheticTokenReserve, amountToken, syntheticTokenSupply));

        // Substract fee
        if (isAPE)
            (uint152 collateralWidthdrawn, uint152 collateralFee) = Fees.hiddenFeeAPE(
                systemParams_.baseFee,
                collateralOut,
                leverageTier
            );
        else (collateralWidthdrawn, collateralFee) = Fees.hiddenFeeTEA(systemParams_.lpFee, collateralOut);

        // Compute amount TEA to mint as POL (max 10% of collateralFee)
        uint152 feeToPOL = collateralFee / 10;
        uint256 amountPOL = reserves.lpReserve == 0
            ? feeToPOL
            : FullMath.mulDiv(syntheticTokenSupply, feeToPOL, reserves.lpReserve);

        // At most 10% of the collected fees go to the Treasury
        uint152 treasuryInc;
        unchecked {
            treasuryInc = uint152((collateralFee * _vaultsIssuanceParams[state_.vaultId].tax) / (10 * type(uint8).max)); // Cannot ovrFlw cuz collateralFee is uint152 and tax is uint8
        }

        /** BURNING AND MINTING
            1. Burn APE or TEA from the user
            2. Mint TEA to protocol owned liquidity (POL)
         */

        // Burn APE/TEA
        if (isAPE) ape.burn(msg.sender, amountToken);
        else burn(msg.sender, state_.vaultId, amountToken);

        // Mint protocol-owned liquidity if necessary
        mint(address(this), state_.vaultId, amountPOL);

        /** UPDATE THE RESERVES
            1. Treasury collects up to 10% of the fees
            2. The LPers collect the rest of the fees
            3. The reserve of the synthetic token is reduced
         */

        reserves.treasury += treasuryInc;
        reserves.lpReserve += collateralFee - treasuryInc;
        /** Cannot UF because
            (1) burn() of APE/TEA ensures amountToken ≤ syntheticTokenSupply => collateralOut ≤ syntheticTokenReserve
            (2) isAPE==true => syntheticTokenReserve == apesReserve & isAPE==false => syntheticTokenReserve == lpReserve
         */
        unchecked {
            if (isAPE) reserves.apesReserve -= collateralOut;
            else reserves.lpReserve -= collateralOut;
        }

        /** REMAINING TASKS
            1. Update state from new reserves
            2. Store new state
            3. Send collateral
         */

        // Update state from new reserves
        VaultExternal.updateState(state_, reserves, leverageTier);

        // Store new state
        state[debtToken][collateralToken][leverageTier] = state_;

        // Send collateral
        TransferHelper.safeTransfer(collateralToken, msg.sender, amountToken);

        return collateralWidthdrawn;
    }

    /*/////////////////////f//////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * Connections Between State Variables (R,priceSat) & Reserves (A,L)
     *     where R = Total reserve, A = Apes reserve, L = LP reserve
     *     (R,priceSat) ⇔ (A,L)
     *     (R,  ∞  ) ⇔ (0,L)
     *     (R,  0  ) ⇔ (A,0)
     */

    // getReserves CAN GO TO THE PERIPHERY!!
    // function getReserves(
    //     address debtToken,
    //     address collateralToken,
    //     int8 leverageTier
    // ) external view returns (VaultStructs.Reserves memory) {
    //     // Get the state and check it actually exists
    //     VaultStructs.State memory state_ = state[debtToken][collateralToken][leverageTier];
    //     if (state_.vaultId == 0) revert VaultDoesNotExist();

    //     // Retrieve price from _ORACLE if not retrieved in a previous tx in this block
    //     if (state_.timeStampPrice != block.timestamp) {
    //         state_.tickPriceX42 = _ORACLE.getPrice(collateralToken, debtToken);
    //         state_.timeStampPrice = uint40(block.timestamp);
    //     }

    //     return _getReserves(state_, leverageTier);
    // }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

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

    // OPTIMIZE WITH THIS?? https://github.com/Uniswap/v3-core/blob/d8b1c635c275d2a9450bd6a78f3fa2484fef73eb/contracts/UniswapV3Pool.sol#L140
    function _getCollateralDeposited(
        VaultStructs.State memory state_,
        address collateralToken
    ) private view returns (uint152) {
        // Get deposited collateral
        unchecked {
            uint256 balance = IERC20(collateralToken).balanceOf(address(this)) - state_.treasury - state_.totalReserves;

            require(uint152(balance) == balance);
            return uint152(balance);
        }
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function widhtdrawTreasuryFees(uint40 vaultId, address to) external onlySystemControl {
        VaultStructs.Parameters memory params = paramsById[vaultId];

        uint256 treasury = state[params.debtToken][params.collateralToken][params.leverageTier].treasury;
        state[params.debtToken][params.collateralToken][params.leverageTier].treasury = 0; // Null balance to avoid reentrancy attack

        TransferHelper.safeTransfer(params.collateralToken, to, treasury);

        // ALSO TRANSFER EARNT SIR DUE TO POL!!
    }
}
