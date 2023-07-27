// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {Oracle} from "./Oracle.sol";
import {VaultStructs} from "./interfaces/VaultStructs.sol";

// Libraries
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {DeployerOfTokens, APE} from "./DeployerOfTokens.sol";

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
    error LiquidityTooLow();

    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 indexed vaultId
    );

    /**
        To avoid having divisions by 0 due to price fluctuations. If a contracts gets bricked,
        then it was obviously to risky because the leveraged allowed the actual liquidity to decrease by more than 1M,
        and therefore it is ok to get bricked.
     */
    uint256 private constant _MIN_LIQUIDITY = 1e6;

    Oracle public immutable oracle;

    mapping(VaultStructs.Parameters => VaultStructs.State) public state; // Do not use vaultId 0
    VaultStructs.Parameters[] public override paramsById; // Never used in-contract. Just for users to access vault parameters by vault ID.

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

        // Deploy APE token, and initialize it
        deploy(vaultId, debtToken, collateralToken, leverageTier);

        // Save vaultId and parameters
        state_.vaultId = vaultId;
    }

    /*////////////////////////////////////////////////////////////////
                            MINT/BURN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
        ADD QUOTING FUNCTIONS TO THE PERIPHERY?
        ADD GET RESERVES FUNCTION TO THE PERIPHERY?
     */

    function mintAPE(address debtToken, address collateralToken, int8 leverageTier) external returns (uint256) {
        (bytes16 price, VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) = _preprocess(
            true,
            debtToken,
            collateralToken,
            leverageTier
        );

        // Get deposited collateral
        uint256 collateralIn = _getCollateralDeposited(state_, collateralToken);

        // Substract fee
        uint256 collateralFee;
        (collateralIn, collateralFee) = Fees._hiddenFee(systemParams.baseFee, collateralIn, leverageTier);

        // Retrieve APE contract
        APE ape = APE(getAddress(state_.vaultId));

        // Compute amount to mint
        uint256 amount;
        if (reserves.apesReserve == 0) {
            // Check min liquidity is added
            if (collateralIn < _MIN_LIQUIDITY) revert LiquidityTooLow();
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
        unchecked {
            // The total reserve cannot exceed the totalSupply
            reserves.daoFees += feeToDAO;
            reserves.apesReserve += collateralIn;
            reserves.lpReserve += collateralFee - feeToDAO;
        }

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
        APE ape = APE(getAddress(state_.vaultId, false));

        // Get collateralOut
        uint256 collateralOut = FullMath.mulDiv(reserves.apesReserve, amountAPE, ape.totalSupply());

        // Substract fee
        uint256 collateralFee;
        (collateralOut, collateralFee) = Fees._hiddenFee(systemParams.baseFee, collateralOut, leverageTier);

        // Burn APE
        ape.burn(msg.sender, amountAPE);

        // A chunk of the LP fee is diverged to Protocol Owned Liquidity (POL)
        uint256 feeToPOL = collateralFee / 10;

        // Mint protocol-owned liquidity if necessary
        if (feeToPOL > 0) _mint(address(this), state_.vaultId, feeToPOL, reserves.lpReserve);

        // Check reserve has enough liquidity
        if (reserves.apesReserve < _MIN_LIQUIDITY + collateralOut) revert LiquidityTooLow();

        // Update reserves
        uint256 feeToDAO = FullMath.mulDiv(collateralFee, _vaultsIssuances[msg.sender].taxToDAO, 1e5);
        unchecked {
            // The total reserve cannot exceed the totalSupply
            reserves.daoFees += feeToDAO;
            reserves.apesReserve -= collateralOut + collateralFee;
            reserves.lpReserve += collateralFee - feeToDAO;
        }

        // Update state
        _updateState(state_, reserves, leverageTier, price);

        // Store new state reserves
        state = state_;

        // Withdraw collateral to user (after substracting fee)
        TransferHelper.safeTransfer(collateralToken, msg.sender, collateralOut);

        return collateralOut;
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
        uint256 collateralIn = _getCollateralDeposited(state_, collateralToken);

        // Compute amount to mint
        uint256 amount;
        if (reserves.lpReserve == 0) {
            // Check min liquidity is added
            if (collateralIn < _MIN_LIQUIDITY) revert LiquidityTooLow();
            amount = collateralIn;
        } else {
            amount = FullMath.mulDiv(totalSupply(state_.vaultId), collateralIn, reserves.lpReserve);
        }

        // Mint MAAM
        _mint(msg.sender, state_.vaultId, amount);

        // Update new reserves
        reserves.lpReserve += collateralDeposited;

        // Check reserve has enough liquidity
        if (reserves.lpReserve < _MIN_LIQUIDITY) revert LiquidityTooLow();

        // Update state from new reserves
        _updateState(state_, reserves, leverageTier, price);

        // Store new state
        state = state_;

        return amount;
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

        // Get collateralOut
        uint256 collateralOut = FullMath.mulDiv(reserves.lpReserve, amountMAAM, totalSupply());

        // Burn MAAM
        _burn(msg.sender, state_.vaultId, amountMAAM);

        // Check reserve has enough liquidity
        if (reserves.lpReserve < _MIN_LIQUIDITY + collateralOut) revert LiquidityTooLow();

        // Update reserves
        unchecked {
            reserves.lpReserve -= collateralOut;
        }

        // Update state from new reserves
        _updateState(state_, reserves, leverageTier, price);

        // Store new state
        state = state_;

        // Send collateral
        TransferHelper.safeTransfer(collateralToken, msg.sender, amountMAAM);

        return collateralOut;
    }

    /*/////////////////////f//////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @return total supply of MAAM (which is pegged to the collateral)
     *     @dev Override of virtual totalSupply() in MAAM.sol
     */
    function totalSupply() public view override returns (uint256) {
        bytes16 price = oracle.getPrice(collateralToken);
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
        reserves.daoFees = state.daoFees;

        // Reserve is empty
        if (state.totalReserves == 0) return reserves;

        if (state.pHigh == FloatingPoint.ZERO) {
            // No LPers
            reserves.apesReserve = state.totalReserves;
        } else if (state.pHigh == FloatingPoint.INFINITY) {
            // No apes
            reserves.lpReserve = state.totalReserves;
        } else if (price.cmp(state.pHigh) < 0) {
            /**
             * PRICE IN PSR
             * Leverage behaves as expected
             */
            bytes16 leverageRatio = _leverageRatio(leverageTier);
            reserves.apesReserve = price.div(state.pHigh).pow(leverageRatio.dec()).mulDiv(
                state.totalReserves,
                leverageRatio
            );

            // mulDiv rounds down, and leverageRatio>1, so apesReserve != totalReserves, we only need to check the case apesReserve == 0
            /**
             * mulDiv rounds down, and leverageRatio>1 & price<pHigh, so apesReserve < totalReserves,
             * we only need to check the case apesReserve == 0 to ensure no reserve ends up with 0 liquidity
             */
            if (reserves.apesReserve == 0) reserves.apesReserve = 1;

            unchecked {
                reserves.lpReserve = state.totalReserves - reserves.apesReserve;
            }
        } else {
            /**
             * PRICE ABOVE PSR
             *      LPers are 100% in pegged to debt token.
             */
            bytes16 collateralizationFactor = _collateralizationFactor(leverageTier);
            reserves.lpReserve = pHigh.mulDiv(state.totalReserves, price.mul(collateralizationFactor));

            /**
             * mulDiv rounds down, and collateralizationFactor>1 & price>=pHigh, so lpReserve < totalReserves,
             * we only need to check the case lpReserve == 0 to ensure no reserve ends up with 0 liquidity
             */
            if (reserves.lpReserve == 0) reserves.lpReserve = 1;

            unchecked {
                reserves.apesReserve = state.totalReserves - reserves.lpReserve;
            }
        }
    }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    // DON'T LET THE LP OR APE RESERVE GO TO 0. AT LEAST IT MUST BE 1.

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
        state.daoFees = reserves.daoFees;
        state.totalReserves = reserves.apesReserve + reserves.lpReserve;

        if (state.totalReserves == 0) return; // When the reserve is empty, pHigh is undetermined

        // Compute pHigh
        if (reserves.apesReserve == 0) {
            state.pHigh = FloatingPoint.INFINITY;
        } else if (reserves.lpReserve == 0) {
            state.pHigh = FloatingPoint.ZERO;
        } else {
            bytes16 leverageRatio = _leverageRatio(leverageTier);
            if (reserves.apesReserve < leverageRatio.inv().mulu(state.totalReserves)) {
                // PRICE IN PSR
                state.pHigh = price.div(
                    leverageRatio.mulDivu(reserves.apesReserve, state.totalReserves).pow(collateralizationFactor.dec())
                );
            } else {
                // PRICE ABOVE PSR
                bytes16 collateralizationFactor = _collateralizationFactor(leverageTier);
                state.pHigh = collateralizationFactor.mul(price).mulDivu(reserves.lpReserve, state.totalReserves);
            }
        }
    }

    function _leverageRatio(int8 leverageTier) private pure returns (bytes16 leverageRatio) {
        bytes16 temp = FloatingPoint.fromInt(leverageTier).pow_2();
        leverageRatio = temp.inc();
    }

    function _collateralizationFactor(int8 leverageTier) private pure returns (bytes16 collateralizationFactor) {
        bytes16 temp = FloatingPoint.fromInt(leverageTier).pow_2();
        collateralizationFactor = temp.inv().inc();
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
        TransferHelper.safeTransfer(collateralToken, msg.sender, daoFees);
    }
}
