pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {Fees} from "src/libraries/Fees.sol";

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
        int8 collateralizationRatioTier // int8 to limit the range of tiers
    ) public {
        vm.assume(collateralIn <= type(uint256).max - reserveGentlemen);

        uint256 maxFreeReserveGentlemen;
        /**
            The maximum possible reserveGentlemen for no fee charge is reserveGentlemenMax = (l-1)reserveApes = reserveApes/(r-1),
            where l is the leverage ratio and r is the collateralization factor.
            Because r=1+2^h, where h is the collateralization tier,
            reserveGentlemenMax = reserveApes/(1+2^h-1) = reserveApes/2^h
         */
        if (collateralizationRatioTier >= 0) {
            maxFreeReserveGentlemen =
                reserveApes /
                2 ** uint256(int256(collateralizationRatioTier));
        } else {
            emit log_string("here");
            unchecked {
                maxFreeReserveGentlemen =
                    reserveApes *
                    2 ** uint256(-int256(collateralizationRatioTier));
            }
            if (
                maxFreeReserveGentlemen /
                    2 ** uint256(-int256(collateralizationRatioTier)) !=
                reserveApes
            ) maxFreeReserveGentlemen = type(uint256).max;
            emit log_string("there");
        }

        // Make sure not too much collateral is deposited
        vm.assume(collateralIn + reserveGentlemen <= maxFreeReserveGentlemen);

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
}
