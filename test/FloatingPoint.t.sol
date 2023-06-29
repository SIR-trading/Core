// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {FloatingPoint} from "src/libraries/FloatingPoint.sol";

contract FloatingPointTest is Test {
    bytes16 internal constant ONE = 0x3FFF0000000000000000000000000000;
    bytes16 internal constant ZERO = 0x00000000000000000000000000000000;
    bytes16 internal constant INFINITY = 0x7FFF0000000000000000000000000000;

    bytes16 internal constant QUASI_ONE_FP = 0x3ffeffffffffffffffffffffffffffff;
    bytes16 internal constant TAT_LG_ONE_FP =
        0x3fff0000000000000000000000000001;
    bytes16 internal constant MAX_FP = 0x7ffeffffffffffffffffffffffffffff;
    bytes16 internal constant MIN_FP = 0x00010000000000000000000000000000;

    bytes16 private constant NEGATIVE_ZERO = 0x80000000000000000000000000000000;
    bytes16 private constant NEGATIVE_INFINITY =
        0xFFFF0000000000000000000000000000;
    bytes16 private constant NaN = 0x7FFF8000000000000000000000000000;

    function testFuzz_fromInt(int256 x) public {
        vm.assume(x != int256(type(int256).min));

        uint256 xAbs = uint256(x < 0 ? -x : x);
        bool xSgn = x >= 0;

        uint totalBits = _bitLength(xAbs);
        uint lostBits = totalBits > 113 ? totalBits - 113 : 0;

        int256 xLB = int256((xAbs >> lostBits) << lostBits);
        int256 xUB;
        unchecked {
            xUB = int256((((xAbs >> lostBits) + 1) << lostBits) - 1);
        }
        if (!xSgn) {
            (xLB, xUB) = (-xUB, -xLB);
        }

        bytes16 xFP = FloatingPoint.fromInt(x);

        assertEq(xFP, FloatingPoint.fromInt(xLB));
        if (xLB != type(int256).min)
            assertTrue(xFP != FloatingPoint.fromInt(xLB - 1), "xLB - 1");
        assertEq(xFP, FloatingPoint.fromInt(xUB));
        if (xUB != type(int256).max)
            assertTrue(xFP != FloatingPoint.fromInt(xUB + 1), "xUB + 1");
    }

    function testFuzz_fromUInt(uint256 x) public {
        uint totalBits = _bitLength(x);
        uint lostBits = totalBits > 113 ? totalBits - 113 : 0;

        uint xLB = (x >> lostBits) << lostBits;
        uint xUB;
        unchecked {
            xUB = (((x >> lostBits) + 1) << lostBits) - 1;
        }

        bytes16 xFP = FloatingPoint.fromUInt(x);

        assertEq(xFP, FloatingPoint.fromUInt(xLB));
        if (xLB != type(uint256).min)
            assertTrue(xFP != FloatingPoint.fromUInt(xLB - 1), "xLB - 1");
        assertEq(xFP, FloatingPoint.fromUInt(xUB));
        if (xUB != type(uint256).max)
            assertTrue(xFP != FloatingPoint.fromUInt(xUB + 1), "xUB + 1");
    }

    function testFuzz_fromUIntUp(uint256 x) public {
        uint totalBits = _bitLength(x);
        uint lostBits = totalBits > 113 ? totalBits - 113 : 0;

        uint xLB;
        uint xUB;
        if (x != 0) {
            if (lostBits == 0) xLB = x;
            else if (x == 2 ** (totalBits - 1))
                xLB = (((x - 1) >> (lostBits - 1)) << (lostBits - 1)) + 1;
            else xLB = (((x - 1) >> lostBits) << lostBits) + 1;

            unchecked {
                xUB = ((((x - 1) >> lostBits) + 1) << lostBits);
            }
            if (xUB < xLB) xUB = type(uint256).max;
        } else {
            xLB = 0;
            xUB = 0;
        }

        bytes16 xFP = FloatingPoint.fromUIntUp(x);

        assertEq(xFP, FloatingPoint.fromUIntUp(xLB), "xLB");
        if (xLB != type(uint256).min)
            assertTrue(xFP != FloatingPoint.fromUIntUp(xLB - 1), "xLB - 1");
        assertEq(xFP, FloatingPoint.fromUIntUp(xUB), "xUB");
        if (xUB != type(uint256).max)
            assertTrue(xFP != FloatingPoint.fromUIntUp(xUB + 1), "xUB + 1");
    }

    function testFuzz_toUInt_fromUInt(uint x) public {
        uint xApprox = FloatingPoint.toUInt(FloatingPoint.fromUInt(x));

        assertEq(xApprox, _precission113Bits(x));
    }

    function testFuzz_toUInt_fromInt(int x) public {
        bytes16 xFP = FloatingPoint.fromInt(x);
        if (x < 0) {
            vm.expectRevert();
            FloatingPoint.toUInt(xFP);
        } else {
            uint totalBits = _bitLength(uint(x));
            uint lostBits = totalBits > 113 ? totalBits - 113 : 0;

            uint xApprox = FloatingPoint.toUInt(xFP);
            assertEq(xApprox, (uint(x) >> lostBits) << lostBits);
        }
    }

    function testFuzz_toUInt_fromNaN(uint128 xFP) public {
        xFP = uint128(
            bound(
                uint(xFP),
                uint(uint128(NaN)),
                uint(0x7FFFffffffffffffffffffffffffffff)
            )
        );
        vm.expectRevert();
        FloatingPoint.toUInt(bytes16(xFP));

        vm.expectRevert();
        xFP |= 0x80000000000000000000000000000000; // Negative NaN
        FloatingPoint.toUInt(bytes16(xFP));
    }

    function test_toUInt_fromInfinity() public {
        vm.expectRevert();
        FloatingPoint.toUInt(INFINITY);
        vm.expectRevert();
        FloatingPoint.toUInt(NEGATIVE_INFINITY);
    }

    function testFuzz_toUInt_fromSubnormals(uint128 xFP) public {
        xFP = uint128(
            bound(
                uint(xFP),
                uint(0x00000000000000000000000000000001),
                uint(0x0000ffffffffffffffffffffffffffff)
            )
        );
        vm.expectRevert();
        FloatingPoint.toUInt(bytes16(xFP));
    }

    function testFuzz_sign_uint(uint x) public {
        bytes16 xFP = FloatingPoint.fromUInt(x);
        if (x == 0) assertEq(FloatingPoint.sign(xFP), 0);
        else assertEq(FloatingPoint.sign(xFP), 1);

        xFP = FloatingPoint.fromUIntUp(x);
        if (x == 0) assertEq(FloatingPoint.sign(xFP), 0);
        else assertEq(FloatingPoint.sign(xFP), 1);
    }

    function testFuzz_sign_int(int x) public {
        bytes16 xFP = FloatingPoint.fromInt(x);
        if (x == 0) assertEq(FloatingPoint.sign(xFP), 0);
        else if (x > 0) assertEq(FloatingPoint.sign(xFP), 1);
        else assertEq(FloatingPoint.sign(xFP), -1);
    }

    function testFuzz_sign_positiveFloatingPointNumbers(uint128 xFP) public {
        xFP = uint128(
            bound(
                uint(xFP),
                uint(0x00000000000000000000000000000001),
                uint(0x7fffffffffffffffffffffffffffffff)
            )
        );
        assertEq(FloatingPoint.sign(bytes16(xFP)), 1);
    }

    function testFuzz_sign_negativeFloatingPointNumbers(uint128 xFP) public {
        xFP = uint128(
            bound(
                uint(xFP),
                uint(0x80000000000000000000000000000001),
                uint(0xFfffffffffffffffffffffffffffffff)
            )
        );
        assertEq(FloatingPoint.sign(bytes16(xFP)), -1);
    }

    function testFuzz_cmp_uint(uint128 x, uint128 y) public {
        x = uint128(_precission113Bits(x));
        y = uint128(_precission113Bits(y));

        assertEq(
            FloatingPoint.cmp(
                FloatingPoint.fromUInt(x),
                FloatingPoint.fromUInt(y)
            ),
            x == y ? int8(0) : x < y ? -1 : int8(1)
        );
    }

    function testFuzz_cmp_int(int128 x, int128 y) public {
        x = int128(_precission113Bits(x));
        y = int128(_precission113Bits(y));

        assertEq(
            FloatingPoint.cmp(
                FloatingPoint.fromInt(x),
                FloatingPoint.fromInt(y)
            ),
            x == y ? int8(0) : x < y ? -1 : int8(1)
        );
    }

    function testFuzz_cmp_fp(uint128 xFP, uint128 yFP) public {
        if (
            xFP & uint128(0x7fffffffffffffffffffffffffffffff) >= uint128(NaN) ||
            yFP & uint128(0x7fffffffffffffffffffffffffffffff) >= uint128(NaN) ||
            (xFP == uint128(INFINITY) && yFP == uint128(INFINITY)) ||
            (xFP == uint128(NEGATIVE_INFINITY) &&
                yFP == uint128(NEGATIVE_INFINITY))
        ) {
            vm.expectRevert();
            FloatingPoint.cmp(bytes16(xFP), bytes16(yFP));
        } else {
            int8 res;
            if (
                FloatingPoint.sign(bytes16(xFP)) >
                FloatingPoint.sign(bytes16(yFP))
            ) {
                res = int8(1);
            } else if (
                FloatingPoint.sign(bytes16(xFP)) <
                FloatingPoint.sign(bytes16(yFP))
            ) {
                res = int8(-1);
            } else if (FloatingPoint.sign(bytes16(xFP)) >= 0) {
                res = xFP > yFP ? int8(1) : xFP < yFP ? int8(-1) : int8(0);
            } else {
                res = xFP > yFP ? int8(-1) : xFP < yFP ? int8(1) : int8(0);
            }
            assertEq(FloatingPoint.cmp(bytes16(xFP), bytes16(yFP)), res);
        }
    }

    /************************
        INTERNAL FUNCTIONS
     ************************/

    function _precission113Bits(uint256 x) internal pure returns (uint256) {
        uint256 bits = _bitLength(x);
        if (bits > 113) {
            uint256 lostBits = bits - 113;
            return (x >> lostBits) << lostBits;
        } else {
            return x;
        }
    }

    function _precission113Bits(int256 x) internal pure returns (int256) {
        unchecked {
            uint256 ux = uint256(x < 0 ? -x : x); // Taking advantage of OF here
            uint256 xPrecission = _precission113Bits(ux);
            return x < 0 ? -int256(xPrecission) : int256(xPrecission);
        }
    }

    function _bitLength(uint256 x) internal pure returns (uint256) {
        uint256 bits = 0;
        while (x >> bits > 0) {
            bits++;
        }
        return bits;
    }

    function _bitLength(int x) public pure returns (uint256) {
        unchecked {
            uint256 ux = uint256(x < 0 ? -x : x); // Taking advantage of OF here
            return _bitLength(ux);
        }
    }
}
