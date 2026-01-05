// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SirStructs} from "./SirStructs.sol";

/**
 * @notice	Smart contract for computing fees in SIR.
 */

library Fees {
    /**
     *  @notice APES pay a fee to the LPers when they mint/burn APE
     *  @notice If a non-zero tax is set for the vault, up to a maximum of 50% of the fee is sent to SIR stakers.
     *  @param collateralDepositedOrOut Amount of collateral deposited or taken out by the apes
     *  @param baseFee Base fee in basis points per unit of liquidity
     *  @param leverageTier Tier of the vault
     *  @param tax Tax in basis points charged to the apes for getting SIR
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

            // Depending on the tax, between 0 and 50% of the fee is for SIR stakers
            fees.collateralFeeToStakers = uint144((totalFees * tax) / (2 * uint256(type(uint8).max))); // Cannot overflow cuz fee is uint144 and tax is uint8

            // The rest is sent to the gentlemen, if there are none, then it is POL
            fees.collateralFeeToLPers = uint144(totalFees) - fees.collateralFeeToStakers;
        }
    }

    /**
     *  @notice LPers pay a fee to the protocol when they mint TEA
     *  @notice collateralFeeToLPers is the fee paid to the protocol (not all LPers)
     *  @notice LPers can reduce their fee by locking their TEA for a period of time
     *  @param collateralDeposited Amount of collateral deposited by the LPers
     *  @param lpFee Fee in basis points charged to LPers and sent to the protocol
     *  @param portionLockTime 0 = full fee (no lock), 255 = no fee (full lock)
     *  @param lpLockTime Max lock duration from system params
     *  @return fees The fee breakdown
     *  @return lockEndTimestamp The timestamp when the lock expires
     */
    function feeMintTEA(
        uint144 collateralDeposited,
        uint16 lpFee,
        uint8 portionLockTime,
        uint40 lpLockTime
    ) internal view returns (SirStructs.Fees memory fees, uint40 lockEndTimestamp) {
        unchecked {
            // Effective fee: ceil(lpFee * (255 - portionLockTime) / 255)
            // Round UP to charge slightly more fee when rounding
            uint256 effectiveFee = (
                uint256(lpFee) * (type(uint8).max - portionLockTime) + type(uint8).max - 1
            ) / type(uint8).max;

            uint256 feeNum = 10000;
            uint256 feeDen = 10000 + effectiveFee;

            // collateralDeposited = collateralIn + collateralFeeToLPers
            fees.collateralInOrWithdrawn = uint144((uint256(collateralDeposited) * feeNum) / feeDen);
            fees.collateralFeeToLPers = collateralDeposited - fees.collateralInOrWithdrawn;

            // Lock duration: ceil(lpLockTime * portionLockTime / 255)
            // Round UP to lock slightly longer when rounding
            lockEndTimestamp = uint40(block.timestamp) + uint40(
                (uint256(lpLockTime) * portionLockTime + type(uint8).max - 1) / type(uint8).max
            );
        }
    }
}
