// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SirStructs} from "./SirStructs.sol";

/**
 * @notice	Smart contract for computing fees in SIR.
 */

library Fees {
    /** @notice APES pay a fee to the LPers when they mint/burn APE
        @notice If a non-zero tax is set for the vault, 10% of the fee is sent to SIR stakers
     */
    function feeAPE(
        uint144 collateralDepositedOrOut,
        uint16 baseFee,
        int256 leverageTier,
        uint8 tax
    ) internal pure returns (SirStructs.Fees memory fees) {
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

            // collateralDepositedOrOut = collateralInOrWithdrawn + collateralFeeToLPers + collateralFeeToStakers
            fees.collateralInOrWithdrawn = uint144((uint256(collateralDepositedOrOut) * feeNum) / feeDen);
            uint256 totalFees = collateralDepositedOrOut - fees.collateralInOrWithdrawn;

            // Depending on the tax, between 0 and 10% of the fee is for SIR stakers
            fees.collateralFeeToStakers = uint144((totalFees * tax) / (10 * uint256(type(uint8).max))); // Cannot overflow cuz fee is uint144 and tax is uint8

            // The rest is sent to the gentlemen, if there are none, then it is POL
            fees.collateralFeeToLPers = uint144(totalFees) - fees.collateralFeeToStakers;
        }
    }

    /** @notice LPers pay a fee to the protocol when they mint TEA
        @notice collateralFeeToLPers is the fee paid to the protocol (not all LPers)
     */
    function feeMintTEA(uint144 collateralDeposited, uint16 lpFee) internal pure returns (SirStructs.Fees memory fees) {
        unchecked {
            uint256 feeNum = 10000;
            uint256 feeDen = 10000 + uint256(lpFee);

            // collateralDeposited = collateralIn + collateralFeeToLPers
            fees.collateralInOrWithdrawn = uint144((uint256(collateralDeposited) * feeNum) / feeDen);
            fees.collateralFeeToLPers = collateralDeposited - fees.collateralInOrWithdrawn;
        }
    }
}
