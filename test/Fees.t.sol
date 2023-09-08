// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {Fees} from "src/libraries/Fees.sol";
import {FullMath} from "src/libraries/FullMath.sol";
import {ABDKMath64x64} from "abdk/ABDKMath64x64.sol";

contract FeesTest is Test {
    using ABDKMath64x64 for int128;

    /*********************
        MINT TESTS
     *********************/

    function testFuzz_APE(uint16 baseFee, uint152 collateralAmount, int8 leverageTier) public {
        // Constraint leverageTier to supported values
        leverageTier = int8(bound(leverageTier, -3, 2));

        (uint152 collateralFeeFree, uint152 comission) = Fees.hiddenFee(baseFee, collateralAmount, leverageTier);

        assertEq(
            collateralFeeFree + comission,
            collateralAmount,
            "collateral deposited + comission is not equal to collateral in"
        );

        uint256 comissionLowerBound;
        uint256 comissionUpperBound;
        if (leverageTier >= 0) {
            comissionLowerBound = FullMath.mulDiv(collateralFeeFree, uint256(baseFee) << uint8(leverageTier), 10000);
            comissionUpperBound = FullMath.mulDivRoundingUp(
                collateralFeeFree < type(uint152).max ? collateralFeeFree + 1 : collateralFeeFree,
                uint256(baseFee) << uint8(leverageTier),
                10000
            );
        } else {
            comissionLowerBound = FullMath.mulDiv(collateralFeeFree, baseFee, 10000 << uint8(-leverageTier));
            comissionUpperBound = FullMath.mulDivRoundingUp(
                collateralFeeFree < type(uint152).max ? collateralFeeFree + 1 : collateralFeeFree,
                baseFee,
                10000 << uint8(-leverageTier)
            );
        }

        assertLe(comissionLowerBound, comission, "Fee computation is not correct");
        assertGe(comissionUpperBound, comission, "Fee computation is not correct");
    }

    function testFuzz_TEA(uint8 lpFee, uint152 collateralAmount) public {
        (uint152 collateralFeeFree, uint152 comission) = Fees.hiddenFee(lpFee, collateralAmount, 0);

        assertEq(
            collateralFeeFree + comission,
            collateralAmount,
            "collateral deposited + comission is not equal to collateral in"
        );

        uint256 comissionLowerBound;
        uint256 comissionUpperBound;
        comissionLowerBound = FullMath.mulDiv(collateralFeeFree, lpFee, 10000);
        comissionUpperBound = FullMath.mulDivRoundingUp(
            collateralFeeFree < type(uint152).max ? collateralFeeFree + 1 : collateralFeeFree,
            lpFee,
            10000
        );

        assertLe(comissionLowerBound, comission, "Fee computation is not correct");
        assertGe(comissionUpperBound, comission, "Fee computation is not correct");
    }
}
