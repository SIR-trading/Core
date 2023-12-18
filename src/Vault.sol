// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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

    constructor(address systemControl, address sir, address oracle) TEA(systemControl, sir) {
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
    ) external returns (uint152 amount) {
        unchecked {
            VaultStructs.SystemParameters memory systemParams_ = systemParams;
            require(!systemParams_.emergencyStop);

            // Until SIR is running, only LPers are allowed to mint (deposit collateral)
            if (isAPE) require(systemParams_.tsIssuanceStart > 0);

            // Get the state
            VaultStructs.State memory state_ = _getState(debtToken, collateralToken, leverageTier);

            // Compute reserves from state
            (VaultStructs.Reserves memory reserves, APE ape, uint152 collateralDeposited) = VaultExternal.getReserves(
                true,
                isAPE,
                state_,
                collateralToken,
                leverageTier
            );

            VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_ = _vaultsIssuanceParams[state_.vaultId];
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
                mint(address(this), state_.vaultId, systemParams_, vaultIssuanceParams_, reserves, polFee);
            } else {
                // Mint TEA for user and protocol owned liquidity (POL)
                amount = mint(
                    msg.sender,
                    state_.vaultId,
                    systemParams_,
                    vaultIssuanceParams_,
                    reserves,
                    collateralDeposited
                );
            }

            // Update state from new reserves
            VaultExternal.updateState(state_, reserves, leverageTier);
            require(state_.totalReserves >= 2);

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
        uint256 amount
    ) external returns (uint152 collateralWidthdrawn) {
        // Get the state
        VaultStructs.State memory state_ = _getState(debtToken, collateralToken, leverageTier);

        // Compute reserves from state
        (VaultStructs.Reserves memory reserves, APE ape, ) = VaultExternal.getReserves(
            false,
            isAPE,
            state_,
            address(0),
            leverageTier
        );

        VaultStructs.SystemParameters memory systemParams_ = systemParams;
        VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_ = _vaultsIssuanceParams[state_.vaultId];
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
            mint(address(this), state_.vaultId, systemParams_, vaultIssuanceParams_, reserves, polFee);
        } else {
            // Burn TEA for user and mint TEA for protocol owned liquidity (POL)
            collateralWidthdrawn = burn(
                msg.sender,
                state_.vaultId,
                systemParams_,
                vaultIssuanceParams_,
                reserves,
                amount
            );
        }

        // Update state from new reserves
        VaultExternal.updateState(state_, reserves, leverageTier);
        require(state_.totalReserves >= 2);

        // Store new state
        state[debtToken][collateralToken][leverageTier] = state_;

        // Send collateral
        TransferHelper.safeTransfer(collateralToken, msg.sender, collateralWidthdrawn);

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

    // // OPTIMIZE WITH THIS?? https://github.com/Uniswap/v3-core/blob/d8b1c635c275d2a9450bd6a78f3fa2484fef73eb/contracts/UniswapV3Pool.sol#L140
    // function _getCollateralDeposited(
    //     VaultStructs.State memory state_,
    //     address collateralToken
    // ) private view returns (uint152) {
    //     // Get deposited collateral
    //     unchecked {
    //         uint256 balance = IERC20(collateralToken).balanceOf(address(this)) - state_.treasury - state_.totalReserves;

    //         require(uint152(balance) == balance);
    //         return uint152(balance);
    //     }
    // }

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
