// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {DeployerOfAPE, APE, SaltedAddress, FullMath} from "./libraries/DeployerOfAPE.sol";
import {TickMathPrecision} from "./libraries/TickMathPrecision.sol";
import {Fees} from "./libraries/Fees.sol";

// Contracts
import {Oracle} from "./Oracle.sol";
import {VaultStructs} from "./interfaces/VaultStructs.sol";
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
        if (leverageTier > 10 || leverageTier < -6) revert LeverageTierOutOfRange();

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

        // Push parameters before deploying tokens, because they are accessed by the tokens' constructors
        _paramsById.push(VaultStructs.Parameters(debtToken, collateralToken, leverageTier));

        // Deploy APE token, and initialize it
        DeployerOfAPE.deploy(_transientTokenParameters, vaultId, debtToken, collateralToken, leverageTier);

        // Save vaultId and parameters
        state_.vaultId = uint128(vaultId);
    }

    /*////////////////////////////////////////////////////////////////
                            MINT/BURN FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
        ADD QUOTING FUNCTIONS TO THE PERIPHERY?
        ADD GET RESERVES FUNCTION TO THE PERIPHERY?
     */

    function mintAPE(address debtToken, address collateralToken, int8 leverageTier) external returns (uint256) {
        (bytes16 tickPriceX42, VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) = _preprocess(
            true,
            debtToken,
            collateralToken,
            leverageTier
        );

        // Get deposited collateral
        uint256 collateralIn = _getCollateralDeposited(state_, collateralToken);

        // Substract fee
        uint256 collateralFee;
        (collateralIn, collateralFee) = Fees.hiddenFee(systemParams.baseFee, collateralIn, leverageTier);

        // Retrieve APE contract
        APE ape = APE(SaltedAddress.getAddress(state_.vaultId, _hashCreationCodeAPE));

        // Compute amount of APE to mint
        uint256 amount = reserves.apesReserve == 0
            ? collateralIn
            : FullMath.mulDiv(ape.totalSupply(), collateralIn, reserves.apesReserve);

        // Mint APE
        ape.mint(msg.sender, amount);

        // Mint protocol-owned liquidity if necessary (10% of the fee)
        _mintPol(state_.vaultId, collateralFee, reserves.lpReserve);

        // Update new reserves
        uint256 feeToDAO = FullMath.mulDiv(
            collateralFee,
            _vaultsIssuanceParams[state_.vaultId].taxToDAO, // taxToDAO is an uint16
            10 * type(uint16).max
        );
        unchecked {
            // The total reserve cannot exceed the totalSupply
            reserves.daoFees += feeToDAO;
            reserves.apesReserve += collateralIn;
            reserves.lpReserve += collateralFee - feeToDAO;
        }

        // Update state from new reserves
        _updateState(state_, reserves, leverageTier, tickPriceX42);

        // Store new state reserves
        state[debtToken][collateralToken][leverageTier] = state_;

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
        (bytes16 tickPriceX42, VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) = _preprocess(
            false,
            debtToken,
            collateralToken,
            leverageTier
        );

        // Retrieve APE contract
        APE ape = APE(SaltedAddress.getAddress(state_.vaultId, _hashCreationCodeAPE));

        // Get collateralOut
        uint256 collateralOut = FullMath.mulDiv(reserves.apesReserve, amountAPE, ape.totalSupply());

        // Substract fee
        uint256 collateralFee;
        (collateralOut, collateralFee) = Fees.hiddenFee(systemParams.baseFee, collateralOut, leverageTier);

        // Burn APE
        ape.burn(msg.sender, amountAPE);

        // Mint protocol-owned liquidity if necessary (10% of the fee)
        _mintPol(state_.vaultId, collateralFee, reserves.lpReserve);

        // Update reserves
        uint256 feeToDAO = FullMath.mulDiv(
            collateralFee,
            _vaultsIssuanceParams[state_.vaultId].taxToDAO, // taxToDAO is an uint16
            10 * type(uint16).max
        );
        reserves.apesReserve -= collateralOut + collateralFee;
        unchecked {
            // The total reserve cannot exceed the totalSupply
            reserves.daoFees += feeToDAO;
            reserves.lpReserve += collateralFee - feeToDAO;
        }

        // Update state
        _updateState(state_, reserves, leverageTier, tickPriceX42);

        // Store new state reserves
        state[debtToken][collateralToken][leverageTier] = state_;

        // Withdraw collateral to user (after substracting fee)
        TransferHelper.safeTransfer(collateralToken, msg.sender, collateralOut);

        return collateralOut;
    }

    /**
     * @notice Upon transfering collateral to the contract, the minter must call this function atomically to mint the corresponding amount of MAAM.
     *     @notice Because MAAM is a rebasing token, the minted amount will always be collateralDeposited regardless of tickPriceX42 fluctuations.
     *     @notice To control the slippage it returns the final value of the LP reserves.
     *     @return LP reserve after mint
     */
    function mintMAAM(address debtToken, address collateralToken, int8 leverageTier) external returns (uint256) {
        (bytes16 tickPriceX42, VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) = _preprocess(
            false,
            debtToken,
            collateralToken,
            leverageTier
        );

        // Get deposited collateral
        uint256 collateralIn = _getCollateralDeposited(state_, collateralToken);

        // Compute amount to mint
        uint256 amount = reserves.lpReserve == 0
            ? collateralIn
            : FullMath.mulDiv(totalSupply[state_.vaultId], collateralIn, reserves.lpReserve);

        // Mint MAAM
        _mint(msg.sender, state_.vaultId, amount);

        // Update new reserves
        unchecked {
            reserves.lpReserve += collateralIn;
        }

        // Update state from new reserves
        _updateState(state_, reserves, leverageTier, tickPriceX42);

        // Store new state
        state[debtToken][collateralToken][leverageTier] = state_;

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
        (bytes16 tickPriceX42, VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) = _preprocess(
            false,
            debtToken,
            collateralToken,
            leverageTier
        );

        // Get collateralOut
        uint256 collateralOut = FullMath.mulDiv(reserves.lpReserve, amountMAAM, totalSupply[state_.vaultId]);

        // Burn MAAM
        _burn(msg.sender, state_.vaultId, amountMAAM);

        // Update reserves
        reserves.lpReserve -= collateralOut;

        // Update state from new reserves
        _updateState(state_, reserves, leverageTier, tickPriceX42);

        // Store new state
        state[debtToken][collateralToken][leverageTier] = state_;

        // Send collateral
        TransferHelper.safeTransfer(collateralToken, msg.sender, amountMAAM);

        return collateralOut;
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
        int8 leverageTier,
        int64 tickPriceX42
    ) public pure returns (VaultStructs.Reserves memory reserves) {
        unchecked {
            reserves.daoFees = state_.daoFees;

            // Reserve is empty
            if (state_.totalReserves == 0) return reserves;

            if (state_.tickPriceSatX42 == 0) {
                // No LPers
                reserves.apesReserve = state_.totalReserves;
            } else if (state_.tickPriceSatX42 == type(int64).max) {
                // No apes
                reserves.lpReserve = state_.totalReserves;
            } else if (tickPriceX42 < state_.tickPriceSatX42) {
                /**
                 * PRICE IN PSR
                 * Power zone
                 * A = (price/priceSat)^(l-1) R/l
                 * price = 1.0001^tickPriceX42 and priceSat = 1.0001^tickPriceSatX42
                 * We use the fact that l = 1+2^leverageTier
                 * apesReserve is rounded up
                 */
                bytes16 leverageRatio = _leverageRatio(leverageTier);
                uint8 absLeverageTier = leverageTier >= 0 ? uint8(leverageTier) : uint8(-leverageTier);
                uint256 den = uint256(
                    TickMathPrecision.getRatioAtTick(
                        leverageTier > 0
                            ? (state_.tickPriceSatX42 - tickPriceX42) << absLeverageTier
                            : (state_.tickPriceSatX42 - tickPriceX42) >> absLeverageTier
                    )
                );
                den += den << absLeverageTier;
                reserves.apesReserve = FullMath.mulDivRoundingUp(
                    state_.totalReserves,
                    2 ** (leverageTier >= 0 ? 64 : 64 + absLeverageTier), // 64 bits because getRatioAtTick returns a Q64.64 number
                    den
                );

                assert(reserves.apesReserve != 0);

                reserves.lpReserve = state_.totalReserves - reserves.apesReserve;
            } else {
                /**
                 * PRICE ABOVE PSR
                 *      LPers are 100% in pegged to debt token.
                 */
                bytes16 collateralizationFactor = _collateralizationFactor(leverageTier);
                reserves.lpReserve = state_.tickPriceSatX42.mulDiv(
                    state_.totalReserves,
                    tickPriceX42.mul(collateralizationFactor)
                );

                /**
                 * mulDiv rounds down, and collateralizationFactor>1 & tickPriceX42>=tickPriceSatX42, so lpReserve < totalReserves,
                 * we only need to check the case lpReserve == 0 to ensure no reserve ends up with 0 liquidity
                 */
                if (reserves.lpReserve == 0) reserves.lpReserve = 1;

                reserves.apesReserve = state_.totalReserves - reserves.lpReserve;
            }
        }
    }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _mintPol(uint256 vaultId, uint256 collateralFee, uint256 lpReserve) private {
        // A chunk of the LP fee is diverged to Protocol Owned Liquidity (POL)
        uint256 feePOL = collateralFee / 10;

        // Compute amount MAAM to mint as POL
        uint256 amountPOL = lpReserve == 0 ? feePOL : FullMath.mulDiv(totalSupply[vaultId], feePOL, lpReserve);

        // Mint protocol-owned liquidity if necessary
        _mint(address(this), vaultId, amountPOL);
    }

    function _preprocess(
        bool isMintAPE,
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) private returns (bytes16 tickPriceX42, VaultStructs.State memory state_, VaultStructs.Reserves memory reserves) {
        // Get tickPriceX42 and update oracle if necessary
        tickPriceX42 = oracle.updateOracleState(collateralToken, debtToken);

        // Retrieve state and check it actually exists
        state_ = state[debtToken][collateralToken][leverageTier];
        if (state_.vaultId == 0) revert VaultDoesNotExist();

        // Until SIR is running, only LPers are allowed to mint (deposit collateral)
        if (isMintAPE) require(systemParams.tsIssuanceStart > 0);

        // Compute reserves from state
        reserves = getReserves(state_, leverageTier, tickPriceX42);
    }

    function _getCollateralDeposited(
        VaultStructs.State memory state_,
        address collateralToken
    ) private view returns (uint256) {
        require(!systemParams.emergencyStop);

        // Get deposited collateral
        return IERC20(collateralToken).balanceOf(address(msg.sender)) - state_.daoFees - state_.totalReserves;
    }

    function _updateState(
        VaultStructs.State memory state_,
        VaultStructs.Reserves memory reserves,
        int8 leverageTier,
        bytes16 tickPriceX42
    ) private pure {
        state_.daoFees = reserves.daoFees;
        state_.totalReserves = reserves.apesReserve + reserves.lpReserve;

        if (state_.totalReserves == 0) return; // When the reserve is empty, tickPriceSatX42 is undetermined

        // Compute tickPriceSatX42
        if (reserves.apesReserve == 0) {
            state_.tickPriceSatX42 = FloatingPoint.INFINITY;
        } else if (reserves.lpReserve == 0) {
            state_.tickPriceSatX42 = FloatingPoint.ZERO;
        } else {
            bytes16 leverageRatio = _leverageRatio(leverageTier);
            bytes16 collateralizationFactor = _collateralizationFactor(leverageTier);
            if (reserves.apesReserve < leverageRatio.inv().mulu(state_.totalReserves)) {
                // PRICE IN PSR
                state_.tickPriceSatX42 = tickPriceX42.div(
                    leverageRatio.mulDivu(reserves.apesReserve, state_.totalReserves).pow(collateralizationFactor.dec())
                );
            } else {
                // PRICE ABOVE PSR
                state_.tickPriceSatX42 = collateralizationFactor.mul(tickPriceX42).mulDivu(
                    reserves.lpReserve,
                    state_.totalReserves
                );
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
