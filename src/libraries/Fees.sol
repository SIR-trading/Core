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
     *  @return collateralInOrWidthdrawn
     */
    function hiddenFeeAPE(
        uint152 collateralDepositedOrOut,
        uint16 baseFee,
        int256 leverageTier,
        uint8 tax
    ) internal pure returns (uint152 collateralInOrWidthdrawn, uint152 treasuryFee, uint152 lpersFee, uint152 polFee) {
        unchecked {
            uint256 feeNum;
            uint256 feeDen;
            if (leverageTier >= 0) {
                feeNum = 10000; // baseFee is uint16, leverageTier is int8, so feeNum does not require more than 24 bits
                feeDen = 10000 + (uint256(baseFee) << uint256(leverageTier));
            } else {
                uint256 temp = 10000 << uint256(-leverageTier);
                feeNum = temp;
                feeDen = temp + uint256(baseFee);
            }

            // Split collateralDepositedOrOut into fee and collateralInOrWidthdrawn
            collateralInOrWidthdrawn = uint152((uint256(collateralDepositedOrOut) * feeNum) / feeDen);
            uint256 fee = collateralDepositedOrOut - collateralInOrWidthdrawn;

            // Depending on the tax, between 0 and 10% of the fee is added to the treasury
            treasuryFee = uint152((fee * tax) / (10 * uint256(type(uint8).max))); // Cannot overflow cuz fee is uint152 and tax is uint8

            // 10% of the fee is added as protocol owned liquidity (POL)
            polFee = uint152(fee) / 10;

            // The rest of the fee is added to the LPers
            lpersFee = uint152(fee) - treasuryFee - polFee;
        }
    }

    function hiddenFeeTEA(
        uint152 collateralDepositedOrOut,
        uint16 lpFee,
        uint8 tax
    ) internal pure returns (uint152 collateralInOrWidthdrawn, uint152 treasuryFee, uint152 lpersFee, uint152 polFee) {
        unchecked {
            uint256 feeNum = 10000;
            uint256 feeDen = 10000 + uint256(lpFee);

            // Split collateralDepositedOrOut into fee and collateralInOrWidthdrawn
            collateralInOrWidthdrawn = uint152((uint256(collateralDepositedOrOut) * feeNum) / feeDen);
            uint256 fee = collateralDepositedOrOut - collateralInOrWidthdrawn;

            // Depending on the tax, between 0 and 10% of the fee is added to the treasury
            treasuryFee = uint152((fee * tax) / (10 * uint256(type(uint8).max))); // Cannot overflow cuz fee is uint152 and tax is uint8

            // 10% of the fee is added as protocol owned liquidity (POL)
            polFee = uint152(fee) / 10;

            // The rest of the fee is added to the LPers
            lpersFee = uint152(fee) - treasuryFee - polFee;
        }
    }
}
