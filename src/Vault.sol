// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

// Libraries
import {VaultExternal} from "./libraries/VaultExternal.sol";
import {TransferHelper} from "v3-periphery/libraries/TransferHelper.sol";
import {TickMathPrecision} from "./libraries/TickMathPrecision.sol";
import {SirStructs} from "./libraries/SirStructs.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";

// Contracts
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {APE} from "./APE.sol";
import {Oracle} from "./Oracle.sol";
import {TEA} from "./TEA.sol";

import "forge-std/console.sol";

/** @notice This is the main contract of the protocol.
    @notice Users can mint or burn the synthetic assets (TEA or APE) of the protocol
    @dev Vault inherits from TEA which inherits from SystemState.
    @dev Vault is a singleton contract that manages all vaults for maximum efficiency.
    @dev A bogus collateral token (doing reentrancy attacks or returning face values)
    @dev would mean that all vaults using that type of collateral are compromised,
    @dev but vaults using other collateral types should be safe.
    @dev VaultExternal is an external library used for unloading bytecode and meeting the maximum contract size requirement.
 */
contract Vault is TEA {
    error AmountTooLow();
    error InsufficientCollateralReceivedFromUniswap();

    /** collateralFeeToLPers also includes protocol owned liquidity (POL),
        i.e., collateralFeeToLPers = collateralFeeToLPers + collateralFeeToProtocol
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

    Oracle private immutable _ORACLE;
    address private immutable _APE_IMPLEMENTATION;
    address private immutable _WETH;

    mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => SirStructs.VaultState)))
        internal _vaultStates; // Do not use vaultId 0

    /** Global parameters for each type of collateral that aggregates amounts from all vaults (excluding fees to stakers)
        Fees to stakers can always be recovered by computing IERC20(collateral).balanceOf(address(this)) - totalReserves[collateral],
        so that if a token is accidentally sent to this contract, it becomes dividends for the stakers.
     */
    mapping(address collateral => uint256) public totalReserves;

    constructor(
        address systemControl,
        address sir,
        address oracle,
        address apeImplementation,
        address weth
    ) TEA(systemControl, sir) {
        // Price _ORACLE
        _ORACLE = Oracle(oracle);

        // Save the address of the APE implementation
        _APE_IMPLEMENTATION = apeImplementation;

        // WETH
        _WETH = weth;

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

    /** @notice Function for minting APE or TEA, the protocol's synthetic tokens.
        @notice When minting APE, the user will give away a portion of his deposited collateral to the LPers.
        @notice When minting TEA, the user will give away a portion of his deposited collateral to protocol owned liquidity.
        @dev The user can mint by depositing collateral token or debt token dependening on whether collateralToDepositMin is 0 or not, respectively.
        @dev The user also has the option to mint with vanilla ETH when the token is WETH by simply sending ETH with the call. In this case, amountToDeposit is ignored.
        @param isAPE If true, mint APE. If false, mint TEA
        @param vaultParams The 3 parameters identifying a vault: collateral token, debt token, and leverage tier.
        @param amountToDeposit Collateral amount to deposit if collateralToDepositMin == 0, debt token to deposit if collateralToDepositMin > 0
        @param collateralToDepositMin Ignored when minting with collateral token, otherwise it specifies the minimum amount of collateral to receive from Uniswap when swapping the debt token.
        @return amount of tokens TEA/APE obtained
     */
    function mint(
        bool isAPE,
        SirStructs.VaultParameters memory vaultParams,
        uint256 amountToDeposit, // Collateral amount to deposit if collateralToDepositMin == 0, debt token to deposit if collateralToDepositMin > 0
        uint144 collateralToDepositMin
    ) external payable returns (uint256 amount) {
        // If ETH is received, we wrap it because we assume the user wants to mint with WETH
        bool isETH = msg.value != 0;
        if (isETH) amountToDeposit = VaultExternal.wrapETH(vaultParams, collateralToDepositMin, _WETH);

        // Cannot deposit 0
        if (amountToDeposit == 0) revert AmountTooLow();

        // Get reserves
        (
            SirStructs.VaultState memory vaultState,
            SirStructs.Reserves memory reserves,
            address ape,
            address uniswapPool
        ) = VaultExternal.getReserves(isAPE, _vaultStates, _ORACLE, vaultParams);

        if (collateralToDepositMin == 0) {
            // Minter deposited collateral

            // Check amount does not exceed max
            require(amountToDeposit <= type(uint144).max);

            // Rest of the mint logic
            amount = _mint(msg.sender, ape, vaultParams, uint144(amountToDeposit), vaultState, reserves);

            // If the user didn't send ETH, transfer the ERC20 collateral from the minter
            if (msg.value == 0) {
                TransferHelper.safeTransferFrom(
                    vaultParams.collateralToken,
                    msg.sender,
                    address(this),
                    amountToDeposit
                );
            }
        } else {
            // Minter deposited debt token and requires a Uniswap V3 swap

            // Store Uniswap v3 pool in transient storage so we can use it in the callback function
            assembly {
                tstore(0, uniswapPool)
            }

            // Check amount does not exceed max
            require(amountToDeposit <= uint256(type(int256).max));

            // Encode data for swap callback
            bool zeroForOne = vaultParams.collateralToken > vaultParams.debtToken;
            bytes memory data = abi.encode(msg.sender, ape, vaultParams, vaultState, reserves, zeroForOne, isETH);

            // Swap
            (int256 amount0, int256 amount1) = IUniswapV3Pool(uniswapPool).swap(
                address(this),
                zeroForOne,
                int256(amountToDeposit),
                zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
                data
            );

            // Retrieve amount of collateral received from the Uniswap pool
            uint256 collateralToDeposit = zeroForOne ? uint256(-amount1) : uint256(-amount0);

            // Check collateral received is sufficient
            if (collateralToDeposit < collateralToDepositMin) revert InsufficientCollateralReceivedFromUniswap();

            // Get amount of tokens
            assembly {
                amount := tload(0)
            }
        }
    }

    /** @dev This callback function is required by Uniswap pools when making a swap.
        @dev This function is exectuted when the user decides to mint TEA or APE with debt token.
        @dev This function is in charge of sending the debt token to the uniswwap pool.
        @dev It will revert if any external actor that is not a Uniswap pool calls this function. 
     */
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        // Check caller is the legit Uniswap pool
        address uniswapPool;
        assembly {
            uniswapPool := tload(0)
        }
        require(msg.sender == uniswapPool);

        // Decode data
        (
            address minter,
            address ape,
            SirStructs.VaultParameters memory vaultParams,
            SirStructs.VaultState memory vaultState,
            SirStructs.Reserves memory reserves,
            bool zeroForOne,
            bool isETH
        ) = abi.decode(
                data,
                (address, address, SirStructs.VaultParameters, SirStructs.VaultState, SirStructs.Reserves, bool, bool)
            );

        // Retrieve amount of collateral to deposit and check it does not exceed max
        (uint256 collateralToDeposit, uint256 debtTokenToSwap) = zeroForOne
            ? (uint256(-amount1Delta), uint256(amount0Delta))
            : (uint256(-amount0Delta), uint256(amount1Delta));

        // Rest of the mint logic
        require(collateralToDeposit <= type(uint144).max);
        uint256 amount = _mint(minter, ape, vaultParams, uint144(collateralToDeposit), vaultState, reserves);

        // Transfer debt token to the pool
        // This is done last to avoid reentrancy attack from a bogus debt token contract
        TransferHelper.safeTransferFrom(
            vaultParams.debtToken,
            isETH ? address(this) : minter,
            uniswapPool,
            debtTokenToSwap
        );

        // Use the transient storage to return amount of tokens minted to the mint function
        assembly {
            tstore(0, amount)
        }
    }

    /** @dev Remainer mint logic of the mint function above.
        @dev It is apart from the mint function because this logic needs to be executed in uniswapV3SwapCallback when minting with debt token
        @dev to ensure there is no reentrancy attack when minting with debt token.
     */
    function _mint(
        address minter,
        address ape, // If ape is 0, minting TEA
        SirStructs.VaultParameters memory vaultParams,
        uint144 collateralToDeposit,
        SirStructs.VaultState memory vaultState,
        SirStructs.Reserves memory reserves
    ) internal returns (uint256 amount) {
        SirStructs.SystemParameters memory systemParams_ = systemParams();
        require(!systemParams_.mintingStopped);

        SirStructs.VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams[vaultState.vaultId];
        SirStructs.Fees memory fees;
        bool isAPE = ape != address(0);
        if (isAPE) {
            // Mint APE
            (reserves, fees, amount) = APE(ape).mint(
                minter,
                systemParams_.baseFee.fee,
                vaultIssuanceParams_.tax,
                reserves,
                collateralToDeposit
            );

            // Distribute APE fees to LPers. Checks that it does not overflow
            reserves.reserveLPers += fees.collateralFeeToLPers;
        } else {
            // Mint TEA and distribute fees to protocol owned liquidity (POL)
            (fees, amount) = mint(
                minter,
                vaultParams.collateralToken,
                vaultState.vaultId,
                systemParams_,
                vaultIssuanceParams_,
                reserves,
                collateralToDeposit
            );
        }

        // For the sake of the user, do not let users deposit collateral in exchange for nothing
        if (amount == 0) revert AmountTooLow();

        // Update _vaultStates from new reserves
        _updateVaultState(vaultState, reserves, vaultParams);

        // Update total reserves
        totalReserves[vaultParams.collateralToken] += collateralToDeposit - fees.collateralFeeToStakers;

        // Emit event
        emit Mint(
            vaultState.vaultId,
            isAPE,
            fees.collateralInOrWithdrawn,
            fees.collateralFeeToStakers,
            fees.collateralFeeToLPers
        );

        /** Check if recipient is enabled for receiving TEA.
            This check is done last to avoid reentrancy attacks because it may call an external contract.
        */
        if (
            !isAPE &&
            minter.code.length > 0 &&
            ERC1155TokenReceiver(minter).onERC1155Received(minter, address(0), vaultState.vaultId, amount, "") !=
            ERC1155TokenReceiver.onERC1155Received.selector
        ) revert UnsafeRecipient();
    }

    /** @notice Function for burning APE or TEA, the protocol's synthetic tokens.
        @notice When burning APE, the user will give away a portion of his collateral to the LPers.
        @param isAPE If true, burn APE. If false, burn TEA
        @param vaultParams The 3 parameters identifying a vault: collateral token, debt token, and leverage tier.
        @param amount Amount of tokens to burn
        @return amount of collateral obtained for burning APE or TEA.
     */
    function burn(
        bool isAPE,
        SirStructs.VaultParameters calldata vaultParams,
        uint256 amount
    ) external returns (uint144) {
        if (amount == 0) revert AmountTooLow();

        SirStructs.SystemParameters memory systemParams_ = systemParams();

        // Get reserves
        (SirStructs.VaultState memory vaultState, SirStructs.Reserves memory reserves, address ape, ) = VaultExternal
            .getReserves(isAPE, _vaultStates, _ORACLE, vaultParams);

        SirStructs.VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams[vaultState.vaultId];
        SirStructs.Fees memory fees;
        if (isAPE) {
            // Burn APE
            (reserves, fees) = APE(ape).burn(
                msg.sender,
                systemParams_.baseFee.fee,
                vaultIssuanceParams_.tax,
                reserves,
                amount
            );

            // Distribute APE fees to LPers
            reserves.reserveLPers += fees.collateralFeeToLPers;
        } else {
            // Burn TEA (no fees are actually paid)
            fees = burn(vaultState.vaultId, systemParams_, vaultIssuanceParams_, reserves, amount);
        }

        // Update vault state from new reserves
        _updateVaultState(vaultState, reserves, vaultParams);

        // Update total reserves
        unchecked {
            totalReserves[vaultParams.collateralToken] -= fees.collateralInOrWithdrawn + fees.collateralFeeToStakers;
        }

        // Emit event
        emit Burn(
            vaultState.vaultId,
            isAPE,
            fees.collateralInOrWithdrawn,
            fees.collateralFeeToStakers,
            fees.collateralFeeToLPers
        );

        // Send collateral to the user
        TransferHelper.safeTransfer(vaultParams.collateralToken, msg.sender, fees.collateralInOrWithdrawn);

        return fees.collateralInOrWithdrawn;
    }

    /*////////////////////////////////////////////////////////////////
                            READ ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @notice Returns the reserves of the vault meaning (1) the amount of collateral in the vault belonging to apes,
        @notice (2) the amount of collateral belonging to LPers, and (3) the current collateral-debt-token price.
     */
    function getReserves(
        SirStructs.VaultParameters calldata vaultParams
    ) external view returns (SirStructs.Reserves memory) {
        return VaultExternal.getReservesReadOnly(_vaultStates, _ORACLE, vaultParams);
    }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @dev This function stores the state of the vault ass efficiently as possible.
        Connections Between VaultState Variables (R,priceSat) & Reserves (A,L)
        where R = Total reserve, A = Apes reserve, L = LP reserve
            (R,priceSat) ⇔ (A,L)
            (R,  ∞  ) ⇔ (0,L)
            (R,  0  ) ⇔ (A,0)
     */
    function _updateVaultState(
        SirStructs.VaultState memory vaultState,
        SirStructs.Reserves memory reserves,
        SirStructs.VaultParameters memory vaultParams
    ) private {
        // Checks that the reserve does not overflow uint144
        vaultState.reserve = reserves.reserveApes + reserves.reserveLPers;

        unchecked {
            /** We enforce that the reserve must be at least 10^6 to avoid division by zero, and
                to mitigate inflation attacks.
             */
            require(vaultState.reserve >= 1e6);

            // Compute tickPriceSatX42
            if (reserves.reserveApes == 0) {
                vaultState.tickPriceSatX42 = type(int64).max;
            } else if (reserves.reserveLPers == 0) {
                vaultState.tickPriceSatX42 = type(int64).min;
            } else {
                bool isLeverageTierNonNegative = vaultParams.leverageTier >= 0;

                /**
                 * Decide if we are in the power or saturation zone
                 * Condition for power zone: A < (l-1) L where l=1+2^leverageTier
                 */
                uint8 absLeverageTier = isLeverageTierNonNegative
                    ? uint8(vaultParams.leverageTier)
                    : uint8(-vaultParams.leverageTier);
                bool isPowerZone;
                if (isLeverageTierNonNegative) {
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
                        isLeverageTierNonNegative ? vaultState.reserve : uint256(vaultState.reserve) << absLeverageTier, // Cannot OF cuz reserve is uint144, and |leverageTier|<=3
                        (uint256(reserves.reserveApes) << absLeverageTier) + reserves.reserveApes // Cannot OF cuz reserveApes is uint144, and |leverageTier|<=3
                    );

                    // Compute saturation price
                    int256 tempTickPriceSatX42 = reserves.tickPriceX42 +
                        (isLeverageTierNonNegative ? tickRatioX42 >> absLeverageTier : tickRatioX42 << absLeverageTier);

                    // Check if overflow
                    if (tempTickPriceSatX42 > type(int64).max) vaultState.tickPriceSatX42 = type(int64).max;
                    else vaultState.tickPriceSatX42 = int64(tempTickPriceSatX42);
                } else {
                    /** PRICE IN SATURATION ZONE
                        priceSat = r*price*L/R
                     */

                    int256 tickRatioX42 = TickMathPrecision.getTickAtRatio(
                        isLeverageTierNonNegative ? uint256(vaultState.reserve) << absLeverageTier : vaultState.reserve,
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

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @notice This function is only intended to be called by the SIR contract.
        @notice The fees collected for SIR stakers are distributed to them.
        @param token to be distributed
        @return totalFeesToStakers is the total amount of tokens to be distributed
     */
    function withdrawFees(address token) external returns (uint256 totalFeesToStakers) {
        require(msg.sender == _SIR);

        // Surplus above totalReserves is fees to stakers
        totalFeesToStakers = IERC20(token).balanceOf(address(this)) - totalReserves[token];

        if (totalFeesToStakers != 0) {
            TransferHelper.safeTransfer(token, _SIR, totalFeesToStakers);
        }
    }

    /** @notice This function is only intended to be called as last recourse to save the system from a critical bug or hack
        @notice during the beta period. To execute it, the system must be in Shutdown status
        @notice which can only be activated after SHUTDOWN_WITHDRAWAL_DELAY seconds elapsed since Emergency status was activated.
        @param tokens is a list of tokens to be withdrawn.
        @param to is the recipient of the tokens
        @return amounts is the list of amounts of tokens to be withdrawn
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

    /** @notice Returns the state of a particular vault
        @param vaultParams The 3 parameters identifying a vault: collateral token, debt token, and leverage tier.
     */
    function vaultStates(
        SirStructs.VaultParameters calldata vaultParams
    ) external view returns (SirStructs.VaultState memory) {
        return _vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier];
    }
}
