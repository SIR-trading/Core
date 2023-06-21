// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Libraries
import {FullMath} from "./FullMath.sol";

/**
 * @notice	Smart contract for computing fees in SIR.
 */

library Fees {
    /**
     * FeesParameters compacts all parameters and avoid "stack to deep" compiling errors
     *     basisFee: indicates the fee in basis points charged to gentlmen/apes per unit of liquidity.
     *     isMint: is true if the fee is computed for minting TEA/APE, or false for burning TEA/APE
     *     collateralInOrOut: is the collateral send or burnt by the user
     *     reserveSyntheticToken: is the amount of collateral in the pool for gentlemen/apes
     *     reserveOtherToken: is the amount of collateral in the pool for apes/gentlemen
     *     collateralizationOrLeverageTier: is the collateralization factor or leverage tier
     */
    struct FeesParameters {
        uint16 basisFee;
        bool isMint;
        uint256 collateralInOrOut; // mint => collateralIn; burn => collateralOut
        uint256 reserveSyntheticToken; // TEA => gentlemenReserve; APE => apesReserve
        uint256 reserveOtherToken; // TEA => apesReserve; APE => gentlemenReserve
        int8 collateralizationOrLeverageTier; // TEA => collateralization tier (-k); APE => leverage tier (k)
    }

    /**
     * @notice The user mints/burns TEA/APE and a fee is substracted
     *     @return collateralDepositedOrWithdrawn
     *     @return comission to LPers
     */
    function _hiddenFee(
        FeesParameters memory feesParams
    )
        internal
        pure
        returns (uint256 collateralDepositedOrWithdrawn, uint256 comission)
    {
        unchecked {
            uint256 maxFreeReserveSyntheticToken;
            if (feesParams.collateralizationOrLeverageTier >= 0) {
                maxFreeReserveSyntheticToken =
                    feesParams.reserveOtherToken >>
                    uint256(int256(feesParams.collateralizationOrLeverageTier));
            } else {
                maxFreeReserveSyntheticToken =
                    feesParams.reserveOtherToken <<
                    uint256(
                        -int256(feesParams.collateralizationOrLeverageTier)
                    );

                if (
                    maxFreeReserveSyntheticToken >>
                        uint256(
                            -int256(feesParams.collateralizationOrLeverageTier)
                        ) !=
                    feesParams.reserveOtherToken
                ) maxFreeReserveSyntheticToken = type(uint256).max;
            }

            uint256 taxFreeCollateral = feesParams.isMint
                ? (
                    maxFreeReserveSyntheticToken >
                        feesParams.reserveSyntheticToken
                        ? maxFreeReserveSyntheticToken -
                            feesParams.reserveSyntheticToken
                        : 0
                )
                : (
                    feesParams.reserveSyntheticToken >
                        maxFreeReserveSyntheticToken
                        ? feesParams.reserveSyntheticToken -
                            maxFreeReserveSyntheticToken
                        : 0
                );

            if (taxFreeCollateral >= feesParams.collateralInOrOut)
                return (feesParams.collateralInOrOut, 0);

            uint256 taxableCollateral = feesParams.collateralInOrOut -
                taxFreeCollateral;

            uint256 feeNum;
            uint256 feeDen;
            if (feesParams.collateralizationOrLeverageTier >= 0) {
                feeNum =
                    uint256(feesParams.basisFee) <<
                    uint256(int256(feesParams.collateralizationOrLeverageTier));
                feeDen =
                    10000 +
                    (uint256(feesParams.basisFee) <<
                        uint256(
                            int256(feesParams.collateralizationOrLeverageTier)
                        ));
            } else {
                feeNum = uint256(feesParams.basisFee);
                feeDen =
                    (10000 <<
                        uint256(
                            -int256(feesParams.collateralizationOrLeverageTier)
                        )) +
                    uint256(feesParams.basisFee);
            }

            // Split taxableCollateral into comission and collateralDepositedOrWithdrawn
            comission = FullMath.mulDivRoundingUp(
                taxableCollateral,
                feeNum,
                feeDen
            );
            collateralDepositedOrWithdrawn =
                feesParams.collateralInOrOut -
                comission;
        }
    }
}
