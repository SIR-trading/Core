// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {Fees} from "src/libraries/Fees.sol";
import {FullMath} from "src/libraries/FullMath.sol";

contract FeesTest is Test {
    function testFuzz_FeeAPE(uint152 collateralDepositedOrOut, uint16 baseFee, int8 leverageTier, uint8 tax) public {
        // Constraint leverageTier to supported values
        leverageTier = int8(_bound(leverageTier, -3, 2));

        (uint152 collateralInOrWidthdrawn, uint152 treasuryFee, uint152 lpersFee, uint152 polFee) = Fees.hiddenFeeAPE(
            collateralDepositedOrOut,
            baseFee,
            leverageTier,
            tax
        );

        uint256 totalFee = uint256(treasuryFee) + lpersFee + polFee;

        assertEq(collateralInOrWidthdrawn + totalFee, collateralDepositedOrOut, "wrong collateral + fee");

        uint256 totalFeeLowerBound;
        uint256 totalFeeUpperBound;
        if (leverageTier >= 0) {
            totalFeeLowerBound = FullMath.mulDiv(
                collateralInOrWidthdrawn,
                uint256(baseFee) * 2 ** uint8(leverageTier),
                10000
            );
            totalFeeUpperBound = FullMath.mulDivRoundingUp(
                collateralInOrWidthdrawn + (collateralInOrWidthdrawn == type(uint152).max ? 0 : 1),
                uint256(baseFee) * 2 ** uint8(leverageTier),
                10000
            );
        } else {
            totalFeeLowerBound = FullMath.mulDiv(collateralInOrWidthdrawn, baseFee, 10000 * 2 ** uint8(-leverageTier));
            totalFeeUpperBound = FullMath.mulDivRoundingUp(
                collateralInOrWidthdrawn + (collateralInOrWidthdrawn == type(uint152).max ? 0 : 1),
                baseFee,
                10000 * 2 ** uint8(-leverageTier)
            );
        }

        assertLe(totalFeeLowerBound, totalFee, "Total fee too low");
        assertGe(totalFeeUpperBound, totalFee, "Total fee too high");
    }

    function testFuzz_FeeTEA(uint152 collateralDepositedOrOut, uint16 lpFee, uint8 tax) public {
        (uint152 collateralInOrWidthdrawn, uint152 treasuryFee, uint152 lpersFee, uint152 polFee) = Fees.hiddenFeeTEA(
            collateralDepositedOrOut,
            lpFee,
            tax
        );

        uint256 totalFee = uint256(treasuryFee) + lpersFee + polFee;

        assertEq(collateralInOrWidthdrawn + totalFee, collateralDepositedOrOut, "wrong collateral + fee");

        uint256 totalFeeLowerBound = FullMath.mulDiv(collateralInOrWidthdrawn, lpFee, 10000);
        uint256 totalFeeUpperBound = FullMath.mulDivRoundingUp(
            collateralInOrWidthdrawn + (collateralInOrWidthdrawn == type(uint152).max ? 0 : 1),
            lpFee,
            10000
        );

        assertLe(totalFeeLowerBound, totalFee, "Total fee too low");
        assertGe(totalFeeUpperBound, totalFee, "Total fee too high");
    }
}
