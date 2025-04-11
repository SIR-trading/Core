// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Fees, SirStructs} from "src/libraries/Fees.sol";
import {FullMath} from "src/libraries/FullMath.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";

import "forge-std/Test.sol";

contract FeesTest is Test {
    function testFuzz_feeAPE(
        uint144 collateralDepositedOrOut,
        uint16 baseFee,
        int8 leverageTier,
        uint8 tax
    ) public pure {
        // Constraint leverageTier to supported values
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER));

        SirStructs.Fees memory fees = Fees.feeAPE(collateralDepositedOrOut, baseFee, leverageTier, tax);

        uint256 totalFee = uint256(fees.collateralFeeToStakers) + fees.collateralFeeToLPers;
        assertEq(fees.collateralInOrWithdrawn + totalFee, collateralDepositedOrOut, "wrong collateral + fee");

        uint256 totalFeeLowerBound;
        uint256 totalFeeUpperBound;
        if (leverageTier >= 0) {
            totalFeeLowerBound = FullMath.mulDiv(
                fees.collateralInOrWithdrawn,
                uint256(baseFee) * 2 ** uint8(leverageTier),
                10000
            );
            totalFeeUpperBound = FullMath.mulDivRoundingUp(
                fees.collateralInOrWithdrawn + (fees.collateralInOrWithdrawn == type(uint144).max ? 0 : 1),
                uint256(baseFee) * 2 ** uint8(leverageTier),
                10000
            );
        } else {
            totalFeeLowerBound = FullMath.mulDiv(
                fees.collateralInOrWithdrawn,
                baseFee,
                10000 * 2 ** uint8(-leverageTier)
            );
            totalFeeUpperBound = FullMath.mulDivRoundingUp(
                fees.collateralInOrWithdrawn + (fees.collateralInOrWithdrawn == type(uint144).max ? 0 : 1),
                baseFee,
                10000 * 2 ** uint8(-leverageTier)
            );
        }

        assertLe(totalFeeLowerBound, totalFee, "Total fee too low");
        assertGe(totalFeeUpperBound, totalFee, "Total fee too high");
        assertEq(
            fees.collateralFeeToStakers,
            (uint256(totalFee) * tax) / (uint256(20) * type(uint8).max),
            "Stakers fee incorrect"
        );
        assertEq(fees.collateralFeeToLPers, totalFee - fees.collateralFeeToStakers, "LPers fee incorrect");
    }

    function testFuzz_feeMintTEA(uint144 collateralDeposited, uint16 lpFee) public pure {
        SirStructs.Fees memory fees = Fees.feeMintTEA(collateralDeposited, lpFee);

        uint256 totalFee = uint256(fees.collateralFeeToStakers) + fees.collateralFeeToLPers;

        assertEq(fees.collateralInOrWithdrawn + totalFee, collateralDeposited, "wrong collateral + fee");

        uint256 totalFeeLowerBound = FullMath.mulDiv(fees.collateralInOrWithdrawn, lpFee, 10000);
        uint256 totalFeeUpperBound = FullMath.mulDivRoundingUp(
            fees.collateralInOrWithdrawn + (fees.collateralInOrWithdrawn == type(uint144).max ? 0 : 1),
            lpFee,
            10000
        );

        assertLe(totalFeeLowerBound, totalFee, "Total fee too low");
        assertGe(totalFeeUpperBound, totalFee, "Total fee too high");
        assertEq(fees.collateralFeeToStakers, 0);
        assertEq(fees.collateralFeeToLPers, totalFee);
    }
}
