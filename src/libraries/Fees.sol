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
    If the market consensus is that the price will go up, then the LPers would want to cash out and the apes to stay in, right?
    Not exactly because then the LPers also lose on the ludicrous fees of those that just open a long.
*/

library Fees {
    /**
     *  @notice The user mints/burns TEA/APE and a fee is substracted
     *  @return collateralDeposited
     *  @return comission to LPers
     */
    function _hiddenFee(
        uint16 baseFee,
        uint256 collateralAmount,
        int256 leverageTier
    ) internal pure returns (uint256 collateralDeposited, uint256 comission) {
        unchecked {
            assert(
                // Negative of such value would cause revert
                leverageTier != type(int256).min
            );

            uint256 feeNum;
            uint256 feeDen;
            if (leverageTier >= 0) {
                feeNum = uint256(baseFee) << uint256(leverageTier);
                feeDen = 10000 + (uint256(baseFee) << uint256(leverageTier));
            } else {
                feeNum = uint256(baseFee);
                feeDen = (10000 << uint256(-leverageTier)) + uint256(baseFee);
            }

            // Split collateralAmount into comission and collateralDeposited
            comission = FullMath.mulDivRoundingUp(collateralAmount, feeNum, feeDen);
            collateralDeposited = collateralAmount - comission;
        }
    }
}
