// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {VaultExternal} from "./libraries/VaultExternal.sol";
import {TransferHelper} from "v3-core/libraries/TransferHelper.sol";
import {TickMathPrecision} from "./libraries/TickMathPrecision.sol";
import {SirStructs} from "./libraries/SirStructs.sol";

// Contracts
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {APE} from "./APE.sol";
import {Oracle} from "./Oracle.sol";
import {TEA} from "./TEA.sol";

contract Vault is TEA {
    /** collateralFeeToLPers also includes protocol owned liquidity (POL),
        i.e., collateralFeeToLPers = collateralFeeToGentlemen + collateralFeeToProtocol
     */
    event Mint(
        uint48 indexed vaultId,
        bool isAPE,
        uint144 collateralIn,
        uint144 collateralFeeToStakers,
        uint144 collateralFeeToLPers
    );
    event Burn(
        uint48 indexed vaultId,
        bool isAPE,
        uint144 collateralWithdrawn,
        uint144 collateralFeeToStakers,
        uint144 collateralFeeToLPers
    );
    event FeesToStakers(address indexed collateralToken, uint112 totalFeesToStakers);

    Oracle private immutable _ORACLE;
    address private immutable _APE_IMPLEMENTATION;

    mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => SirStructs.VaultState)))
        internal _vaultStates; // Do not use vaultId 0

    // Global parameters for each type of collateral that aggregates amounts from all vaults
    mapping(address collateral => SirStructs.CollateralState) internal _collateralStates;

    constructor(address systemControl, address sir, address oracle, address apeImplementation) TEA(systemControl, sir) {
        // Price _ORACLE
        _ORACLE = Oracle(oracle);

        // Save the address of the APE implementation
        _APE_IMPLEMENTATION = apeImplementation;

        // Push empty parameters to avoid vaultId 0
        _paramsById.push(SirStructs.VaultParameters(address(0), address(0), 0));
    }

    /** @notice Initialization is always necessary because we must deploy APE contracts, and possibly initialize the Oracle.
     */
    function initialize(SirStructs.VaultParameters memory vaultParams) external {
        VaultExternal.deploy(
            _ORACLE,
            _vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier],
            _paramsById,
            vaultParams,
            _APE_IMPLEMENTATION
        );
    }

    /*////////////////////////////////////////////////////////////////
                            MINT/BURN FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @notice Function for minting APE or TEA
     */
    function mint(bool isAPE, SirStructs.VaultParameters calldata vaultParams) external returns (uint256 amount) {
        unchecked {
            SirStructs.SystemParameters memory systemParams_ = _systemParams;
            require(!systemParams_.mintingStopped);

            // Get reserves
            (
                SirStructs.CollateralState memory collateralState,
                SirStructs.VaultState memory vaultState,
                SirStructs.Reserves memory reserves,
                address ape,
                uint144 collateralDeposited
            ) = VaultExternal.getReserves(true, isAPE, _collateralStates, _vaultStates, _ORACLE, vaultParams);

            SirStructs.VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams[vaultState.vaultId];
            SirStructs.Fees memory fees;
            if (isAPE) {
                // Mint APE
                (reserves, fees, amount) = APE(ape).mint(
                    msg.sender,
                    systemParams_.baseFee,
                    vaultIssuanceParams_.tax,
                    reserves,
                    collateralDeposited
                );

                // Mint TEA for protocol owned liquidity (POL)
                if (fees.collateralFeeToProtocol > 0) {
                    mintToProtocol(
                        vaultParams.collateralToken,
                        vaultState.vaultId,
                        reserves,
                        fees.collateralFeeToProtocol
                    );
                }
            } else {
                // Mint TEA for user and protocol owned liquidity (POL)
                (fees, amount) = mint(
                    vaultParams.collateralToken,
                    vaultState.vaultId,
                    systemParams_,
                    vaultIssuanceParams_,
                    reserves,
                    collateralDeposited
                );
            }

            // Update _vaultStates from new reserves
            _updateVaultState(vaultState, reserves, vaultParams);

            // Update collateral params
            _updateCollateralState(
                true,
                collateralState,
                fees.collateralFeeToStakers,
                vaultParams.collateralToken,
                collateralDeposited
            );

            // Emit event
            emit Mint(
                vaultState.vaultId,
                isAPE,
                fees.collateralInOrWithdrawn,
                fees.collateralFeeToStakers,
                fees.collateralFeeToGentlemen + fees.collateralFeeToProtocol
            );

            /** Check if recipient is enabled for receiving TEA.
                This check is done last to avoid reentrancy attacks because it may call an external contract.
             */
            if (
                !isAPE &&
                msg.sender.code.length > 0 &&
                ERC1155TokenReceiver(msg.sender).onERC1155Received(
                    msg.sender,
                    address(0),
                    vaultState.vaultId,
                    amount,
                    ""
                ) !=
                ERC1155TokenReceiver.onERC1155Received.selector
            ) revert UnsafeRecipient();
        }
    }

    /** @notice Function for burning APE or TEA
     */
    function burn(
        bool isAPE,
        SirStructs.VaultParameters calldata vaultParams,
        uint256 amount
    ) external returns (uint144) {
        SirStructs.SystemParameters memory systemParams_ = _systemParams;

        // Get reserves
        (
            SirStructs.CollateralState memory collateralState,
            SirStructs.VaultState memory vaultState,
            SirStructs.Reserves memory reserves,
            address ape,

        ) = VaultExternal.getReserves(false, isAPE, _collateralStates, _vaultStates, _ORACLE, vaultParams);

        SirStructs.VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams[vaultState.vaultId];
        SirStructs.Fees memory fees;
        if (isAPE) {
            // Burn APE
            (reserves, fees) = APE(ape).burn(
                msg.sender,
                systemParams_.baseFee,
                vaultIssuanceParams_.tax,
                reserves,
                amount
            );

            // Mint TEA for protocol owned liquidity (POL)
            if (fees.collateralFeeToProtocol > 0) {
                mintToProtocol(vaultParams.collateralToken, vaultState.vaultId, reserves, fees.collateralFeeToProtocol);
            }
        } else {
            // Burn TEA for user and mint TEA for protocol owned liquidity (POL)
            fees = burn(
                vaultParams.collateralToken,
                vaultState.vaultId,
                systemParams_,
                vaultIssuanceParams_,
                reserves,
                amount
            );
        }

        // Update _vaultStates from new reserves
        _updateVaultState(vaultState, reserves, vaultParams);

        // Update collateral params
        _updateCollateralState(
            false,
            collateralState,
            fees.collateralFeeToStakers,
            vaultParams.collateralToken,
            fees.collateralInOrWithdrawn
        );

        // Emit event
        emit Burn(
            vaultState.vaultId,
            isAPE,
            fees.collateralInOrWithdrawn,
            fees.collateralFeeToStakers,
            fees.collateralFeeToGentlemen + fees.collateralFeeToProtocol
        );

        // Send collateral
        TransferHelper.safeTransfer(vaultParams.collateralToken, msg.sender, fees.collateralInOrWithdrawn);

        return fees.collateralInOrWithdrawn;
    }

    /*////////////////////////////////////////////////////////////////
                            READ ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @dev Kick it to periphery if more space is needed
     */
    function getReserves(
        SirStructs.VaultParameters calldata vaultParams
    ) external view returns (SirStructs.Reserves memory) {
        return VaultExternal.getReservesReadOnly(_vaultStates, _ORACLE, vaultParams);
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
        SirStructs.VaultState memory vaultState,
        SirStructs.Reserves memory reserves,
        SirStructs.VaultParameters calldata vaultParams
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
                    /** PRICE IN POWER ZONE
                        priceSat = price*(R/(lA))^(r-1)
                     */

                    int256 tickRatioX42 = TickMathPrecision.getTickAtRatio(
                        vaultParams.leverageTier >= 0
                            ? vaultState.reserve
                            : uint256(vaultState.reserve) << absLeverageTier, // Cannot OF cuz reserve is uint144, and |leverageTier|<=3
                        (uint256(reserves.reserveApes) << absLeverageTier) + reserves.reserveApes // Cannot OF cuz reserveApes is uint144, and |leverageTier|<=3
                    );

                    // Compute saturation price
                    int256 tempTickPriceSatX42 = reserves.tickPriceX42 +
                        (
                            vaultParams.leverageTier >= 0
                                ? tickRatioX42 >> absLeverageTier
                                : tickRatioX42 << absLeverageTier
                        );

                    // Check if overflow
                    if (tempTickPriceSatX42 > type(int64).max) vaultState.tickPriceSatX42 = type(int64).max;
                    else vaultState.tickPriceSatX42 = int64(tempTickPriceSatX42);
                } else {
                    /** PRICE IN SATURATION ZONE
                        priceSat = r*price*L/R
                     */

                    int256 tickRatioX42 = TickMathPrecision.getTickAtRatio(
                        vaultParams.leverageTier >= 0
                            ? uint256(vaultState.reserve) << absLeverageTier
                            : vaultState.reserve,
                        (uint256(reserves.reserveLPers) << absLeverageTier) + reserves.reserveLPers
                    );

                    // Compute saturation price
                    int256 tempTickPriceSatX42 = reserves.tickPriceX42 - tickRatioX42;

                    // Check if underflow
                    if (tempTickPriceSatX42 < type(int64).min) vaultState.tickPriceSatX42 = type(int64).min;
                    else vaultState.tickPriceSatX42 = int64(tempTickPriceSatX42);
                }
            }

            _vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier] = vaultState;
        }
    }

    function _updateCollateralState(
        bool isMint,
        SirStructs.CollateralState memory collateralState,
        uint256 collateralFeeToStakers,
        address collateralToken,
        uint144 collateralDepositedOrWithdrawn
    ) private {
        uint256 totalFeesToStakers_ = collateralState.totalFeesToStakers + collateralFeeToStakers;
        require(totalFeesToStakers_ <= type(uint112).max); // Ensure it fits in a uint112
        collateralState = SirStructs.CollateralState({
            totalFeesToStakers: uint112(totalFeesToStakers_),
            total: isMint
                ? collateralState.total + collateralDepositedOrWithdrawn
                : collateralState.total - collateralDepositedOrWithdrawn
        });

        _collateralStates[collateralToken] = collateralState;
        emit FeesToStakers(collateralToken, uint112(totalFeesToStakers_));
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function withdrawFees(address token) external returns (uint112 totalFeesToStakers) {
        require(msg.sender == _SIR);

        SirStructs.CollateralState memory collateralState = _collateralStates[token];
        totalFeesToStakers = collateralState.totalFeesToStakers;
        if (totalFeesToStakers != 0) {
            _collateralStates[token] = SirStructs.CollateralState({
                totalFeesToStakers: 0,
                total: collateralState.total - totalFeesToStakers
            });
            emit FeesToStakers(token, 0);
            TransferHelper.safeTransfer(token, _SIR, totalFeesToStakers);
        }
    }

    /** @notice This function is only intended to be called as last recourse to save the system from a critical bug or hack
        @notice during the beta period. To execute it, the system must be in Shutdown status
        @notice which can only be activated after SHUTDOWN_WITHDRAWAL_DELAY seconds elapsed since Emergency status was activated.
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

            // Data length is always a multiple of 32 bytes
            if (success && data.length == 32) {
                amounts[i] = abi.decode(data, (uint256));

                if (amounts[i] > 0) {
                    (success, data) = tokens[i].call(abi.encodeWithSelector(IERC20.transfer.selector, to, amounts[i]));

                    // If the transfer failed, set the amount of transfered tokens back to 0
                    success = success && (data.length == 0 || abi.decode(data, (bool)));

                    if (!success) amounts[i] = 0;
                }
            }
        }
    }

    /*////////////////////////////////////////////////////////////////
                            EXPLICIT GETTERS
    ////////////////////////////////////////////////////////////////*/

    function vaultStates(
        SirStructs.VaultParameters calldata vaultParams
    ) external view returns (SirStructs.VaultState memory) {
        return _vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier];
    }

    function collateralStates(address token) external view returns (SirStructs.CollateralState memory) {
        return _collateralStates[token];
    }
}
