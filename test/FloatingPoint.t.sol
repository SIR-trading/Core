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

    function testFuzz_toUIntFromUInt(uint x) public {
        uint totalBits = _bitLength(x);
        uint lostBits = totalBits > 113 ? totalBits - 113 : 0;

        uint xApprox = FloatingPoint.toUInt(FloatingPoint.fromUInt(x));

        assertEq(xApprox, (x >> lostBits) << lostBits);
    }

    function testFuzz_toUIntFromInt(int x) public {
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

    function testFuzz_toUIntFromNaN(uint128 xFP) public {
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

    function test_toUIntFromInfinity() public {
        vm.expectRevert();
        FloatingPoint.toUInt(INFINITY);
        vm.expectRevert();
        FloatingPoint.toUInt(NEGATIVE_INFINITY);
    }

    function testFuzz_toUIntFromSubnormals(uint128 xFP) public {
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

    /************************
        INTERNAL FUNCTIONS
     ************************/

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
