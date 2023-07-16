// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Libraries
import {FullMath} from "./FullMath.sol";

/**
 * @notice	Smart contract for computing fees in SIR.
 */

/**
    In 9 months, ETH gained 45% and SQUEETH -3%. Without volatility decay, SQUEETH should have gained 1.45^2, or 110%.
    This is equivalent to paying an initial fee of 1-0.97/2.1 = 0.54, which is 54%.
    If we assume the fee would have to scale linearly with time, that is (0.97/2.1)^(1 year/9 months) results in a fee of 64%.
    So... basisFee = 64/36 = 1.78 or 178% !! For every 1 ETH, we must pay 1.78 ETH in fees.
    If the leverage ratio was 1.2, then the fee would be 1.78*(1.2-1) = 0.35 or 35%.
    These are VERY HIGH FEES. Should I add a feethat deters LPers from draining liquidity in expectation of a large move?

    In 3 months, ETH remained flat while SQUEETH lost -16%. Without fees and volatility decay, SQUEETH should also have remained flat.
    Compounding the fees for 4 times, we get (1-0.16)^(1 year/3 months) = 50% lost over a year with a flat price a 2x.
    This computation has to be done on flat prices, because when the price moves, SQUEETH has to overpay shorters to stay short.
    In SIR the LPers take the loss when the market moves against them, and viceversa.
    This implies a basisFee = 100% for 2x constant leverage. At 1.2x, basisFee = 20%.
    BUT this would make overcollateralized stablecoins very expensive unless they mint and burn when they are the minority.
    Yes and no, the gentlemen would need to wait for the right time to cash out.
    If the market consensus is that the price will go up, then the LPers would want to cash out and the apes to stay in, right?
    Not exactly because then the LPers also lose on the ludicrous fees of those that just open a long.
*/

library Fees {
    /**
     * FeesParameters compacts all parameters and avoid "stack to deep" compiling errors
     *     basisFee: indicates the fee in basis points charged to gentlmen/apes per unit of liquidity.
     *     isMint: is true if the fee is computed for minting TEA/APE, or false for burning TEA/APE
     *     collateralInOrOut: is the collateral send or burnt by the user
     *     reserveSyntheticToken: is the amount of collateral in the vault for gentlemen/apes
     *     reserveOtherToken: is the amount of collateral in the vault for apes/gentlemen
     *     collateralizationOrLeverageTier: is the collateralization factor or leverage tier
     */
    struct FeesParameters {
        uint16 basisFee;
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
                feeNum = uint256(feesParams.basisFee) << uint256(feesParams.collateralizationOrLeverageTier);
                feeDen = 10000 + (uint256(feesParams.basisFee) << uint256(feesParams.collateralizationOrLeverageTier));
            } else {
                feeNum = uint256(feesParams.basisFee);
                feeDen = (10000 << uint256(-feesParams.collateralizationOrLeverageTier)) + uint256(feesParams.basisFee);
            }

            // Split taxableCollateral into comission and collateralDepositedOrWithdrawn
            comission = FullMath.mulDivRoundingUp(taxableCollateral, feeNum, feeDen);
            collateralDepositedOrWithdrawn = feesParams.collateralInOrOut - comission;
        }
    }
}
