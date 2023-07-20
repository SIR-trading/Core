// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {Oracle} from "./Oracle.sol";
import {VaultStructs} from "./interfaces/VaultStructs.sol";

// Libraries
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {DeployerOfTokens, SyntheticToken} from "./DeployerOfTokens.sol";

// Contracts
import {MAAM} from "./MAAM.sol";

/**
 * @dev Floating point (FP) numbers are necessary for rebasing balances of LP (MAAM tokens).
 *  @dev The price of the collateral vs rewards token is also represented as FP.
 *  @dev THE RULE is that rounding should be applied so that an equal or smaller amount is owed. In this way the protocol will never owe more than it controls.
 *  @dev price's range is [0,Infinity], where Infinity is included.
 *  @dev TEA's supply cannot exceed type(uint).max because of its mint() function.
 */
contract Vault is MAAM, DeployerOfTokens, VaultStructs {
    using FloatingPoint for bytes16;

    error VaultAlreadyInitialized();
    error VaultDoesNotExist();

    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 indexed vaultId
    );

    Oracle public immutable oracle;

    mapping(VaultStructs.Parameters => VaultStructs.State) public state; // Do not use vaultId 0
    VaultStructs.Parameters[] private paramsById; // Never used in-contract. Just for users to access vault parameters by vault ID.

    constructor(address vaultLogic, address oracle) MAAM(vaultLogic) {
        // Price oracle
        oracle = Oracle(oracle);

        /** We rely on vaultId == 0 to test if a particular vault exists.
         *  To make sure vault Id 0 is never used, we push one empty element as first entry.
         */
        paramsById.push(VaultStructs.Parameters());
    }

    function latestTokenParams()
        external
        returns (
            string memory name,
            string memory symbol,
            uint8 decimals,
            address debtToken,
            address collateralToken,
            int8 leverageTier
        )
    {
        TokenParameters memory tokenParams = tokenParameters;
        name = tokenParams.name;
        symbol = tokenParams.symbol;
        decimals = tokenParams.decimals;

        VaultStructs.Parameters memory params = paramsById[paramsById.length - 1];
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
        /**
         * 1. This will initialize the oracle for this pair of tokens if it has not been initialized before.
         * 2. It also will revert if there are no pools with liquidity, which implicitly solves the case where the user
         *    tries to instantiate an invalid pair of tokens like address(0)
         */
        oracle.initialize(debtToken, collateralToken);

        // Check the vault has not been initialized previously
        VaultStructs.State storage state_ = state[VaultStructs.Parameters(debtToken, collateralToken, leverageTier)];
        if (state_.vaultId != 0) revert VaultAlreadyInitialized();

        // Next vault ID
        uint256 vaultId = paramsById.length;

        // Push parameters before deploying tokens, because they are accessed by the tokens' constructors
        paramsById.push(VaultStructs.Parameters(debtToken, collateralToken, leverageTier));

        // Deploy TEA and APE tokens, and initialize them
        deploy(vaultId, debtToken, collateralToken, leverageTier);

        // Save vaultId and parameters
        state_.vaultId = vaultId;
    }

    /*////////////////////////////////////////////////////////////////
                            MINT/BURN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function mintAPE(address debtToken, address collateralToken, int8 leverageTier) external returns (uint256) {
        (bytes16 price, VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) = _preprocess(
            true,
            debtToken,
            collateralToken,
            leverageTier
        );

        // Get deposited collateral
        uint256 collateralDeposited = _getCollateralDeposited(state_, collateralToken);

        // Substract fee
        (uint256 collateralIn, uint256 collateralFee) = Fees._hiddenFee(
            systemParams.baseFee,
            collateralDeposited,
            leverageTier
        );

        // Retrieve APE contract
        SyntheticToken ape = SyntheticToken(getAddress(state_.vaultId));

        // Liquidate apes if necessary
        uint256 amount;
        if (reserves.apesReserve == 0) {
            ape.liquidate();
            amount = collateralIn;
        } else {
            amount = FullMath.mulDiv(ape.totalSupply(), collateralIn, reserves.apesReserve);
        }

        // Mint APE
        ape.mint(msg.sender, amount);

        // A chunk of the LP fee is diverged to Protocol Owned Liquidity (POL)
        uint256 feeToPOL = collateralFee / 10;

        // Mint protocol-owned liquidity if necessary
        if (feeToPOL > 0) _mint(address(this), state_.vaultId, feeToPOL, reserves.lpReserve);

        // Update new reserves
        uint256 feeToDAO = FullMath.mulDiv(collateralFee, _vaultsIssuances[msg.sender].taxToDAO, 1e5);
        reserves.daoFees += feeToDAO;
        reserves.apesReserve += collateralIn;
        reserves.lpReserve += collateralFee - feeToDAO;

        // Update state from new reserves
        _updateState(state_, reserves, leverageTier, price);

        // Store new state reserves
        state = state_;

        return amount;
    }

    /**
     *  @notice Users call burn() to burn their APE in exchange for hard cold collateral
     *  @param amountAPE is the amount of APE the gentleman wishes to burn
     *  @dev No fee is charged on exit
     */
    function burnAPE(
        address debtToken,
        address collateralToken,
        int8 leverageTier,
        uint256 amountAPE
    ) external returns (uint256) {
        (bytes16 price, VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) = _preprocess(
            false,
            debtToken,
            collateralToken,
            leverageTier
        );

        // Retrieve APE contract
        SyntheticToken ape = SyntheticToken(getAddress(state_.vaultId, false));

        // Get collateralOut
        uint256 collateralOut = FullMath.mulDiv(reserves.apesReserve, amountAPE, ape.totalSupply());

        // Burn APE
        ape.burn(msg.sender, amountAPE);

        // Update reserves
        reserves.apesReserve -= collateralOut;

        // Update state
        _updateState(state_, reserves, leverageTier, price);

        // Store new state reserves
        state = state_;

        // Withdraw collateral to user (after substracting fee)
        TransferHelper.safeTransfer(collateralToken, msg.sender, collateralOut);

        return collateralWithdrawn;
    }

    /**
     * @notice Upon transfering collateral to the contract, the minter must call this function atomically to mint the corresponding amount of MAAM.
     *     @notice Because MAAM is a rebasing token, the minted amount will always be collateralDeposited regardless of price fluctuations.
     *     @notice To control the slippage it returns the final value of the LP reserves.
     *     @return LP reserve after mint
     */
    function mintMAAM(address debtToken, address collateralToken, int8 leverageTier) external returns (uint256) {
        (bytes16 price, VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) = _preprocess(
            false,
            debtToken,
            collateralToken,
            leverageTier
        );

        // Get deposited collateral
        collateralDeposited = _getCollateralDeposited(state_, collateralToken);

        // Mint MAAM
        _mint(msg.sender, state_.vaultId, collateralDeposited, reserves.lpReserve);

        // Update new reserves
        reserves.lpReserve += collateralDeposited;

        // Update state from new reserves
        _updateState(state_, reserves, leverageTier, price);

        // Store new state
        state = state_;

        return reserves.lpReserve;
    }

    /**
     * @notice LPers call burnMAAM() to burn their MAAM in exchange for hard cold collateral
     *     @param amountMAAM the LPer wishes to burn
     *     @notice To control the slippage it returns the final value of the LP reserves.
     *     @return LP reserve after burn
     */
    function burnMAAM(
        address debtToken,
        address collateralToken,
        int8 leverageTier,
        uint256 amountMAAM
    ) external returns (uint256) {
        (bytes16 price, VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) = _preprocess(
            false,
            debtToken,
            collateralToken,
            leverageTier
        );

        // Burn MAAM
        if (amountMAAM == type(uint256).max) amountMAAM = _burnAll(msg.sender, reserves.lpReserve);
        else _burn(msg.sender, amountMAAM, reserves.lpReserve);

        // Update new reserves
        reserves.lpReserve -= amountMAAM;

        // Update state from new reserves
        _updateState(state_, reserves, leverageTier, price);

        // Store new state
        state = state_;

        // Send collateral
        TransferHelper.safeTransfer(_COLLATERAL_TOKEN, msg.sender, amountMAAM);

        return reserves.lpReserve;
    }

    /*/////////////////////f//////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @return total supply of MAAM (which is pegged to the collateral)
     *     @dev Override of virtual totalSupply() in MAAM.sol
     */
    function totalSupply() public view override returns (uint256) {
        bytes16 price = oracle.getPrice(_COLLATERAL_TOKEN);
        VaultStructs.Reserves memory reserves = _VAULT_LOGIC.getReserves(state, _LEVERAGE_TIER, price);
        return reserves.lpReserve;
    }

    /**
     * Connections Between State Variables (R,pHigh) & Reserves (A,L)
     *     where R = Total reserve, A = Apes reserve, L = LP reserve
     *     (R,pHigh) ⇔ (A,L)
     *     (R,  ∞  ) ⇔ (0,L)
     *     (R,  0  ) ⇔ (A,0)
     */

    function getReserves(
        VaultStructs.State memory state,
        int8 leverageTier,
        bytes16 price
    ) public pure returns (VaultStructs.Reserves memory reserves) {
        unchecked {
            reserves.daoFees = state.daoFees;

            // Reserve is empty
            if (state.totalReserves == 0) return reserves;

            if (state.pHigh == FloatingPoint.ZERO) {
                // All apes
                reserves.apesReserve = state.totalReserves;
                return reserves;
            }

            (bytes16 leverageRatio, bytes16 collateralizationFactor) = _calculateRatios(leverageTier);

            if (state.pHigh == FloatingPoint.INFINITY) {
                // No apes
                reserves.apesReserve = 0;
            } else if (price.cmp(state.pHigh) < 0) {
                /**
                 * PRICE IN PSR
                 * Leverage behaves as expected
                 */
                reserves.apesReserve = price.div(state.pHigh).pow(leverageRatio.dec()).mulDiv(
                    state.totalReserves,
                    leverageRatio
                );
                /**
                 * Proof apesReserve ≤ totalReserves:
                 *      price < pHigh ⇒ price.div(pHigh).pow(leverageRatio.dec()).mulDiv(totalReserves,leverageRatio)
                 *      < totalReserves / leverageRatio < totalReserves
                 * Proof apesReserve ≥ 0
                 *      All variables in the calculation are possitive
                 */
            } else {
                /**
                 * PRICE ABOVE PSR
                 *      LPers are 100% in pegged to debt token.
                 */
                // TO REDO!!
                reserves.apesReserve = state.totalReserves - state.pHigh.mulDiv(reserves.gentlemenReserve, pLow);
                /**
                 * Proof gentlemenReserve + apesReserve ≤ totalReserves
                 *                     pHigh / pLow ≥ 1
                 *                     ⇒ apesReserve ≤ totalReserves - gentlemenReserve
                 *                 Proof apesReserve ≥ 0
                 *                     pHigh.mulDiv(gentlemenReserve, pLow) ≤  pHigh / price * totalReserves / collateralizationFactor
                 *                     ⇒ pHigh.mulDiv(gentlemenReserve, pLow) ≤ totalReserves / collateralizationFactor
                 *                     ⇒ totalReserves - pHigh.mulDiv(gentlemenReserve, pLow) ≥ 0
                 */
            }

            assert(reserves.gentlemenReserve + reserves.apesReserve <= state.totalReserves);

            // COMPUTE LP RESERVE
            reserves.lpReserve = state.totalReserves - reserves.gentlemenReserve - reserves.apesReserve;
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
    ) private view returns (bytes16 price, VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) {
        // Get price and update oracle if necessary
        price = oracle.updateOracleState(collateralToken, debtToken);

        // Retrieve state and check it actually exists
        state_ = state;
        if (state_.vaultId == 0) revert VaultDoesNotExist();

        // Until SIR is running, only LPers are allowed to mint (deposit collateral)
        if (isMintAPE) require(systemParams.tsIssuanceStart > 0);

        // Compute reserves from state
        reserves = getReserves(state_, leverageTier, price);
    }

    function _getCollateralDeposited(
        VaultStructs.State memory state,
        address collateralToken
    ) private view returns (uint256) {
        require(!systemParams.onlyWithdrawals);

        // Get deposited collateral
        return IERC20(collateralToken).balanceOf(address(msg.sender)) - state.daoFees - state.totalReserves;
    }

    function _updateState(
        VaultStructs.State memory state,
        VaultStructs.Reserves memory reserves,
        int8 leverageTier,
        bytes16 price
    ) private pure {
        (bytes16 leverageRatio, bytes16 collateralizationFactor) = _calculateRatios(leverageTier);

        state.daoFees = reserves.daoFees;
        state.totalReserves = reserves.gentlemenReserve + reserves.apesReserve + reserves.lpReserve;

        unchecked {
            if (state.totalReserves == 0) return; // When the reserve is empty, pLow and pHigh are undetermined

            // COMPUTE pLiq & pLow
            state.pLiq = reserves.gentlemenReserve == 0
                ? FloatingPoint.ZERO
                : price.mulDivuUp(reserves.gentlemenReserve, state.totalReserves);
            bytes16 pLow = collateralizationFactor.mulUp(state.pLiq);
            /**
             * Why round up numerical errors?
             *                 To enable TEA to become a stablecoin, its price long term should not decay, even if extremely slowly.
             *                 By rounding up we ensure it decays UP.
             *             Numerical concerns
             *                 Division by 0 not possible because totalReserves != 0
             */

            // COMPUTE pHigh
            if (reserves.apesReserve == 0) {
                state.pHigh = FloatingPoint.INFINITY;
            } else if (reserves.lpReserve == 0) {
                state.pHigh = pLow;
            } else if (price.cmp(pLow) <= 0) {
                // PRICE BELOW PSR
                state.pHigh = pLow.div(
                    FloatingPoint.divu(reserves.apesReserve, reserves.apesReserve + reserves.lpReserve).pow(
                        collateralizationFactor.dec()
                    )
                );
                /**
                 * Numerical Concerns
                 *                     Division by 0 not possible because apesReserve != 0
                 *                     Righ hand side could still be ∞ because of the power.
                 *                     0 * ∞ not possible because  pLow > price > 0
                 *                 Proof pHigh ≥ pLow
                 *                     apesReserve + lpReserve ≥ apesReserve
                 */
            } else if (reserves.apesReserve < leverageRatio.inv().mulu(state.totalReserves)) {
                // PRICE IN PSR
                state.pHigh = price.div(
                    leverageRatio.mulDivu(reserves.apesReserve, state.totalReserves).pow(collateralizationFactor.dec())
                );
                /**
                 * Numerical Concerns
                 *                     Division by 0 not possible because totalReserves != 0
                 *                 Proof pHigh ≥ pLow
                 *                     leverageRatio.mulDivu(apesReserve,totalReserves) ≤ 1 & price ≥ pLow
                 */
            } else {
                // PRICE ABOVE PSR
                state.pHigh = collateralizationFactor.mul(price).mulDivu(
                    reserves.gentlemenReserve + reserves.lpReserve,
                    state.totalReserves
                );
                /**
                 * Numerical Concerns
                 *                     Division by 0 not possible because totalReserves != 0
                 *                 Proof pHigh ≥ pLow
                 *                     Yes, because
                 *                     collateralizationFactor.mul(price).mulDivu(gentlemenReserve + lpReserve,state.totalReserves) >
                 *                     collateralizationFactor.mul(price).mulDivu(gentlemenReserve,state.totalReserves) = pLow
                 */
            }

            assert(pLow.cmp(FloatingPoint.INFINITY) < 0);
            assert(pLow.cmp(state.pHigh) <= 0);
        }
    }

    function _calculateRatios(
        int8 leverageTier
    ) private pure returns (bytes16 leverageRatio, bytes16 collateralizationFactor) {
        bytes16 temp = FloatingPoint.fromInt(leverageTier).pow_2();
        collateralizationFactor = temp.inv().inc();
        leverageRatio = temp.inc();
    }

    /*////////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Multisig/daoFees withdraws collected _VAULT_LOGIC
     */
    function withdrawDAOFees() external returns (uint256 daoFees) {
        require(msg.sender == _VAULT_LOGIC.SYSTEM_CONTROL());
        daoFees = state.daoFees;
        state.daoFees = 0; // No re-entrancy attack
        TransferHelper.safeTransfer(_COLLATERAL_TOKEN, msg.sender, daoFees);
    }
}
