// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Libraries
import {FullMath} from "./FullMath.sol";

/**
 * @notice	Smart contract for computing fees in SIR.
 */

/**
    In 3 months, ETH remained flat while SQUEETH lost -16%. Without fees and volatility decay, SQUEETH should also have remained flat.
    Compounding the fees for 4 times, we get (1-0.16)^(1 year/3 months) = 50% lost over a year with a flat price a 2x.
    This computation has to be done on flat prices, because when the price moves, SQUEETH has to overpay shorters to stay short.
    In SIR the LPers take the loss when the market moves against them, and viceversa.
    This implies a baseFee = 100% for 2x constant leverage. At 1.2x, fee = 20%.
    BUT this would make overcollateralized stablecoins very expensive unless they mint and burn when they are the minority.
    Yes and no, the gentlemen would need to wait for the right time to cash out.
    If the market consensus is that the price will go up, then the LPers would want to cash out and the apes to stay in, right?
    Not exactly because then the LPers also lose on the ludicrous fees of those that just open a long.

    Make the protocol charge proportionally to the amount of LP liquidity needed to compensate for your actions. So..
    - Deposit APE when A > (l-1)T => fBasis·(l-1)
    - Deposit TEA when T > (r-1)A => fBasis·(r-1)
    - Withdraw APE when A < (l-1)T => fBasis (here APE is acting as liquidity for gentlemen, and removing it is equivalent to removing LP liquidity)
    - Withdraw TEA when T < (r-1)A => fBasis
    - Else, => 0

    Even if I chose fBasis=50%, that is still A LOT to pay to exit TEA. Not sure who will use TEA tokens,
    and if there is any need for including the extra complexity in the system. What if only create the APE token?
    I could arbitrarily set the TEA fees lower, but it is still not ideal because it relies on the price of other tokens.
*/

library Fees {
    /**
     * FeesParameters compacts all parameters and avoid "stack to deep" compiling errors
     *     baseFee: indicates the fee in basis points charged to gentlmen/apes per unit of liquidity.
     *     isMint: is true if the fee is computed for minting TEA/APE, or false for burning TEA/APE
     *     collateralInOrOut: is the collateral send or burnt by the user
     *     reserveSyntheticToken: is the amount of collateral in the vault for gentlemen/apes
     *     reserveOtherToken: is the amount of collateral in the vault for apes/gentlemen
     *     collateralizationOrLeverageTier: is the collateralization factor or leverage tier
     */
    struct FeesParameters {
        uint16 baseFee;
        bool isMint;
        uint256 collateralInOrOut; // mint => collateralIn; burn => collateralOut
        uint256 reserveSyntheticToken; // TEA => gentlemenReserve; APE => apesReserve
        uint256 reserveOtherToken; // TEA => apesReserve; APE => gentlemenReserve
        int256 collateralizationOrLeverageTier; // TEA => collateralization tier (-k); APE => leverage tier (k)
    }

    /**
     * @notice The user mints/burns TEA/APE and a fee is substracted
     *     @return collateralDepositedOrWithdrawn
     *     @return comission to LPers
     */
    function _hiddenFee(
        FeesParameters memory feesParams
    ) internal pure returns (uint256 collateralDepositedOrWithdrawn, uint256 comission) {
        unchecked {
            assert(
                // Negative of such value would cause revert
                feesParams.collateralizationOrLeverageTier != type(int256).min
            );

            uint256 idealReserveSyntheticToken;
            if (feesParams.collateralizationOrLeverageTier >= 0) {
                idealReserveSyntheticToken =
                    feesParams.reserveOtherToken >>
                    uint256(feesParams.collateralizationOrLeverageTier);
            } else {
                idealReserveSyntheticToken =
                    feesParams.reserveOtherToken <<
                    uint256(-feesParams.collateralizationOrLeverageTier);

                if (
                    idealReserveSyntheticToken >> uint256(-feesParams.collateralizationOrLeverageTier) !=
                    feesParams.reserveOtherToken
                ) idealReserveSyntheticToken = type(uint256).max;
            }

            uint256 taxFreeCollateral = feesParams.isMint
                ? (
                    idealReserveSyntheticToken > feesParams.reserveSyntheticToken
                        ? idealReserveSyntheticToken - feesParams.reserveSyntheticToken
                        : 0
                )
                : (
                    feesParams.reserveSyntheticToken > idealReserveSyntheticToken
                        ? feesParams.reserveSyntheticToken - idealReserveSyntheticToken
                        : 0
                );

            if (taxFreeCollateral >= feesParams.collateralInOrOut) return (feesParams.collateralInOrOut, 0);

            uint256 taxableCollateral = feesParams.collateralInOrOut - taxFreeCollateral;

            uint256 feeNum;
            uint256 feeDen;
            if (feesParams.collateralizationOrLeverageTier >= 0) {
                feeNum = uint256(feesParams.baseFee) << uint256(feesParams.collateralizationOrLeverageTier);
                feeDen = 10000 + (uint256(feesParams.baseFee) << uint256(feesParams.collateralizationOrLeverageTier));
            } else {
                feeNum = uint256(feesParams.baseFee);
                feeDen = (10000 << uint256(-feesParams.collateralizationOrLeverageTier)) + uint256(feesParams.baseFee);
            }

            // Split taxableCollateral into comission and collateralDepositedOrWithdrawn
            comission = FullMath.mulDivRoundingUp(taxableCollateral, feeNum, feeDen);
            collateralDepositedOrWithdrawn = feesParams.collateralInOrOut - comission;
        }
    }
}
