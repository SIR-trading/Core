// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {Fees, FullMath} from "src/libraries/Fees.sol";

contract FeesTest is Test {
    uint8 constant basisFee = 100; // 1%

    /*********************
        MINT TEA TESTS
     *********************/

    function test_mintTEA_fullFeeWhenFirst() public {
        uint256 collateralIn = 10 ** 18;
        uint256 reserveGentlemen = 0;
        uint256 reserveApes = 0;
        int8 collateralizationTier = 0;

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: true,
            collateralInOrOut: collateralIn,
            reserveSyntheticToken: reserveGentlemen,
            reserveOtherToken: reserveApes,
            collateralizationOrLeverageTier: collateralizationTier
        });

        (uint256 collateralDeposited, uint256 comission) = Fees._hiddenFee(
            feesParams
        );

        uint256 expectedComission = (collateralDeposited * basisFee - 1) /
            10000 +
            1;

        assertEq(comission, expectedComission, "comission is wrong");

        assertEq(
            collateralDeposited + comission,
            collateralIn,
            "collateral deposited + comission is not equal to collateral in"
        );
    }

    function testFuzz_mintTEA_noFee(
        uint256 collateralIn,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 collateralizationTier
    ) public {
        // Make sure not too much collateral is deposited
        uint256 idealReserveGentlemen = _idealReserveGentlemen(
            reserveApes,
            collateralizationTier
        );
        reserveGentlemen = bound(reserveGentlemen, 0, idealReserveGentlemen);
        collateralIn = bound(
            collateralIn,
            0,
            idealReserveGentlemen - reserveGentlemen
        );

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: true,
            collateralInOrOut: collateralIn,
            reserveSyntheticToken: reserveGentlemen,
            reserveOtherToken: reserveApes,
            collateralizationOrLeverageTier: collateralizationTier
        });

        (uint256 collateralDeposited, uint256 comission) = Fees._hiddenFee(
            feesParams
        );

        assertEq(
            collateralIn,
            collateralDeposited,
            "collateral deposited is less than collateral in"
        );

        assertEq(comission, 0, "comission is not zero");
    }

    function testFuzz_mintTEA_fullFee(
        uint256 collateralIn,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 collateralizationTier // int8 to limit the range of tiers
    ) public {
        // Make sure the user must pay a fee
        reserveGentlemen = bound(
            reserveGentlemen,
            _idealReserveGentlemen(reserveApes, collateralizationTier),
            type(uint256).max
        );

        // Total supply of collateral cannot overflow uint256
        collateralIn = bound(
            collateralIn,
            0,
            type(uint256).max - reserveGentlemen
        );

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: true,
            collateralInOrOut: collateralIn,
            reserveSyntheticToken: reserveGentlemen,
            reserveOtherToken: reserveApes,
            collateralizationOrLeverageTier: collateralizationTier
        });

        (uint256 collateralDeposited, uint256 comission) = Fees._hiddenFee(
            feesParams
        );

        assertEq(
            collateralDeposited + comission,
            collateralIn,
            "collateral deposited + comission is not equal to collateral in"
        );

        assertEq(
            comission,
            _comissionExpectedForTEA(collateralIn, collateralizationTier),
            "comission is not equal to the expected value"
        );

        (
            uint256 comissionLowerBound,
            uint256 comissionUpperBound
        ) = _comissionBoundsForTEA(collateralDeposited, collateralizationTier);

        assertGe(comission, comissionLowerBound, "comission is too low");
        assertLe(comission, comissionUpperBound, "comission is too high");
    }

    function testFuzz_mintTEA_partialFee(
        uint256 collateralIn,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 collateralizationTier // int8 to limit the range of tiers
    ) public {
        // Make sure user pays a partial fee
        uint256 idealReserveGentlemen = _idealReserveGentlemen(
            reserveApes,
            collateralizationTier
        );
        vm.assume(
            idealReserveGentlemen != 0 &&
                idealReserveGentlemen != type(uint256).max
        );
        reserveGentlemen = bound(
            reserveGentlemen,
            0,
            idealReserveGentlemen - 1
        );

        // Total supply of collateral cannot overflow uint256
        collateralIn = bound(
            collateralIn,
            0,
            type(uint256).max - reserveGentlemen
        );

        // Make sure the user pays a fee
        vm.assume(collateralIn + reserveGentlemen > idealReserveGentlemen);

        // Split the collateral deposited in two parts, one for which the user pays a fee and another for which the user doesn't pay a fee
        uint256 collateralInTaxFree = idealReserveGentlemen - reserveGentlemen;
        testFuzz_mintTEA_noFee(
            collateralInTaxFree,
            reserveGentlemen,
            reserveApes,
            collateralizationTier
        );
        testFuzz_mintTEA_fullFee(
            collateralIn - collateralInTaxFree,
            idealReserveGentlemen,
            reserveApes,
            collateralizationTier
        );
    }

    /*********************
        MINT APE TESTS
     *********************/

    function test_mintAPE_fullFee() public {
        uint256 collateralIn = 10 ** 18;
        uint256 reserveGentlemen = 0;
        uint256 reserveApes = 0;
        int8 leverageTier = 0;

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: true,
            collateralInOrOut: collateralIn,
            reserveSyntheticToken: reserveApes,
            reserveOtherToken: reserveGentlemen,
            collateralizationOrLeverageTier: leverageTier
        });

        (uint256 collateralDeposited, uint256 comission) = Fees._hiddenFee(
            feesParams
        );

        uint256 expectedComission = (collateralDeposited * basisFee - 1) /
            10000 +
            1;

        assertEq(comission, expectedComission, "comission is wrong");

        assertEq(
            collateralDeposited + comission,
            collateralIn,
            "collateral deposited + comission is not equal to collateral in"
        );
    }

    function testFuzz_mintAPE_noFee(
        uint256 collateralIn,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 leverageTier
    ) public {
        // Make sure not too much collateral is deposited
        uint256 idealReserveApes = _idealReserveApes(
            reserveGentlemen,
            leverageTier
        );
        reserveApes = bound(reserveApes, 0, idealReserveApes);
        collateralIn = bound(collateralIn, 0, idealReserveApes - reserveApes);

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: true,
            collateralInOrOut: collateralIn,
            reserveSyntheticToken: reserveApes,
            reserveOtherToken: reserveGentlemen,
            collateralizationOrLeverageTier: leverageTier
        });

        (uint256 collateralDeposited, uint256 comission) = Fees._hiddenFee(
            feesParams
        );

        assertEq(
            collateralIn,
            collateralDeposited,
            "collateral deposited is less than collateral in"
        );

        assertEq(comission, 0, "comission is not zero");
    }

    function testFuzz_mintAPE_fullFee(
        uint256 collateralIn,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 leverageTier
    ) public {
        // Make sure the user must pay a fee
        reserveApes = bound(
            reserveApes,
            _idealReserveApes(reserveGentlemen, leverageTier),
            type(uint256).max
        );

        // Total supply of collateral cannot overflow uint256
        collateralIn = bound(collateralIn, 0, type(uint256).max - reserveApes);

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: true,
            collateralInOrOut: collateralIn,
            reserveSyntheticToken: reserveApes,
            reserveOtherToken: reserveGentlemen,
            collateralizationOrLeverageTier: leverageTier
        });

        (uint256 collateralDeposited, uint256 comission) = Fees._hiddenFee(
            feesParams
        );

        assertEq(
            collateralDeposited + comission,
            collateralIn,
            "collateral deposited + comission is not equal to collateral in"
        );

        assertEq(
            comission,
            _comissionExpectedForAPE(collateralIn, leverageTier),
            "comission is not equal to the expected value"
        );

        (
            uint256 comissionLowerBound,
            uint256 comissionUpperBound
        ) = _comissionBoundsForAPE(collateralDeposited, leverageTier);

        assertGe(comission, comissionLowerBound, "comission is too low");
        assertLe(comission, comissionUpperBound, "comission is too high");
    }

    function testFuzz_mintAPE_partialFee(
        uint256 collateralIn,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 leverageTier // int8 to limit the range of tiers
    ) public {
        // Make sure user pays a partial fee
        uint256 idealReserveApes = _idealReserveApes(
            reserveGentlemen,
            leverageTier
        );
        vm.assume(
            idealReserveApes != 0 && idealReserveApes != type(uint256).max
        );
        reserveApes = bound(reserveApes, 0, idealReserveApes - 1);

        // Total supply of collateral cannot overflow uint256
        collateralIn = bound(collateralIn, 0, type(uint256).max - reserveApes);

        // Make sure the user pays a fee
        vm.assume(collateralIn + reserveApes > idealReserveApes);

        // Split the collateral deposited in two parts, one for which the user pays a fee and another for which the user doesn't pay a fee
        uint256 collateralInTaxFree = idealReserveApes - reserveApes;
        testFuzz_mintAPE_noFee(
            collateralInTaxFree,
            reserveGentlemen,
            reserveApes,
            leverageTier
        );
        testFuzz_mintAPE_fullFee(
            collateralIn - collateralInTaxFree,
            idealReserveApes,
            reserveApes,
            leverageTier
        );
    }

    /*********************
        BURN TEA TESTS
     *********************/

    function testFuzz_burnTEA_noFee(
        uint256 collateralOut,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 collateralizationTier
    ) public {
        // Make sure not too much collateral is deposited
        uint256 idealReserveGentlemen = _idealReserveGentlemen(
            reserveApes,
            collateralizationTier
        );
        reserveGentlemen = bound(
            reserveGentlemen,
            idealReserveGentlemen,
            type(uint256).max
        );
        collateralOut = bound(
            collateralOut,
            0,
            reserveGentlemen - idealReserveGentlemen
        );

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: false,
            collateralInOrOut: collateralOut,
            reserveSyntheticToken: reserveGentlemen,
            reserveOtherToken: reserveApes,
            collateralizationOrLeverageTier: collateralizationTier
        });

        (uint256 collateralWithdrawn, uint256 comission) = Fees._hiddenFee(
            feesParams
        );

        assertEq(
            collateralOut,
            collateralWithdrawn,
            "collateral deposited is less than collateral in"
        );

        assertEq(comission, 0, "comission is not zero");
    }

    function testFuzz_burnTEA_fullFee(
        uint256 collateralOut,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 collateralizationTier // int8 to limit the range of tiers
    ) public {
        // Make sure the user must pay a fee
        reserveGentlemen = bound(
            reserveGentlemen,
            0,
            _idealReserveGentlemen(reserveApes, collateralizationTier)
        );

        collateralOut = bound(collateralOut, 0, reserveGentlemen);

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: false,
            collateralInOrOut: collateralOut,
            reserveSyntheticToken: reserveGentlemen,
            reserveOtherToken: reserveApes,
            collateralizationOrLeverageTier: collateralizationTier
        });

        (uint256 collateralWithdrawn, uint256 comission) = Fees._hiddenFee(
            feesParams
        );

        assertEq(
            collateralWithdrawn + comission,
            collateralOut,
            "collateral deposited + comission is not equal to collateral in"
        );

        assertEq(
            comission,
            _comissionExpectedForTEA(collateralOut, collateralizationTier),
            "comission is not equal to the expected value"
        );

        (
            uint256 comissionLowerBound,
            uint256 comissionUpperBound
        ) = _comissionBoundsForTEA(collateralWithdrawn, collateralizationTier);

        assertGe(comission, comissionLowerBound, "comission is too low");
        assertLe(comission, comissionUpperBound, "comission is too high");
    }

    function testFuzz_burnTEA_partialFee(
        uint256 collateralOut,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 collateralizationTier
    ) public {
        // Make sure user pays a partial fee
        uint256 idealReserveGentlemen = _idealReserveGentlemen(
            reserveApes,
            collateralizationTier
        );
        vm.assume(
            idealReserveGentlemen != 0 &&
                idealReserveGentlemen != type(uint256).max
        );
        reserveGentlemen = bound(
            reserveGentlemen,
            idealReserveGentlemen + 1,
            type(uint256).max
        );

        // Cannot remove more collateral than available in the reserve
        collateralOut = bound(collateralOut, 0, reserveGentlemen);

        // Make sure the user pays a fee
        vm.assume(reserveGentlemen - collateralOut < idealReserveGentlemen);

        // Split the collateral deposited in two parts, one for which the user pays a fee and another for which the user doesn't pay a fee
        uint256 collateralOutTaxFree = reserveGentlemen - idealReserveGentlemen;
        testFuzz_burnTEA_noFee(
            collateralOutTaxFree,
            reserveGentlemen,
            reserveApes,
            collateralizationTier
        );
        testFuzz_burnTEA_fullFee(
            collateralOut - collateralOutTaxFree,
            idealReserveGentlemen,
            reserveApes,
            collateralizationTier
        );
    }

    /*********************
        BURN APE TESTS
     *********************/

    function testFuzz_burnAPE_noFee(
        uint256 collateralOut,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 leverageTier
    ) public {
        // Make sure not too much collateral is deposited
        uint256 idealReserveApes = _idealReserveApes(
            reserveGentlemen,
            leverageTier
        );
        reserveApes = bound(reserveApes, idealReserveApes, type(uint256).max);
        collateralOut = bound(collateralOut, 0, reserveApes - idealReserveApes);

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: false,
            collateralInOrOut: collateralOut,
            reserveSyntheticToken: reserveApes,
            reserveOtherToken: reserveGentlemen,
            collateralizationOrLeverageTier: leverageTier
        });

        (uint256 collateralWithdrawn, uint256 comission) = Fees._hiddenFee(
            feesParams
        );

        assertEq(
            collateralOut,
            collateralWithdrawn,
            "collateral deposited is less than collateral in"
        );

        assertEq(comission, 0, "comission is not zero");
    }

    function testFuzz_burnAPE_fullFee(
        uint256 collateralOut,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 leverageTier // int8 to limit the range of tiers
    ) public {
        // Make sure the user must pay a fee
        reserveApes = bound(
            reserveApes,
            0,
            _idealReserveApes(reserveGentlemen, leverageTier)
        );

        collateralOut = bound(collateralOut, 0, reserveApes);

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: false,
            collateralInOrOut: collateralOut,
            reserveSyntheticToken: reserveApes,
            reserveOtherToken: reserveGentlemen,
            collateralizationOrLeverageTier: leverageTier
        });

        (uint256 collateralWithdrawn, uint256 comission) = Fees._hiddenFee(
            feesParams
        );

        assertEq(
            collateralWithdrawn + comission,
            collateralOut,
            "collateral deposited + comission is not equal to collateral in"
        );

        assertEq(
            comission,
            _comissionExpectedForAPE(collateralOut, leverageTier),
            "comission is not equal to the expected value"
        );

        (
            uint256 comissionLowerBound,
            uint256 comissionUpperBound
        ) = _comissionBoundsForAPE(collateralWithdrawn, leverageTier);

        assertGe(comission, comissionLowerBound, "comission is too low");
        assertLe(comission, comissionUpperBound, "comission is too high");
    }

    function testFuzz_burnAPE_partialFee(
        uint256 collateralOut,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 leverageTier
    ) public {
        // Make sure user pays a partial fee
        uint256 idealReserveApes = _idealReserveApes(
            reserveGentlemen,
            leverageTier
        );
        vm.assume(
            idealReserveApes != 0 && idealReserveApes != type(uint256).max
        );
        reserveApes = bound(
            reserveApes,
            idealReserveApes + 1,
            type(uint256).max
        );

        // Cannot remove more collateral than available in the reserve
        collateralOut = bound(collateralOut, 0, reserveApes);

        // Make sure the user pays a fee
        vm.assume(reserveApes - collateralOut < idealReserveApes);

        // Split the collateral deposited in two parts, one for which the user pays a fee and another for which the user doesn't pay a fee
        uint256 collateralOutTaxFree = reserveApes - idealReserveApes;
        testFuzz_burnAPE_noFee(
            collateralOutTaxFree,
            reserveGentlemen,
            reserveApes,
            leverageTier
        );
        testFuzz_burnAPE_fullFee(
            collateralOut - collateralOutTaxFree,
            idealReserveApes,
            reserveApes,
            leverageTier
        );
    }

    /************************
        INTERNAL FUNCTIONS
     ************************/

    function _idealReserveGentlemen(
        uint256 reserveApes,
        int8 collateralizationTier
    ) internal pure returns (uint256 idealReserveGentlemen) {
        /**
            The maximum possible reserveGentlemen for no fee charge is reserveGentlemenMax = (l-1)reserveApes = reserveApes/(r-1),
            where l is the leverage ratio and r is the collateralization factor.
            Because r=1+2^h, where h is the collateralization tier,
            reserveGentlemenMax = reserveApes/(1+2^h-1) = reserveApes/2^h
         */
        if (collateralizationTier >= 0) {
            idealReserveGentlemen =
                reserveApes /
                2 ** uint256(int256(collateralizationTier));
        } else {
            unchecked {
                idealReserveGentlemen =
                    reserveApes *
                    2 ** uint256(-int256(collateralizationTier));
            }
            if (
                idealReserveGentlemen /
                    2 ** uint256(-int256(collateralizationTier)) !=
                reserveApes
            ) idealReserveGentlemen = type(uint256).max;
        }
    }

    function _idealReserveApes(
        uint256 reserveGentlemen,
        int8 leverageTier
    ) internal pure returns (uint256 idealReserveApes) {
        /**
            The maximum possible reserveApes for no fee charge is reserveApesMax = (r-1)reserveGentlemen = reserveGentlemen/(l-1),
            where l is the leverage ratio and r is the collateralization factor.
            Because l=1+2^k, where k is the collateralization tier,
            reserveApesMax = reserveGentlemen/(1+2^k-1) = reserveGentlemen/2^k
         */
        if (leverageTier >= 0) {
            idealReserveApes =
                reserveGentlemen /
                2 ** uint256(int256(leverageTier));
        } else {
            unchecked {
                idealReserveApes =
                    reserveGentlemen *
                    2 ** uint256(-int256(leverageTier));
            }
            if (
                idealReserveApes / 2 ** uint256(-int256(leverageTier)) !=
                reserveGentlemen
            ) idealReserveApes = type(uint256).max;
        }
    }

    function _comissionExpectedForTEA(
        uint256 collateralInOrOut,
        int8 collateralizationTier
    ) internal pure returns (uint256 comissionExpected) {
        if (collateralizationTier >= 0) {
            comissionExpected = FullMath.mulDivRoundingUp(
                collateralInOrOut,
                basisFee * 2 ** uint256(int256(collateralizationTier)),
                basisFee * 2 ** uint256(int256(collateralizationTier)) + 10000
            );
        } else {
            comissionExpected = FullMath.mulDivRoundingUp(
                collateralInOrOut,
                basisFee,
                basisFee + 10000 * 2 ** uint256(-int256(collateralizationTier))
            );
        }
    }

    function _comissionExpectedForAPE(
        uint256 collateralInOrOut,
        int8 leverageTier
    ) internal pure returns (uint256 comissionExpected) {
        if (leverageTier >= 0) {
            comissionExpected = FullMath.mulDivRoundingUp(
                collateralInOrOut,
                basisFee * 2 ** uint256(int256(leverageTier)),
                basisFee * 2 ** uint256(int256(leverageTier)) + 10000
            );
        } else {
            comissionExpected = FullMath.mulDivRoundingUp(
                collateralInOrOut,
                basisFee,
                basisFee + 10000 * 2 ** uint256(-int256(leverageTier))
            );
        }
    }

    function _comissionBoundsForTEA(
        uint256 collateralDepositedOrWithdrawn,
        int8 collateralizationTier
    )
        internal
        pure
        returns (uint256 comissionLowerBound, uint256 comissionUpperBound)
    {
        /**
            Let x be the collaretal sent by the user minting TEA, y the collateral actually deposited in the pool and z the comission.
            Then, x = y + z, but because of rounding errors the real amounts are x = y_ + z‾ where
                y_ = y - ε, z‾ = z + ε and ε is the rounding error such that 0 ≤ ε < 1.
            We know the that y and z are related through the fee equation as z = (r-1)*f*y, where r is the collateralization factor and f is the basis fee.
            Thus, z‾ = (r-1)*f*(y_+ε)+ε, and therefore,
                z‾ ∈ [ (r-1)*f*y_ , (r-1)*f*(y_+1)+1 )
            Because we know z‾ is an integer (rounded), we can simplify the expression to
                z‾ ∈ [ zLB , zUB ] where
                    zLB = ceil((r-1)*f*y_)
                    zUB = ceil((r-1)*f*(y_+1))
         */
        if (collateralizationTier >= 0) {
            comissionLowerBound = FullMath.mulDivRoundingUp(
                collateralDepositedOrWithdrawn,
                basisFee * 2 ** uint256(int256(collateralizationTier)),
                10000
            );
            comissionUpperBound = FullMath.mulDivRoundingUp(
                collateralDepositedOrWithdrawn + 1,
                basisFee * 2 ** uint256(int256(collateralizationTier)),
                10000
            );
        } else {
            comissionLowerBound = FullMath.mulDivRoundingUp(
                collateralDepositedOrWithdrawn,
                basisFee,
                10000 * 2 ** uint256(-int256(collateralizationTier))
            );
            comissionUpperBound = FullMath.mulDivRoundingUp(
                collateralDepositedOrWithdrawn + 1,
                basisFee,
                10000 * 2 ** uint256(-int256(collateralizationTier))
            );
        }
    }

    function _comissionBoundsForAPE(
        uint256 collateralDepositedOrWithdrawn,
        int8 leverageTier
    )
        internal
        pure
        returns (uint256 comissionLowerBound, uint256 comissionUpperBound)
    {
        if (leverageTier >= 0) {
            comissionLowerBound = FullMath.mulDivRoundingUp(
                collateralDepositedOrWithdrawn,
                basisFee * 2 ** uint256(int256(leverageTier)),
                10000
            );
            comissionUpperBound = FullMath.mulDivRoundingUp(
                collateralDepositedOrWithdrawn + 1,
                basisFee * 2 ** uint256(int256(leverageTier)),
                10000
            );
        } else {
            comissionLowerBound = FullMath.mulDivRoundingUp(
                collateralDepositedOrWithdrawn,
                basisFee,
                10000 * 2 ** uint256(-int256(leverageTier))
            );
            comissionUpperBound = FullMath.mulDivRoundingUp(
                collateralDepositedOrWithdrawn + 1,
                basisFee,
                10000 * 2 ** uint256(-int256(leverageTier))
            );
        }
    }
}
