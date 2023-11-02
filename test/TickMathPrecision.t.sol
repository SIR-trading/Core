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
        console.log("tickX42Uint: %d", tickX42Uint);
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
    }
}
