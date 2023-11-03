// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TickMathPrecision} from "src/libraries/TickMathPrecision.sol";
import {ABDKMathQuad} from "abdk/ABDKMathQuad.sol";

contract TickMathPrecisionTest is Test {
    using ABDKMathQuad for bytes16;

    bytes16 immutable LOG_2_10001;

    constructor() {
        LOG_2_10001 = ABDKMathQuad.fromUInt(10001).div(ABDKMathQuad.fromUInt(10000)).log_2();
    }

    function testFuzz_getRatioAtTick(uint64 tickX42Uint) public {
        int64 tickX42 = int64(int256(bound(tickX42Uint, 0, uint64(TickMathPrecision.MAX_TICK_X42))));

        (bool OF, uint128 ratioX64) = TickMathPrecision.getRatioAtTick(tickX42);

        assertTrue(!OF);

        /** 1.0001^tickX42 = 2^(tickX42 * log_2(1.0001))
            computed using the ABDKMath64x64 library
         */
        uint256 ratioX64Bis = ABDKMathQuad
            .fromInt(tickX42)
            .div(ABDKMathQuad.fromUInt(1 << 42))
            .mul(LOG_2_10001)
            .pow_2()
            .mul(ABDKMathQuad.fromUInt(1 << 64))
            .toUInt();

        assertApproxEqRel(ratioX64, ratioX64Bis, 1);
        assertLe(ratioX64, ratioX64Bis, "Not rounding down");
    }

    function testFuzz_getRatioAtTickOneBitActive(uint8 tickX42ActiveBit) public {
        tickX42ActiveBit = uint8(bound(tickX42ActiveBit, 0, 60)); // Because 2^60 < MAX_TICK_X42 and 2^61 > MAX_TICK_X42
        int64 tickX42 = int64(int256(1 << tickX42ActiveBit));

        (bool OF, uint128 ratioX64) = TickMathPrecision.getRatioAtTick(tickX42);

        assertTrue(!OF);

        /** 1.0001^tickX42 = 2^(tickX42 * log_2(1.0001))
            computed using the ABDKMath64x64 library
         */
        uint256 ratioX64Bis = ABDKMathQuad
            .fromInt(tickX42)
            .div(ABDKMathQuad.fromUInt(1 << 42))
            .mul(LOG_2_10001)
            .pow_2()
            .mul(ABDKMathQuad.fromUInt(1 << 64))
            .toUInt();

        assertApproxEqAbs(ratioX64, ratioX64Bis, 2); // We found out that ABDKMathQuad can result in ±2 error
    }

    function testFuzz_getRatioAtTickOverflows(uint64 tickX42Uint) public {
        int64 tickX42 = int64(
            int256(bound(tickX42Uint, uint64(TickMathPrecision.MAX_TICK_X42) + 1, uint64(type(int64).max)))
        );

        (bool OF, ) = TickMathPrecision.getRatioAtTick(tickX42);

        assertTrue(OF);
    }

    function testFuzz_getTickAtRatio(uint256 num, uint256 den) public {
        // console.log("num: %d, den: %d", num, den);
        vm.assume(den > 0);
        num = bound(num, den, type(uint256).max);

        int64 tickX42 = TickMathPrecision.getTickAtRatio(num, den);

        int64 tickX42Bis = int64(
            ABDKMathQuad
                .fromUInt(num)
                .div(ABDKMathQuad.fromUInt(den))
                .log_2()
                .div(LOG_2_10001)
                .mul(ABDKMathQuad.fromUInt(1 << 42))
                .toInt()
        );

        assertApproxEqAbs(tickX42, tickX42Bis, 1);
        assertLe(tickX42, tickX42Bis, "Not rounding down");
    }

    function testFuzz_getTickAtRatioWrongNumerator(uint256 num, uint256 den) public {
        vm.assume(den > 0);
        num = bound(num, 0, den - 1);

        vm.expectRevert();
        TickMathPrecision.getTickAtRatio(num, den);
    }

    function testFuzz_getTickAtRatioWrongDenominator(uint256 num) public {
        uint256 den = 0;
        num = bound(num, den, type(uint256).max);

        vm.expectRevert();
        TickMathPrecision.getTickAtRatio(num, den);
    }
}
