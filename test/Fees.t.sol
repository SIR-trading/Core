// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {Fees} from "src/libraries/Fees.sol";
import {FullMath} from "src/libraries/FullMath.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";

contract FeesTest is Test {
    function testFuzz_FeeAPE(uint144 collateralDepositedOrOut, uint16 baseFee, int8 leverageTier, uint8 tax) public {
        // Constraint leverageTier to supported values
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER));

        (uint144 collateralInOrWidthdrawn, uint144 treasuryFee, uint144 lpersFee, uint144 polFee) = Fees.hiddenFeeAPE(
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
                collateralInOrWidthdrawn + (collateralInOrWidthdrawn == type(uint144).max ? 0 : 1),
                uint256(baseFee) * 2 ** uint8(leverageTier),
                10000
            );
        } else {
            totalFeeLowerBound = FullMath.mulDiv(collateralInOrWidthdrawn, baseFee, 10000 * 2 ** uint8(-leverageTier));
            totalFeeUpperBound = FullMath.mulDivRoundingUp(
                collateralInOrWidthdrawn + (collateralInOrWidthdrawn == type(uint144).max ? 0 : 1),
                baseFee,
                10000 * 2 ** uint8(-leverageTier)
            );
        }

        assertLe(totalFeeLowerBound, totalFee, "Total fee too low");
        assertGe(totalFeeUpperBound, totalFee, "Total fee too high");
        assertEq(treasuryFee, (uint256(totalFee) * tax) / (uint256(10) * type(uint8).max), "Treasury fee incorrect");
        assertEq(polFee, totalFee / 10, "LPers fee incorrect");
    }

    function testFuzz_FeeTEA(uint144 collateralDepositedOrOut, uint16 lpFee, uint8 tax) public {
        (uint144 collateralInOrWidthdrawn, uint144 treasuryFee, uint144 lpersFee, uint144 polFee) = Fees.hiddenFeeTEA(
            collateralDepositedOrOut,
            lpFee,
            tax
        );

        uint256 totalFee = uint256(treasuryFee) + lpersFee + polFee;

        assertEq(collateralInOrWidthdrawn + totalFee, collateralDepositedOrOut, "wrong collateral + fee");

        uint256 totalFeeLowerBound = FullMath.mulDiv(collateralInOrWidthdrawn, lpFee, 10000);
        uint256 totalFeeUpperBound = FullMath.mulDivRoundingUp(
            collateralInOrWidthdrawn + (collateralInOrWidthdrawn == type(uint144).max ? 0 : 1),
            lpFee,
            10000
        );

        assertLe(totalFeeLowerBound, totalFee, "Total fee too low");
        assertGe(totalFeeUpperBound, totalFee, "Total fee too high");
        assertEq(treasuryFee, (uint256(totalFee) * tax) / (uint256(10) * type(uint8).max), "Treasury fee incorrect");
        assertEq(polFee, totalFee / 10, "LPers fee incorrect");
    }
}
