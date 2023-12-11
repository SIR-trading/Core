// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {VaultExternal} from "./libraries/VaultExternal.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {SaltedAddress} from "./libraries/SaltedAddress.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {TickMathPrecision} from "./libraries/TickMathPrecision.sol";
import {Fees} from "./libraries/Fees.sol";
import {VaultStructs} from "./libraries/VaultStructs.sol";
import {VaultEvents} from "./interfaces/VaultEvents.sol";

// Contracts
import {APE} from "./APE.sol";
import {Oracle} from "./Oracle.sol";
import {SystemState} from "./SystemState.sol";

import "forge-std/console.sol";

contract Vault is SystemState, VaultEvents {
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
            require(!systemParams.emergencyStop);

            // Until SIR is running, only LPers are allowed to mint (deposit collateral)
            if (isAPE) require(systemParams.tsIssuanceStart > 0);

            // Get the state
            VaultStructs.State memory state_ = _getState(debtToken, collateralToken, leverageTier);

            // Compute reserves from state
            VaultStructs.Reserves memory reserves = _getReserves(state_, leverageTier);

            uint256 amount;
            // Too avoid stack too deep
            {
                /** COMPUTE PARAMETERS
                    ape                   - The token contract of APE if necessary
                    syntheticTokenReserve - Collateral reserve backing APE or TEA
                    syntheticTokenSupply  - Supply of APE or TEA
                */
                APE ape;
                uint152 syntheticTokenReserve;
                uint256 syntheticTokenSupply;
                (ape, syntheticTokenReserve, syntheticTokenSupply) = _getSupplies(isAPE, state_, reserves);

                /** COMPUTE AMOUNTS
                    collateralIn  - The amount of collateral that has been sent to the contract
                    collateralFee - The amount of collateral paid in fees
                    amount        - The amount of APE/TEA minted for the user
                    feeToPOL      - The amount of fees (collateral) diverged to protocol owned liquidity (POL)
                    feeToDAO      - The amount of fees (collateral) diverged to the DAO
                    amountPOL     - The amount of TEA minted to protocol owned liquidity (POL)
                */

                // Get deposited collateral
                uint152 collateralIn = _getCollateralDeposited(state_, collateralToken);

                // Too avoid stack too deep
                {
                    // Ensures we can do unchecked math for the entire function.
                    uint256 temp = collateralIn + state_.totalReserves + state_.daoFees;
                    require(uint152(temp) == temp); // Sufficient but not necessary condition to avoid OF in the remaining operation.
                }

                // Substract fee
                uint152 collateralFee;
                (collateralIn, collateralFee) = Fees.hiddenFee(
                    isAPE ? systemParams.baseFee : systemParams.lpFee,
                    collateralIn,
                    isAPE ? leverageTier : int8(0)
                );

                // Compute amount TEA or APE to mint for the user
                amount = syntheticTokenReserve == 0
                    ? collateralIn
                    : FullMath.mulDiv(syntheticTokenSupply, collateralIn, syntheticTokenReserve);

                // Compute amount TEA to mint as POL (max 10% of collateralFee)
                uint152 feeToPOL = collateralFee / 10;
                uint256 amountPOL = reserves.lpReserve == 0
                    ? feeToPOL
                    : FullMath.mulDiv(syntheticTokenSupply, feeToPOL, reserves.lpReserve);

                // Compute amount of collateral diverged to the DAO (max 10% of collateralFee)
                uint152 feeToDAO = uint152(
                    (collateralFee * _vaultsIssuanceParams[state_.vaultId].tax) / (10 * type(uint8).max)
                ); // Cannot OF cuz collateralFee is uint152 and tax is uint8

                /** MINTING
                    1. Mint APE or TEA for the user
                    2. Mint TEA to protocol owned liquidity (POL)
                */

                // Mint APE/TEA
                if (isAPE) ape.mint(msg.sender, amount);
                else mint(msg.sender, state_.vaultId, amount);

                // Mint protocol-owned liquidity if necessary
                mint(address(this), state_.vaultId, amountPOL);

                /** UPDATE THE RESERVES
                    1. DAO collects up to 10% of the fees
                    2. The LPers collect the rest of the fees
                    3. The reserve of the synthetic token is increased
                */
                reserves.daoFees += feeToDAO;
                reserves.lpReserve += collateralFee - feeToDAO;
                if (isAPE) reserves.apesReserve += collateralIn;
                else reserves.lpReserve += collateralIn;
            }

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

        uint152 collateralWidthdrawn;

        /** COMPUTE PARAMETERS
            ape                   - The token contract of APE if necessary
            syntheticTokenReserve - Collateral reserve backing APE or TEA
            syntheticTokenSupply  - Supply of APE or TEA
        */
        APE ape;
        uint152 collateralOut;
        uint152 collateralFee;
        uint256 amountPOL;
        // Too avoid stack too deep
        {
            uint152 syntheticTokenReserve;
            uint256 syntheticTokenSupply;
            (ape, syntheticTokenReserve, syntheticTokenSupply) = _getSupplies(isAPE, state_, reserves);

            /** COMPUTE AMOUNTS
                collateralOut - The amount of collateral that is removed from the reserve
                collateralWidthdrawn - The amount of collateral that is actually withdrawn by the user
                collateralFee - The amount of collateral paid in fees
                feeToPOL      - The amount of fees (collateral) diverged to protocol owned liquidity (POL)
                feeToDAO      - The amount of fees (collateral) diverged to the DAO
                amountPOL     - The amount of TEA minted to protocol owned liquidity (POL)
            */

            // Get collateralOut
            collateralOut = uint152(FullMath.mulDiv(syntheticTokenReserve, amountToken, syntheticTokenSupply));

            // Substract fee
            if (isAPE)
                (collateralWidthdrawn, collateralFee) = Fees.hiddenFee(
                    systemParams.baseFee,
                    collateralOut,
                    leverageTier
                );
            else (collateralWidthdrawn, collateralFee) = Fees.hiddenFee(systemParams.lpFee, collateralOut, int8(0));

            // Compute amount TEA to mint as POL (max 10% of collateralFee)
            uint152 feeToPOL = collateralFee / 10;
            amountPOL = reserves.lpReserve == 0
                ? feeToPOL
                : FullMath.mulDiv(syntheticTokenSupply, feeToPOL, reserves.lpReserve);
        }

        // At most 10% of the collected fees go to the DAO
        uint152 feeToDAO;
        unchecked {
            feeToDAO = uint152((collateralFee * _vaultsIssuanceParams[state_.vaultId].tax) / (10 * type(uint8).max)); // Cannot OF cuz collateralFee is uint152 and tax is uint8
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
            1. DAO collects up to 10% of the fees
            2. The LPers collect the rest of the fees
            3. The reserve of the synthetic token is reduced
         */

        reserves.daoFees += feeToDAO;
        reserves.lpReserve += collateralFee - feeToDAO;
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

    function _getSupplies(
        bool isAPE,
        VaultStructs.State memory state_,
        VaultStructs.Reserves memory reserves
    ) private view returns (APE ape, uint152 syntheticTokenReserve, uint256 syntheticTokenSupply) {
        if (isAPE) {
            ape = APE(SaltedAddress.getAddress(address(this), state_.vaultId));
            syntheticTokenReserve = reserves.apesReserve;
            syntheticTokenSupply = ape.totalSupply();
        } else {
            syntheticTokenReserve = reserves.lpReserve;
            syntheticTokenSupply = totalSupply[state_.vaultId];
        }
    }

    function _getReserves(
        VaultStructs.State memory state_,
        int8 leverageTier
    ) private view returns (VaultStructs.Reserves memory reserves) {
        unchecked {
            reserves.daoFees = state_.daoFees;

            // Reserve is empty
            if (state_.totalReserves == 0) return reserves;

            if (state_.tickPriceSatX42 == type(int64).min) {
                if (totalSupply[state_.vaultId] == 0) {
                    reserves.apesReserve = state_.totalReserves; // type(int64).min represents -∞ => lpReserve = 0
                } else {
                    reserves.apesReserve = state_.totalReserves - 1;
                    reserves.lpReserve = 1;
                }
            } else if (state_.tickPriceSatX42 == type(int64).max) {
                if (APE(SaltedAddress.getAddress(address(this), state_.vaultId)).totalSupply() == 0) {
                    reserves.lpReserve = state_.totalReserves; // type(int64).max represents +∞ => apesReserve = 0
                } else {
                    reserves.apesReserve = 1;
                    reserves.lpReserve = state_.totalReserves - 1;
                }
            } else {
                uint8 absLeverageTier = leverageTier >= 0 ? uint8(leverageTier) : uint8(-leverageTier);

                if (state_.tickPriceX42 < state_.tickPriceSatX42) {
                    /**
                     * POWER ZONE
                     * A = (price/priceSat)^(l-1) R/l
                     * price = 1.0001^tickPriceX42 and priceSat = 1.0001^tickPriceSatX42
                     * We use the fact that l = 1+2^leverageTier
                     * apesReserve is rounded up
                     */
                    (bool OF, uint256 poweredPriceRatio) = TickMathPrecision.getRatioAtTick(
                        leverageTier > 0
                            ? (state_.tickPriceSatX42 - state_.tickPriceX42) << absLeverageTier
                            : (state_.tickPriceSatX42 - state_.tickPriceX42) >> absLeverageTier
                    );

                    if (OF) {
                        reserves.apesReserve = 1;
                    } else {
                        /** Rounds up apesReserve, rounds down lpReserve.
                            Cannot OF.
                            64 bits because getRatioAtTick returns a Q64.64 number.
                         */
                        reserves.apesReserve = uint152(
                            _divRoundUp(
                                uint256(state_.totalReserves) << (leverageTier >= 0 ? 64 : 64 + absLeverageTier),
                                poweredPriceRatio + (poweredPriceRatio << absLeverageTier)
                            )
                        );

                        assert(reserves.apesReserve != 0); // It should never be 0 because it's rounded up. Important for the protocol that it is at least 1.
                    }

                    reserves.lpReserve = state_.totalReserves - reserves.apesReserve;
                } else {
                    /**
                     * SATURATION ZONE
                     * LPers are 100% pegged to debt token.
                     * L = (priceSat/price) R/r
                     * price = 1.0001^tickPriceX42 and priceSat = 1.0001^tickPriceSatX42
                     * We use the fact that lr = 1+2^-leverageTier
                     * lpReserve is rounded up
                     */
                    (bool OF, uint256 priceRatio) = TickMathPrecision.getRatioAtTick(
                        state_.tickPriceX42 - state_.tickPriceSatX42
                    );

                    if (OF) {
                        reserves.lpReserve = 1;
                    } else {
                        /** Rounds up lpReserve, rounds down apesReserve.
                            Cannot OF.
                            64 bits because getRatioAtTick returns a Q64.64 number.
                         */
                        reserves.lpReserve = uint152(
                            _divRoundUp(
                                uint256(state_.totalReserves) << (leverageTier >= 0 ? 64 : 64 + absLeverageTier),
                                priceRatio + (priceRatio << absLeverageTier)
                            )
                        );

                        assert(reserves.lpReserve != 0); // It should never be 0 because it's rounded up. Important for the protocol that it is at least 1.
                    }

                    reserves.apesReserve = state_.totalReserves - reserves.lpReserve;
                }
            }
        }
    }

    function _divRoundUp(uint256 a, uint256 b) private pure returns (uint256) {
        unchecked {
            return (a - 1) / b + 1;
        }
    }

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
            uint256 balance = IERC20(collateralToken).balanceOf(address(this)) - state_.daoFees - state_.totalReserves;

            require(uint152(balance) == balance);
            return uint152(balance);
        }
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function widhtdrawDAOFees(uint40 vaultId, address to) external onlySystemControl {
        VaultStructs.Parameters memory params = paramsById[vaultId];

        uint256 daoFees = state[params.debtToken][params.collateralToken][params.leverageTier].daoFees;
        state[params.debtToken][params.collateralToken][params.leverageTier].daoFees = 0; // Null balance to avoid reentrancy attack

        TransferHelper.safeTransfer(params.collateralToken, to, daoFees);
    }
}
