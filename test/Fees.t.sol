pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {Fees, FullMath} from "src/libraries/Fees.sol";

contract FeesContract {
    function publicHiddenFee(
        Fees.FeesParameters memory feesParams
    )
        public
        pure
        returns (uint256 collateralDepositedOrWithdrawn, uint256 comission)
    {
        return Fees._hiddenFee(feesParams);
    }
}

contract FeesTest is Test {
    FeesContract fees;
    uint8 constant basisFee = 100; // 1%

    function setUp() public {
        fees = new FeesContract();
    }

    function test_FullFeeWhenMintingFirst() public {
        uint256 collateralIn = 10 ** 18;
        uint256 reserveGentlemen = 0;
        uint256 reserveApes = 0;
        int8 collateralizationRatioTier = 0;

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: true,
            collateralInOrOut: collateralIn,
            reserveSyntheticToken: reserveGentlemen,
            reserveOtherToken: reserveApes,
            collateralizationOrLeverageTier: collateralizationRatioTier
        });

        (uint256 collateralDeposited, uint256 comission) = fees.publicHiddenFee(
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

    function testFuzz_NoFeeWhenMintingTEA(
        uint256 collateralIn,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 collateralizationRatioTier
    ) public {
        // Make sure not too much collateral is deposited
        uint256 idealReserveGentlemen = _idealReserveGentlemen(
            reserveApes,
            collateralizationRatioTier
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
            collateralizationOrLeverageTier: collateralizationRatioTier
        });

        (uint256 collateralDeposited, uint256 comission) = fees.publicHiddenFee(
            feesParams
        );

        assertEq(
            collateralIn,
            collateralDeposited,
            "collateral deposited is less than collateral in"
        );

        assertEq(comission, 0, "comission is not zero");
    }

    function testFuzz_FullFeeWhenMintingTEA(
        uint256 collateralIn,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 collateralizationRatioTier // int8 to limit the range of tiers
    ) public {
        collateralIn = bound(
            collateralIn,
            0,
            type(uint256).max - reserveGentlemen
        );

        // Make sure the user must pay a fee
        reserveGentlemen = bound(
            reserveGentlemen,
            _idealReserveGentlemen(reserveApes, collateralizationRatioTier),
            type(uint256).max
        );

        Fees.FeesParameters memory feesParams = Fees.FeesParameters({
            basisFee: basisFee,
            isMint: true,
            collateralInOrOut: collateralIn,
            reserveSyntheticToken: reserveGentlemen,
            reserveOtherToken: reserveApes,
            collateralizationOrLeverageTier: collateralizationRatioTier
        });

        // ALSO TEST THE SAME PROCEDURE THAN THE CODE
        // USE THIS FUNCTION TO TEST PARTIAL FEE

        (uint256 collateralDeposited, uint256 comission) = fees.publicHiddenFee(
            feesParams
        );

        assertEq(
            collateralDeposited + comission,
            collateralIn,
            "collateral deposited + comission is not equal to collateral in"
        );

        uint256 comissionExpected;
        if (collateralizationRatioTier >= 0) {
            comissionExpected = FullMath.mulDivRoundingUp(
                collateralIn,
                basisFee * 2 ** uint256(int256(collateralizationRatioTier)),
                basisFee *
                    2 ** uint256(int256(collateralizationRatioTier)) +
                    10000
            );
        } else {
            comissionExpected = FullMath.mulDivRoundingUp(
                collateralIn,
                basisFee,
                basisFee +
                    10000 *
                    2 ** uint256(-int256(collateralizationRatioTier))
            );
        }

        assertEq(
            comission,
            comissionExpected,
            "comission is not equal to the expected value"
        );

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
        uint256 comissionLowerBound;
        uint256 comissionUpperBound;
        if (collateralizationRatioTier >= 0) {
            comissionLowerBound = FullMath.mulDivRoundingUp(
                collateralDeposited,
                basisFee * 2 ** uint256(int256(collateralizationRatioTier)),
                10000
            );
            comissionUpperBound = FullMath.mulDivRoundingUp(
                collateralDeposited + 1,
                basisFee * 2 ** uint256(int256(collateralizationRatioTier)),
                10000
            );
        } else {
            comissionLowerBound = FullMath.mulDivRoundingUp(
                collateralDeposited,
                basisFee,
                10000 * 2 ** uint256(-int256(collateralizationRatioTier))
            );
            comissionUpperBound = FullMath.mulDivRoundingUp(
                collateralDeposited + 1,
                basisFee,
                10000 * 2 ** uint256(-int256(collateralizationRatioTier))
            );
        }

        assertGe(comission, comissionLowerBound, "comission is too low");
        assertLe(comission, comissionUpperBound, "comission is too high");
    }

    function testFuzz_PartialFeeWhenMintingTEA(
        uint256 collateralIn,
        uint256 reserveGentlemen,
        uint256 reserveApes,
        int8 collateralizationRatioTier // int8 to limit the range of tiers
    ) public {
        collateralIn = bound(
            collateralIn,
            0,
            type(uint256).max - reserveGentlemen
        );

        // Make sure user pays a partial fee
        uint256 idealReserveGentlemen = _idealReserveGentlemen(
            reserveApes,
            collateralizationRatioTier
        );
        reserveGentlemen = bound(
            reserveGentlemen,
            idealReserveGentlemen > collateralIn
                ? idealReserveGentlemen - collateralIn
                : 0,
            idealReserveGentlemen
        );

        // Split the collateral deposited in two parts, one for which the user pays a fee and another for which the user doesn't pay a fee
        uint256 collateralInTaxFree = idealReserveGentlemen - reserveGentlemen;
        testFuzz_NoFeeWhenMintingTEA(
            collateralInTaxFree,
            reserveGentlemen,
            reserveApes,
            collateralizationRatioTier
        );
        testFuzz_FullFeeWhenMintingTEA(
            collateralIn - collateralInTaxFree,
            idealReserveGentlemen,
            reserveApes,
            collateralizationRatioTier
        );
    }

    function _idealReserveGentlemen(
        uint256 reserveApes,
        int8 collateralizationRatioTier
    ) internal pure returns (uint256 idealReserveGentlemen) {
        /**
            The maximum possible reserveGentlemen for no fee charge is reserveGentlemenMax = (l-1)reserveApes = reserveApes/(r-1),
            where l is the leverage ratio and r is the collateralization factor.
            Because r=1+2^h, where h is the collateralization tier,
            reserveGentlemenMax = reserveApes/(1+2^h-1) = reserveApes/2^h
         */
        if (collateralizationRatioTier >= 0) {
            idealReserveGentlemen =
                reserveApes /
                2 ** uint256(int256(collateralizationRatioTier));
        } else {
            unchecked {
                idealReserveGentlemen =
                    reserveApes *
                    2 ** uint256(-int256(collateralizationRatioTier));
            }
            if (
                idealReserveGentlemen /
                    2 ** uint256(-int256(collateralizationRatioTier)) !=
                reserveApes
            ) idealReserveGentlemen = type(uint256).max;
        }
    }
}
