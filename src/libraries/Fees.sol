// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VaultStructs} from "./VaultStructs.sol";

/**
 * @notice	Smart contract for computing fees in SIR.
 */

/**
    In 3 months, ETH remained flat while SQUEETH lost -16%. Without fees and volatility decay, SQUEETH should also have remained flat.
    Compounding the fees for 4 times, we get (1-0.16)^(1 year/3 months) = 50% lost over a year with a flat price a 2x.
    This computation has to be done on flat prices, because when the price moves, SQUEETH has to overpay shorters to stay short.
    In SIR the LPers take the loss gitwhen the market moves against them, and viceversa.
    This implies a baseFee = 100% for 2x constant leverage. At 1.2x, fee = 20%.

    Gentleman Sandwitch Attack:

    An MEV attacker could mint TEA before an ape makes its deposit and burn the TEA immediately after, pocketing the fees minus the LP fee of minting/burning.
    This way the LPer avoids any negative impact from price fluctuations.
    We are assuming that the ape is not depositing more than L/(l-1) collateral, where L is the LP reserve and l is the leverage because it wants
    the system to operate in the power zone.

    1) The gentlman sandwitch attacker mints a TEA depositing y collateral, but after fees only y'=y/(lpFee+1) makes it.
    2) The ape deposits, including the fee, the maximum it can assuming we stay in the power zone is L/(l-1), and its fee is L/(l-1)*(l-1)baseFee
       The gentlman's TEA after the ape's mint is now worth y''=y'+y'/(y+L)*L*baseFee. y''/y' is maximized for y' small, simplyfing we get y''≈y'(1+baseFee).
    3) The gentlemen finally pays the exit fee upon burning, pocketing y'''=y''/(1+lpFee)=y(1+baseFee)/(lpFee+1)^2.

    So, if we wish to make the sandwitch attack irrelevant, y''' ≤ y, and therefore (lpFee+1)^2 ≥ baseFee+1.
*/

library Fees {
    function hiddenFeeAPE(
        uint144 collateralDepositedOrOut,
        uint16 baseFee,
        int256 leverageTier,
        uint8 tax
    ) internal pure returns (VaultStructs.Fees memory fees) {
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

            // Split collateralDepositedOrOut into fee and collateralInOrWithdrawn
            fees.collateralInOrWithdrawn = uint144((uint256(collateralDepositedOrOut) * feeNum) / feeDen);
            uint256 totalFees = collateralDepositedOrOut - fees.collateralInOrWithdrawn;

            // Depending on the tax, between 0 and 10% of the fee is for SIR stakers
            fees.collateralFeeToStakers = uint144((totalFees * tax) / (10 * uint256(type(uint8).max))); // Cannot overflow cuz fee is uint144 and tax is uint8

            // 10% of the fee is becomes protocol owned liquidity (POL)
            fees.collateralFeeToProtocol = uint144(totalFees) / 10;

            // The rest of the fee is sent to the LPers
            fees.collateralFeeToGentlemen =
                uint144(totalFees) -
                fees.collateralFeeToStakers -
                fees.collateralFeeToProtocol;
        }
    }

    function hiddenFeeTEA(
        uint144 collateralDepositedOrOut,
        uint16 lpFee,
        uint8 tax
    ) internal pure returns (VaultStructs.Fees memory fees) {
        unchecked {
            uint256 feeNum = 10000;
            uint256 feeDen = 10000 + uint256(lpFee);

            // Split collateralDepositedOrOut into fee and collateralInOrWithdrawn
            fees.collateralInOrWithdrawn = uint144((uint256(collateralDepositedOrOut) * feeNum) / feeDen);
            uint256 totalFees = collateralDepositedOrOut - fees.collateralInOrWithdrawn;

            // Depending on the tax, between 0 and 10% of the fee is for SIR stakers
            fees.collateralFeeToStakers = uint144((totalFees * tax) / (10 * uint256(type(uint8).max))); // Cannot overflow cuz fee is uint144 and tax is uint8

            // 10% of the fee is becomes protocol owned liquidity (POL)
            fees.collateralFeeToProtocol = uint144(totalFees) / 10;

            // The rest of the fee is sent to the LPers
            fees.collateralFeeToGentlemen =
                uint144(totalFees) -
                fees.collateralFeeToStakers -
                fees.collateralFeeToProtocol;
        }
    }
}
