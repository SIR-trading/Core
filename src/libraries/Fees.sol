// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
     *  @return collateralFeeFree
     *  @return comission to LPers
     */
    function hiddenFee(
        uint16 baseFee,
        uint152 collateralAmount,
        int256 leverageTier
    ) internal pure returns (uint152, uint152) {
        unchecked {
            uint256 feeNum;
            uint256 feeDen;
            if (leverageTier >= 0) {
                feeNum = uint256(baseFee) << uint256(leverageTier); // baseFee is uint16, leverageTier is int8, so feeNum does not require more than 24 bits
                feeDen = 10000 + (uint256(baseFee) << uint256(leverageTier));
            } else {
                feeNum = uint256(baseFee);
                feeDen = (10000 << uint256(-leverageTier)) + uint256(baseFee);
            }

            // Split collateralAmount into comission and collateralFeeFree
            uint256 temp = uint256(collateralAmount) * feeNum;
            uint256 comission = temp == 0 ? 0 : (temp - 1) / feeDen + 1; // Cannot OF because feeNum takes at most 24 bits. Round up.
            uint256 collateralFeeFree = collateralAmount - comission;

            return (uint152(collateralFeeFree), uint152(comission));
        }
    }
}
