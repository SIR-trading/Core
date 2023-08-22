// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {DeployerOfAPE, APE, SaltedAddress, FullMath} from "./libraries/DeployerOfAPE.sol";
import {TickMathPrecision} from "./libraries/TickMathPrecision.sol";
import {Fees} from "./libraries/Fees.sol";
import {VaultStructs} from "./libraries/VaultStructs.sol";

// Contracts
import {Oracle} from "./Oracle.sol";
import {SystemState} from "./SystemState.sol";

/**
 * @dev Floating point (FP) numbers are necessary for rebasing balances of LP (MAAM tokens).
 *  @dev The tickPriceX42 of the collateral vs rewards token is also represented as FP.
 *  @dev tickPriceX42's range is [0,Infinity], where Infinity is included.
 */
contract Vault is SystemState {
    error VaultAlreadyInitialized();
    error VaultDoesNotExist();
    error LeverageTierOutOfRange();
    error Overflow();

    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId
    );

    bytes32 private immutable _hashCreationCodeAPE;

    // Used to pass parameters to the APE token constructor
    VaultStructs.TokenParameters private _transientTokenParameters;

    Oracle public immutable oracle;

    mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => VaultStructs.State)))
        public state; // Do not use vaultId 0
    VaultStructs.Parameters[] private _paramsById; // Never used in-contract. Just for users to access vault parameters by vault ID.

    constructor(address systemControl_, address oracle_, bytes32 hashCreationCodeAPE) SystemState(systemControl_) {
        // Price oracle
        oracle = Oracle(oracle_);
        _hashCreationCodeAPE = hashCreationCodeAPE;

        /** We rely on vaultId == 0 to test if a particular vault exists.
         *  To make sure vault Id 0 is never used, we push one empty element as first entry.
         */
        _paramsById.push(VaultStructs.Parameters(address(0), address(0), 0));
    }

    function paramsById(
        uint256 vaultId
    ) public view override returns (address debtToken, address collateralToken, int8 leverageTier) {
        debtToken = _paramsById[vaultId].debtToken;
        collateralToken = _paramsById[vaultId].collateralToken;
        leverageTier = _paramsById[vaultId].leverageTier;
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

        VaultStructs.Parameters memory params = _paramsById[_paramsById.length - 1];
        debtToken = params.debtToken;
        collateralToken = params.collateralToken;
        leverageTier = params.leverageTier;
    }

    /**
        Initialization is always necessary because we must deploy TEA and APE contracts, and possibly initialize the Oracle.
        If I require initialization, the vaultId can be chosen sequentially,
        and stored in the state by squeezing out some bytes from the other state variables.
        Potentially we can have custom list of salts to allow for 7ea and a9e addresses.
     */
    function initialize(address debtToken, address collateralToken, int8 leverageTier) external {
        if (leverageTier > 2 || leverageTier < -3) revert LeverageTierOutOfRange();

        /**
         * 1. This will initialize the oracle for this pair of tokens if it has not been initialized before.
         * 2. It also will revert if there are no pools with liquidity, which implicitly solves the case where the user
         *    tries to instantiate an invalid pair of tokens like address(0)
         */
        oracle.initialize(debtToken, collateralToken);

        // Check the vault has not been initialized previously
        VaultStructs.State storage state_ = state[debtToken][collateralToken][leverageTier];
        if (state_.vaultId != 0) revert VaultAlreadyInitialized();

        // Next vault ID
        uint256 vaultId = _paramsById.length;
        require(vaultId <= type(uint40).max); // It has to fit in a uint40

        // Push parameters before deploying tokens, because they are accessed by the tokens' constructors
        _paramsById.push(VaultStructs.Parameters(debtToken, collateralToken, leverageTier));

        // Deploy APE token, and initialize it
        DeployerOfAPE.deploy(_transientTokenParameters, vaultId, debtToken, collateralToken, leverageTier);

        // Save vaultId and parameters
        state_.vaultId = uint40(vaultId);
    }

    /*////////////////////////////////////////////////////////////////
                            MINT/BURN FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
        ADD QUOTING FUNCTIONS TO THE PERIPHERY?
        ADD GET RESERVES FUNCTION TO THE PERIPHERY?
     */

    /** @notice Function for minting APE or MAAM
     */
    function mint(
        bool isAPE,
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external returns (uint256) {
        (VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) = _preprocess(
            false,
            debtToken,
            collateralToken,
            leverageTier
        );

        /** COMPUTE PARAMETERS
            ape                   - The token contract of APE if necessary
            syntheticTokenReserve - Collateral reserve backing APE or MAAM
            syntheticTokenSupply  - Supply of APE or MAAM
         */
        APE ape;
        uint152 syntheticTokenReserve;
        uint256 syntheticTokenSupply;
        if (isAPE) {
            ape = APE(SaltedAddress.getAddress(state_.vaultId, _hashCreationCodeAPE));
            syntheticTokenReserve = reserves.apesReserve;
            syntheticTokenSupply = ape.totalSupply();
        } else {
            syntheticTokenReserve = reserves.lpReserve;
            syntheticTokenSupply = totalSupply[state_.vaultId];
        }

        /** COMPUTE AMOUNTS
            collateralIn  - The amount of collateral that has been sent to the contract
            collateralFee - The amount of collateral paid in fees
            amount        - The amount of APE/MAAM minted for the user
            feeToPOL      - The amount of fees (collateral) diverged to protocol owned liquidity (POL)
            feeToDAO      - The amount of fees (collateral) diverged to the DAO
            amountPOL     - The amount of MAAM minted to protocol owned liquidity (POL)
         */

        // Get deposited collateral
        uint152 collateralIn = _getCollateralDeposited(state_, collateralToken);

        // Substract fee
        uint152 collateralFee;
        (collateralIn, collateralFee) = Fees.hiddenFee(
            isAPE ? systemParams.baseFee : systemParams.lpFee,
            collateralIn,
            isAPE ? leverageTier : int8(0)
        );

        // Compute amount MAAM or APE to mint for the user
        uint256 amount = syntheticTokenReserve == 0
            ? collateralIn
            : FullMath.mulDiv(syntheticTokenSupply, collateralIn, syntheticTokenReserve);

        // Compute amount MAAM to mint as POL (max 10% of collateralFee)
        uint152 feeToPOL = collateralFee / 10;
        uint256 amountPOL = reserves.lpReserve == 0
            ? feeToPOL
            : FullMath.mulDiv(syntheticTokenSupply, feeToPOL, reserves.lpReserve);

        // Compute amount of collateral diverged to the DAO (max 10% of collateralFee)
        uint152 feeToDAO;
        unchecked {
            feeToDAO = uint152(
                (collateralFee * _vaultsIssuanceParams[state_.vaultId].taxToDAO) / (10 * type(uint16).max)
            ); // Cannot OF cuz collateralFee is uint152 and taxToDAO is uint16
        }

        /** MINTING
            1. Mint APE or MAAM for the user
            2. Mint MAAM to protocol owned liquidity (POL)
         */

        // Mint APE/MAAM
        isAPE ? ape.mint(msg.sender, amount) : _mint(msg.sender, state_.vaultId, amount);

        // Mint protocol-owned liquidity if necessary
        _mint(address(this), state_.vaultId, amountPOL);

        /** UPDATE THE RESERVES
            1. DAO collects up to 10% of the fees
            2. The LPers collect the rest of the fees
            3. The reserve of the synthetic token is increased
         */
        reserves.daoFees += feeToDAO;
        reserves.lpReserve += collateralFee - feeToDAO;
        if (isAPE) reserves.apesReserve += collateralIn;
        else reserves.lpReserve += collateralIn;

        // Update state from new reserves
        _updateState(state_, reserves, leverageTier);

        // Store new state reserves
        state[debtToken][collateralToken][leverageTier] = state_;

        return amount;
    }

    /** @notice Function for burning APE or MAAM
     */
    function burn(
        bool isAPE,
        address debtToken,
        address collateralToken,
        int8 leverageTier,
        uint256 amountToken
    ) external returns (uint152) {
        (VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) = _preprocess(
            false,
            debtToken,
            collateralToken,
            leverageTier
        );

        /** COMPUTE PARAMETERS
            ape                   - The token contract of APE if necessary
            syntheticTokenReserve - Collateral reserve backing APE or MAAM
            syntheticTokenSupply  - Supply of APE or MAAM
         */
        APE ape;
        uint152 syntheticTokenReserve;
        uint256 syntheticTokenSupply;
        if (isAPE) {
            ape = APE(SaltedAddress.getAddress(state_.vaultId, _hashCreationCodeAPE));
            syntheticTokenReserve = reserves.apesReserve;
            syntheticTokenSupply = ape.totalSupply();
        } else {
            syntheticTokenReserve = reserves.lpReserve;
            syntheticTokenSupply = totalSupply[state_.vaultId];
        }

        /** COMPUTE AMOUNTS
            collateralOut - The amount of collateral that is removed from the reserve
            collateralWidthdrawn - The amount of collateral that is actually withdrawn by the user
            collateralFee - The amount of collateral paid in fees
            feeToPOL      - The amount of fees (collateral) diverged to protocol owned liquidity (POL)
            feeToDAO      - The amount of fees (collateral) diverged to the DAO
            amountPOL     - The amount of MAAM minted to protocol owned liquidity (POL)
         */

        // Get collateralOut
        uint152 collateralOut = uint152(FullMath.mulDiv(syntheticTokenReserve, amountToken, syntheticTokenSupply));

        // Substract fee
        (uint152 collateralWidthdrawn, uint152 collateralFee) = Fees.hiddenFee(
            isAPE ? systemParams.baseFee : systemParams.lpFee,
            collateralOut,
            isAPE ? leverageTier : int8(0)
        );

        // Compute amount MAAM to mint as POL (max 10% of collateralFee)
        uint152 feeToPOL = collateralFee / 10;
        uint256 amountPOL = reserves.lpReserve == 0
            ? feeToPOL
            : FullMath.mulDiv(syntheticTokenSupply, feeToPOL, reserves.lpReserve);

        // At most 10% of the collected fees go to the DAO
        uint152 feeToDAO;
        unchecked {
            feeToDAO = uint152(
                (collateralFee * _vaultsIssuanceParams[state_.vaultId].taxToDAO) / (10 * type(uint16).max)
            ); // Cannot OF cuz collateralFee is uint152 and taxToDAO is uint16
        }

        /** BURNING AND MINTING
            1. Burn APE or MAAM from the user
            2. Mint MAAM to protocol owned liquidity (POL)
         */

        // Burn APE/MAAM
        isAPE ? ape.burn(msg.sender, amountToken) : _burn(msg.sender, state_.vaultId, amountToken);

        // Mint protocol-owned liquidity if necessary
        _mint(address(this), state_.vaultId, amountPOL);

        /** UPDATE THE RESERVES
            1. DAO collects up to 10% of the fees
            2. The LPers collect the rest of the fees
            3. The reserve of the synthetic token is reduced
         */

        reserves.daoFees += feeToDAO;
        reserves.lpReserve += collateralFee - feeToDAO;
        if (isAPE) reserves.apesReserve -= collateralOut;
        else reserves.lpReserve -= collateralOut;

        /** REMAINING TASKS
            1. Update state from new reserves
            2. Store new state
            3. Send collateral
         */

        // Update state from new reserves
        _updateState(state_, reserves, leverageTier);

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

    function getReserves(
        VaultStructs.State memory state_,
        int8 leverageTier
    ) public pure returns (VaultStructs.Reserves memory reserves) {
        unchecked {
            reserves.daoFees = state_.daoFees;

            // Reserve is empty
            if (state_.totalReserves == 0) return reserves;

            if (state_.tickPriceSatX42 == type(int64).min) {
                // No LPers
                reserves.apesReserve = state_.totalReserves;
            } else if (state_.tickPriceSatX42 == type(int64).max) // type(int64).max represents infinity
            {
                // No apes
                reserves.lpReserve = state_.totalReserves;
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
                    // USE Q128.128!!
                    (bool OF, uint256 poweredPriceRatio) = TickMathPrecision.getRatioAtTick(
                        leverageTier > 0
                            ? (state_.tickPriceSatX42 - state_.tickPriceX42) << absLeverageTier
                            : (state_.tickPriceSatX42 - state_.tickPriceX42) >> absLeverageTier
                    );

                    if (OF) {
                        reserves.apesReserve = 1;
                    } else {
                        uint256 den = poweredPriceRatio + (poweredPriceRatio << absLeverageTier);
                        reserves.apesReserve = FullMath.mulDivRoundingUp( // NO NEED FOR FULLMATH!!
                            state_.totalReserves,
                            2 ** (leverageTier >= 0 ? 64 : 64 + absLeverageTier), // 64 bits because getRatioAtTick returns a Q64.64 number
                            den
                        );

                        assert(reserves.apesReserve != 0); // It should not be ever 0 because it's rounded up. Important for the protocol that it is at least 1.
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
                        uint256 den = priceRatio + (priceRatio << absLeverageTier);
                        reserves.lpReserve = FullMath.mulDivRoundingUp(
                            state_.totalReserves,
                            2 ** (leverageTier >= 0 ? 64 : 64 + absLeverageTier), // 64 bits because getRatioAtTick returns a Q64.64 number
                            den
                        );

                        assert(reserves.lpReserve != 0);
                    }

                    reserves.apesReserve = state_.totalReserves - reserves.lpReserve;
                }
            }
        }
    }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _preprocess(
        bool isMintAPE,
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) private returns (VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) {
        // Retrieve state and check it actually exists
        state_ = state[debtToken][collateralToken][leverageTier];
        if (state_.vaultId == 0) revert VaultDoesNotExist();

        // Retrieve price from oracle if not retrieved in a previous tx in this block
        if (state_.timeStampPrice != block.timestamp) {
            state_.tickPriceX42 = oracle.updateOracleState(collateralToken, debtToken);
            state_.timeStampPrice = uint40(block.timestamp);
        }

        // Until SIR is running, only LPers are allowed to mint (deposit collateral)
        if (isMintAPE) require(systemParams.tsIssuanceStart > 0);

        // Compute reserves from state
        reserves = getReserves(state_, leverageTier);
    }

    function _getCollateralDeposited(
        VaultStructs.State memory state_,
        address collateralToken
    ) private view returns (uint152) {
        require(!systemParams.emergencyStop);

        // Get deposited collateral
        unchecked {
            uint256 balance = IERC20(collateralToken).balanceOf(address(msg.sender)) -
                state_.daoFees -
                state_.totalReserves;

            if (uint152(balance) != balance) revert Overflow();
            return uint152(balance);
        }
    }

    function _updateState(
        VaultStructs.State memory state_,
        VaultStructs.Reserves memory reserves,
        int8 leverageTier
    ) private pure {
        unchecked {
            state_.daoFees = reserves.daoFees;
            state_.totalReserves = reserves.apesReserve + reserves.lpReserve;

            if (state_.totalReserves == 0) return; // When the reserve is empty, tickPriceSatX42 is undetermined

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
                    ) // Cannot OF because apesReserve is an uint152, and |leverageTier|<=2
                    {
                        isPowerZone = true;
                    } else {
                        isPowerZone = false;
                    }
                } else {
                    if (
                        reserves.apesReserve < uint256(reserves.lpReserve) << absLeverageTier
                    ) // Cannot OF because apesReserve is an uint152, and |leverageTier|<=2
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
                        leverageTier >= 0 ? state_.totalReserves : uint256(state_.totalReserves) << absLeverageTier, // Cannot OF cuz totalReserves is uint152, and |leverageTier|<=2
                        (uint256(reserves.apesReserve) << absLeverageTier) + reserves.apesReserve // Cannot OF cuz apesReserve is uint152, and |leverageTier|<=2
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
        }
    }

    // /*////////////////////////////////////////////////////////////////
    //                         ADMIN FUNCTIONS
    // ////////////////////////////////////////////////////////////////*/

    // /**
    //  * @notice Multisig/daoFees withdraws collected _VAULT_LOGIC
    //  */
    // function withdrawDAOFees() external returns (uint256 daoFees) {
    //     require(msg.sender == _VAULT_LOGIC.SYSTEM_CONTROL());
    //     daoFees = state.daoFees;
    //     state.daoFees = 0; // No re-entrancy attack
    //     TransferHelper.safeTransfer(collateralToken, msg.sender, daoFees);
    // }
}
