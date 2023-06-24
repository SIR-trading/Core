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

    function testFuzz_fromInt_boundedRoundingError(int256 x) public {
        vm.assume(x != int256(type(int256).min));

        uint256 xAbs = uint256(x < 0 ? -x : x);
        bool xSgn = x >= 0;

        uint totalBits = _bitLength(xAbs);
        uint lostBits = totalBits > 113 ? totalBits - 113 : 0;

        int256 xLB = int256((xAbs >> lostBits) << lostBits);
        int256 xUB = xLB + int256(2 ** lostBits - 1);
        if (!xSgn) {
            xLB = -xLB;
            xUB = -xUB;
        }

        assertEq(FloatingPoint.fromInt(x), FloatingPoint.fromInt(xLB));
        assertEq(FloatingPoint.fromInt(x), FloatingPoint.fromInt(xUB));
    }

    function testFuzz_fromUInt_boundedRoundingError(uint256 x) public {
        uint totalBits = _bitLength(x);
        uint lostBits = totalBits > 113 ? totalBits - 113 : 0;

        uint xLB = (x >> lostBits) << lostBits;
        uint xUB;
        unchecked {
            xUB = xLB + 2 ** lostBits - 1;
        }
        assertEq(FloatingPoint.fromUInt(x), FloatingPoint.fromUInt(xLB));
        assertEq(FloatingPoint.fromUInt(x), FloatingPoint.fromUInt(xUB));
    }

    function testFuzz_fromUIntUp_boundedRoundingError(uint256 x) public {
        uint totalBits = _bitLength(x);
        uint lostBits = totalBits > 113 ? totalBits - 113 : 0;

        uint xLB = ((x >> lostBits) << lostBits) + 1;
        uint xUB = xLB + 2 ** lostBits;

        assertEq(FloatingPoint.fromUInt(x), FloatingPoint.fromUInt(xLB));
        assertEq(FloatingPoint.fromUInt(x), FloatingPoint.fromUInt(xUB));
        // CHECK NUMBERS THAT DO NOT MATCH
        // BETTER WAY TO ROUND UP?
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
