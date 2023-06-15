// SPDX-License-Identifier: BSD-4-Clause

import "./FullMath.sol";

/**
 * @notice This a modified version of ABDK Math Quad Smart Contract Library
 *     by Mikhail Vladimirov <mikhail.vladimirov@gmail.com> found at https://github.com/abdk-consulting/abdk-libraries-solidity/blob/master/ABDKMathQuad.md
 * 
 *     @dev Sub-normals are REMOVED for all functions because they add extra complexity for negligible gain.
 *     @dev Negative numbers are REMOVED, except for fromInt() and  mul() whose 1st parameter is allowed to be negative.
 *     @dev NaN & -INFINITY are REMOVED. Functions only output positive numbers, INFINITY or revert().
 *     @dev Only function that can output INFINITY is div and only under the condition that the denominator is 0
 *     @dev It is the duty of the caller to ensure the functions do not overflow. This is done because the calling functions should never overflow during operation.
 */
pragma solidity ^0.8.0;

/**
 * TO REDUCE BYTECODE, I COULD USE MULDIV AND MULMUL FOR MUL AND DIV OPERATIONS!!
 */
library FloatingPoint {
    bytes16 internal constant ONE = 0x3FFF0000000000000000000000000000;
    bytes16 internal constant ZERO = 0x00000000000000000000000000000000;
    bytes16 internal constant INFINITY = 0x7FFF0000000000000000000000000000;

    /**
     * @notice Convert signed 256-bit integer number into quadruple precision number.
     *     @notice Rounds towards zero
     * 
     *     @param x Unsigned 256-bit integer number
     *     @return Quadruple precision number
     */
    function fromInt(int256 x) internal pure returns (bytes16) {
        unchecked {
            if (x == 0) return bytes16(0);

            // We rely on overflow behavior here
            uint256 result = uint256(x > 0 ? x : -x);
            result = _fromUInt(result, false);
            if (x < 0) result |= 0x80000000000000000000000000000000;

            return bytes16(uint128(result));
        }
    }

    /**
     * @notice Convert unsigned 256-bit integer number into quadruple precision number.
     *     @notice Rounds down
     * 
     *     @param x Unsigned 256-bit integer number
     *     @return Quadruple precision positive number
     */
    function fromUInt(uint256 x) internal pure returns (bytes16) {
        unchecked {
            if (x == 0) return bytes16(0);
            return bytes16(uint128(_fromUInt(x, false)));
        }
    }

    /**
     * @notice Convert unsigned 256-bit integer number into quadruple precision number.
     *     @notice Rounds up
     * 
     *     @param x Unsigned 256-bit integer number
     *     @return Quadruple precision positive number
     */
    function fromUIntUp(uint256 x) internal pure returns (bytes16) {
        unchecked {
            if (x == 0) return bytes16(0);
            return bytes16(uint128(_fromUInt(x, true)));
        }
    }

    function _fromUInt(uint256 result, bool roundUp) private pure returns (uint256) {
        unchecked {
            uint256 msb = mostSignificantBit(result);
            if (msb < 112) {
                result <<= 112 - msb;
            } // No approximation error
            else if (msb > 112) {
                if (roundUp) {
                    // Round UP
                    result = ((result - 1) >> (msb - 112)) + 1;
                    if (result == 2 ** 113) msb++;
                } else {
                    result >>= msb - 112;
                }
            }

            return (result & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | ((16383 + msb) << 112);
        }
    }

    /**
     * @notice Convert quadruple precision number into unsigned 256-bit integer number
     *     @notice Rounds down
     * 
     *     @param x Quadruple precision number
     *     @return Unsigned 256-bit integer number. Reverts on overflow.
     */
    function toUInt(bytes16 x) internal pure returns (uint256) {
        unchecked {
            uint256 exponent = uint128(x) >> 112;

            assert(exponent <= 0x40FE); // No OF or NEGATIVE
            assert(exponent > 0 || x == ZERO); // No SUBNORMALS

            if (exponent < 16383) return 0; // Underflow

            uint256 result = (uint256(uint128(x)) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;

            if (exponent < 16495) result >>= 16495 - exponent;
            else if (exponent > 16495) result <<= exponent - 16495;

            return result;
        }
    }

    /**
     * @notice Calculate sign of x, i.e. -1 if x is negative, 0 if x if zero, and 1 if x is positive.
     * 
     *     @param x Quadruple precision number
     *     @return Sign of x
     */
    function sign(bytes16 x) internal pure returns (int8) {
        unchecked {
            uint128 absoluteX = uint128(x) & 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

            if (absoluteX == 0) return 0;
            if (uint128(x) >= 0x80000000000000000000000000000000) return -1;
            return 1;
        }
    }

    /**
     * @notice Calculate sign (x - y). 
     *     @notice Revert if both arguments are infinities.
     * 
     *     @param x Quadruple precision number
     *     @param y Quadruple precision number
     *     @return sign (x - y)
     */
    function cmp(bytes16 x, bytes16 y) internal pure returns (int8) {
        unchecked {
            uint128 absoluteX = uint128(x) & 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
            uint128 absoluteY = uint128(y) & 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

            require(absoluteX <= 0x7FFF0000000000000000000000000000); // Not NaN
            require(absoluteY <= 0x7FFF0000000000000000000000000000); // Not NaN
            require(x != y || absoluteX < 0x7FFF0000000000000000000000000000); // Not infinities of the same sign

            if (x == y) return 0;

            bool negativeX = uint128(x) >= 0x80000000000000000000000000000000;
            bool negativeY = uint128(y) >= 0x80000000000000000000000000000000;

            if (negativeX) {
                if (negativeY) return absoluteX > absoluteY ? -1 : int8(1);
                else return -1;
            } else {
                if (negativeY) return 1;
                else return absoluteX > absoluteY ? int8(1) : -1;
            }
        }
    }

    /**
     * @notice Calculate x + y.
     *     @notice Caller must ensure no OF
     *     @notice Rounds down
     * 
     *     @param x quadruple precision positive number
     *     @param y Quadruple precision positive number
     *     @return Quadruple precision positive number
     */
    function add(bytes16 x, bytes16 y) internal pure returns (bytes16) {
        return _add(x, y, false);
    }

    /**
     * @notice Calculate x + y.
     *     @notice Caller must ensure no OF
     *     @notice Rounds up
     * 
     *     @param x quadruple precision positive number
     *     @param y Quadruple precision positive number
     *     @return Quadruple precision positive number
     */
    function addUp(bytes16 x, bytes16 y) internal pure returns (bytes16) {
        return _add(x, y, true);
    }

    function _add(bytes16 x, bytes16 y, bool roundUp) private pure returns (bytes16) {
        unchecked {
            uint256 xExponent = uint128(x) >> 112;
            uint256 yExponent = uint128(y) >> 112;
            assert(xExponent < 0x7FFF && yExponent < 0x7FFF); // No INF & no NEG

            if (x == ZERO) return y;
            if (y == ZERO) return x;

            uint256 xSignifier = (uint128(x) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;
            uint256 ySignifier = (uint128(y) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;

            assert(xExponent > 0 && yExponent > 0); // No SUBNORMALS

            int256 delta = int256(xExponent) - int256(yExponent);

            if (roundUp) {
                if (delta > 112) {
                    ySignifier = 1;
                } // Round up
                else if (delta > 0) {
                    ySignifier = ((ySignifier - 1) >> uint256(delta)) + 1;
                } // Round up
                else if (delta < -112) {
                    xSignifier = 1; // Round up
                    xExponent = yExponent;
                } else if (delta < 0) {
                    xSignifier = ((xSignifier - 1) >> uint256(-delta)) + 1; // Round up
                    xExponent = yExponent;
                }
            } else {
                if (delta > 112) {
                    return x;
                } else if (delta > 0) {
                    ySignifier >>= uint256(delta);
                } else if (delta < -112) {
                    return y;
                } else if (delta < 0) {
                    xSignifier >>= uint256(-delta);
                    xExponent = yExponent;
                }
            }

            xSignifier += ySignifier;

            if (xSignifier >= 0x20000000000000000000000000000) {
                xSignifier = roundUp ? ((xSignifier - 1) >> 1) + 1 : xSignifier >> 1;
                xExponent++;
            }

            assert(xExponent < 0x7FFF);

            if (xSignifier < 0x10000000000000000000000000000) xExponent = 0;
            else xSignifier &= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

            return bytes16(uint128((xExponent << 112) | xSignifier));
        }
    }

    /**
     * @notice Calculate x + 1.
     *     @notice Caller must ensure no OF
     * 
     *     @param x quadruple precision positive number
     *     @return Quadruple precision positive number
     */
    function inc(bytes16 x) internal pure returns (bytes16) {
        return _add(x, ONE, false);
    }

    /**
     * @notice Calculate x - y.
     *     @notice Caller must ensure no OF
     *     @notice Revert on UF
     *     @notice Rounds down
     * 
     *     @param x quadruple precision positive number
     *     @param y Quadruple precision positive number
     *     @return Quadruple precision positive number
     */
    function sub(bytes16 x, bytes16 y) internal pure returns (bytes16) {
        return _sub(x, y, false);
    }

    /**
     * @notice Calculate x - y.
     *     @notice Caller must ensure no OF
     *     @notice Revert on UF
     *     @notice Rounds up
     * 
     *     @param x quadruple precision positive number
     *     @param y Quadruple precision positive number
     *     @return Quadruple precision positive number
     */
    function subUp(bytes16 x, bytes16 y) internal pure returns (bytes16) {
        return _sub(x, y, true);
    }

    /**
     * @notice Calculate x - 1.
     *     @notice Revert on UF
     * 
     *     @param x quadruple precision positive number
     *     @return Quadruple precision positive number
     */
    function dec(bytes16 x) internal pure returns (bytes16) {
        return _sub(x, ONE, false);
    }

    function _sub(bytes16 x, bytes16 y, bool roundUp) private pure returns (bytes16) {
        unchecked {
            require(cmp(x, y) >= 0);

            uint256 xExponent = uint128(x) >> 112;
            uint256 yExponent = uint128(y) >> 112;
            assert(xExponent < 0x7FFF && yExponent < 0x7FFF); // No INF & no NEG

            uint256 xSignifier = (uint128(x) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;
            uint256 ySignifier = (uint128(y) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;

            if (y == ZERO) return x;
            if (x == ZERO) revert("UF");

            assert(xExponent > 0 && yExponent > 0); // No SUBNORMALS

            uint256 delta = xExponent - yExponent;

            if (roundUp) {
                if (delta > 112) return x;
                if (delta > 0) ySignifier >>= uint256(delta);
            } else {
                if (delta > 0) {
                    xSignifier <<= 1;
                    xExponent -= 1;
                }

                // The next 2 lines of code ensures sub() rounds the result down (towards 0)
                if (delta > 112) ySignifier = 1;
                else if (delta > 1) ySignifier = ((ySignifier - 1) >> (delta - 1)) + 1;
            }

            xSignifier -= ySignifier;

            if (xSignifier == 0) return ZERO;

            uint256 msb = mostSignificantBit(xSignifier);

            if (!roundUp && msb == 113) {
                xSignifier = (xSignifier >> 1) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
                xExponent += 1;
            } else if (msb < 112) {
                uint256 shift = 112 - msb;
                if (xExponent > shift) {
                    xSignifier = (xSignifier << shift) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
                    xExponent -= shift;
                } else {
                    revert("UF");
                }
            } else {
                xSignifier &= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
            }

            assert(xExponent != 0x7FFF);

            return bytes16(uint128((xExponent << 112) | xSignifier));
        }
    }

    /**
     * @notice Calculate x * y.
     *     @notice Caller must ensure no OF
     *     @notice Rounds towards 0
     * 
     *     @param x Quadruple precision number
     *     @param y Quadruple precision positive number
     *     @return Quadruple precision number
     */
    function mul(bytes16 x, bytes16 y) internal pure returns (bytes16) {
        return _mul(x, y, false);
    }

    /**
     * @notice Calculate x * y.
     *     @notice Caller must ensure no OF
     *     @notice Rounds towards 0
     * 
     *     @param x Quadruple precision number
     *     @param y Quadruple precision positive number
     *     @return Quadruple precision number
     */
    function mulUp(bytes16 x, bytes16 y) internal pure returns (bytes16) {
        assert(sign(x) >= 0);
        return _mul(x, y, true);
    }

    function _mul(bytes16 x, bytes16 y, bool roundUp) private pure returns (bytes16) {
        unchecked {
            uint256 xExponent = (uint128(x) >> 112) & 0x7FFF;
            uint256 yExponent = uint128(y) >> 112;
            assert(xExponent < 0x7FFF && yExponent < 0x7FFF); // No INF (& no NEG for y)

            if (x == ZERO || y == ZERO) return ZERO;

            uint256 xSignifier = (uint128(x) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;
            uint256 ySignifier = (uint128(y) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;

            assert(xExponent > 0 && yExponent > 0); // No SUBNORMALS

            xSignifier *= ySignifier;
            xExponent += yExponent;

            uint256 msb = xSignifier >= 0x200000000000000000000000000000000000000000000000000000000 ? 225 : 224;

            if (xExponent + msb < 16608) return ZERO;
            if (roundUp) {
                xSignifier = ((xSignifier - 1) >> (msb - 112)) + 1;
                if (xSignifier >= 0x20000000000000000000000000000) {
                    xSignifier >>= 1;
                    xExponent++;
                }
            } else {
                xSignifier >>= (msb - 112);
            }

            assert(xExponent + msb <= 49373);
            xSignifier &= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

            xExponent = xExponent + msb - 16607;

            return bytes16(uint128(uint128(x & 0x80000000000000000000000000000000) | (xExponent << 112) | xSignifier));
        }
    }

    /**
     * @notice Calculate x / y.
     *     @notice Caller must ensure no x / inf or inf / y or x / 0 does NOT occur
     *     @notice However, in the case of x / y where y is very small and it OF, it returns INFINITY
     *     @notice Rounds down
     * 
     *     @param x Quadruple precision positive number
     *     @param y Quadruple precision positive number
     *     @return Quadruple precision positive number
     */
    function div(bytes16 x, bytes16 y) internal pure returns (bytes16) {
        unchecked {
            uint256 xExponent = uint128(x) >> 112;
            uint256 xSignifier =
                (uint256(uint128(x) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000) << 113;

            uint256 yExponent = uint128(y) >> 112;
            uint256 ySignifier = (uint128(y) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;

            assert(xExponent < 0x7FFF && yExponent < 0x7FFF); // No INF & no NEG
            assert(yExponent > 0); // No SUBNORMALS & no 0

            if (x == ZERO) return ZERO;

            assert(xExponent > 0); // No SUBNORMALS

            xSignifier /= ySignifier;

            assert(xSignifier >= 0x1000000000000000000000000000 && xSignifier < 0x40000000000000000000000000000);

            uint256 msb = xSignifier >= 0x20000000000000000000000000000 ? 113 : 112;

            if (xExponent + msb > yExponent + 16496) return INFINITY;
            if (xExponent + msb + 16270 <= yExponent) return ZERO;

            // Normal
            if (msb > 112) xSignifier >>= (msb - 112);

            xSignifier &= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

            xExponent += msb + 16270 - yExponent;

            return bytes16(uint128((xExponent << 112) | xSignifier));
        }
    }

    /**
     * @notice Calculate 1/x.
     *     @notice Rounds down
     * 
     *     @param x Quadruple precision positive number
     *     @return Quadruple precision positive number
     */
    function inv(bytes16 x) internal pure returns (bytes16) {
        return div(ONE, x);
    }

    /**
     * @notice Computes x * y
     *     @notice Caller must ensure no OF
     *     @notice Rounds down
     * 
     *     @param x Quadruple precision positive number
     *     @param y Unsigned integer
     *     @return Unsigned integer
     */
    function mulu(bytes16 x, uint256 y) internal pure returns (uint256) {
        return _mulDiv(x, y, ONE);
    }

    /**
     * @notice Calculate x * y / z.
     *     @notice Caller must ensure x ≤ z
     *     @notice Rounds down
     *     @notice mulDiv() is better than splitting the * & / operation because it does not degrade the precision.
     * 
     *     @param x Quadruple precision positive number
     *     @param y Unsigned 256-bit integer 
     *     @param z Quadruple precision positive number
     *     @return Unsigned 256-bit integer
     */
    function mulDiv(bytes16 x, uint256 y, bytes16 z) internal pure returns (uint256) {
        assert(cmp(z, x) >= 0);
        return _mulDiv(x, y, z);
    }

    function _mulDiv(bytes16 x, uint256 y, bytes16 z) private pure returns (uint256) {
        unchecked {
            uint256 xExponent = uint128(x) >> 112;
            uint256 xSignifier = (uint128(x) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;

            uint256 zExponent = uint128(z) >> 112;
            uint256 zSignifier = (uint128(z) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;

            assert(xExponent < 0x7FFF && zExponent < 0x7FFF); // No INF & no NEG
            assert(zExponent > 0); // No SUBNORMALS & no 0

            if (x == ZERO || y == 0) return 0;

            assert(xExponent > 0); // No SUBNORMALS

            if (xExponent > zExponent + 143) {
                uint256 msb = mostSignificantBit(y);
                assert(msb + xExponent <= zExponent + 256); // OF
                xSignifier <<= 143;
                y <<= xExponent - zExponent - 143;
            } else if (xExponent > zExponent) {
                xSignifier <<= xExponent - zExponent;
            } else if (xExponent + 143 < zExponent) {
                uint256 msb = mostSignificantBit(y);
                if (msb + xExponent + 1 < zExponent) return 0;
                zSignifier <<= 143;
                return FullMath.mulDiv(xSignifier, y, zSignifier) >> (zExponent - xExponent - 143);
            } else if (xExponent < zExponent) {
                zSignifier <<= zExponent - xExponent;
            }

            return FullMath.mulDiv(xSignifier, y, zSignifier);
        }
    }

    /**
     * @notice Computes x / y
     *     @notice Caller must ensure no OF
     *     @notice Rounds down
     * 
     *     @param x Unsigned integer
     *     @param y Unsigned integer
     *     @return Quadruple precision positive number
     */
    function divu(uint256 x, uint256 y) internal pure returns (bytes16) {
        return _mulDiv(ONE, x, y, false);
    }

    /**
     * @notice Calculate x * y / z.
     *     @notice Caller must ensure no OF
     *     @notice Rounds down
     *     @notice mulDiv() is better than splitting the * & / operation because it does not degrade the precision.
     * 
     *     @param x Quadruple precision positive number
     *     @param y Unsigned 256-bit integer 
     *     @param z Unsigned 256-bit integer
     *     @return Quadruple precision positive number
     */
    function mulDivu(bytes16 x, uint256 y, uint256 z) internal pure returns (bytes16) {
        return _mulDiv(x, y, z, false);
    }

    /**
     * @notice Calculate x * y / z.
     *     @notice Caller must ensure no OF
     *     @notice Rounds up
     *     @notice mulDiv() is better than splitting the * & / operation because it does not degrade the precision.
     * 
     *     @param x Quadruple precision positive number
     *     @param y Unsigned 256-bit integer 
     *     @param z Unsigned 256-bit integer
     *     @return Quadruple precision positive number
     */
    function mulDivuUp(bytes16 x, uint256 y, uint256 z) internal pure returns (bytes16) {
        return _mulDiv(x, y, z, true);
    }

    function _mulDiv(bytes16 x, uint256 y, uint256 z, bool roundUp) private pure returns (bytes16) {
        unchecked {
            assert(z != 0);

            int256 xExponent = int128(uint128(x) >> 112);
            assert(xExponent < 0x7FFF); // No INF & no NEG

            if (x == ZERO || y == 0) return ZERO;
            assert(xExponent > 0); // No SUBNORMALS

            uint256 xSignifier = (uint128(x) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;

            int256 yBits = int256(mostSignificantBit(y));
            int256 zBits = int256(mostSignificantBit(z));
            if (yBits <= zBits) {
                // To ensure with end up with 113 bits of precision
                xSignifier <<= 1;
                y <<= uint256(zBits - yBits); // this makes msb(y) = msb(z), hence the bit shift cannot overflow

                xExponent += yBits - zBits - 1;
            } else if (yBits > zBits + 141) {
                // To ensure Fullmath.mulDiv()'s output fits in a uint
                int256 shift = yBits - (zBits + 141);
                y >>= uint256(shift);

                xExponent += shift;
            }

            xSignifier = roundUp ? FullMath.mulDivRoundingUp(xSignifier, y, z) : FullMath.mulDiv(xSignifier, y, z);
            if (xSignifier == 0) return ZERO;

            int256 msb = int256(mostSignificantBit(xSignifier));

            if (xExponent + msb <= 112) return ZERO;

            // Normal
            if (msb > 112) {
                if (roundUp) {
                    xSignifier = ((xSignifier - 1) >> uint256(msb - 112)) + 1;
                    if (xSignifier >= 0x20000000000000000000000000000) {
                        xSignifier >>= 1;
                        xExponent++;
                    }
                } else {
                    xSignifier = xSignifier >> uint256(msb - 112);
                }
            } else if (msb < 112) {
                xSignifier <<= uint256(112 - msb);
            }

            assert(xExponent + msb <= 112 + 2 * 16383);

            xSignifier &= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

            xExponent += msb - 112;

            return bytes16(uint128((uint256(xExponent) << 112) | xSignifier));
        }
    }

    /**
     * @notice Calculate 2^x.
     *     @notice Caller must ensure no OF
     *     @notice Rounds down
     * 
     *     @param x Quadruple precision number
     *     @return Quadruple precision positive number
     */
    function pow_2(bytes16 x) internal pure returns (bytes16) {
        unchecked {
            bool xNegative = uint128(x) > 0x80000000000000000000000000000000;
            uint256 xExponent = (uint128(x) >> 112) & 0x7FFF;
            uint256 xSignifier = (uint128(x) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;

            assert(xExponent < 16397 || xNegative);

            if (xExponent > 16397) return ZERO;
            if (xExponent < 16255) return ONE;

            if (xExponent > 16367) xSignifier <<= xExponent - 16367;
            else if (xExponent < 16367) xSignifier >>= 16367 - xExponent;

            if (xNegative && xSignifier > 0x406E00000000000000000000000000000000) return ZERO;

            uint256 resultExponent = xSignifier >> 128;
            xSignifier &= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
            if (xNegative && xSignifier != 0) {
                xSignifier = ~xSignifier;
                resultExponent += 1;
            }

            uint256 resultSignifier = 0x80000000000000000000000000000000;
            if (xSignifier & 0x80000000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x16A09E667F3BCC908B2FB1366EA957D3E) >> 128;
            }
            if (xSignifier & 0x40000000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1306FE0A31B7152DE8D5A46305C85EDEC) >> 128;
            }
            if (xSignifier & 0x20000000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1172B83C7D517ADCDF7C8C50EB14A791F) >> 128;
            }
            if (xSignifier & 0x10000000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10B5586CF9890F6298B92B71842A98363) >> 128;
            }
            if (xSignifier & 0x8000000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1059B0D31585743AE7C548EB68CA417FD) >> 128;
            }
            if (xSignifier & 0x4000000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x102C9A3E778060EE6F7CACA4F7A29BDE8) >> 128;
            }
            if (xSignifier & 0x2000000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10163DA9FB33356D84A66AE336DCDFA3F) >> 128;
            }
            if (xSignifier & 0x1000000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100B1AFA5ABCBED6129AB13EC11DC9543) >> 128;
            }
            if (xSignifier & 0x800000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10058C86DA1C09EA1FF19D294CF2F679B) >> 128;
            }
            if (xSignifier & 0x400000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1002C605E2E8CEC506D21BFC89A23A00F) >> 128;
            }
            if (xSignifier & 0x200000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100162F3904051FA128BCA9C55C31E5DF) >> 128;
            }
            if (xSignifier & 0x100000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000B175EFFDC76BA38E31671CA939725) >> 128;
            }
            if (xSignifier & 0x80000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100058BA01FB9F96D6CACD4B180917C3D) >> 128;
            }
            if (xSignifier & 0x40000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10002C5CC37DA9491D0985C348C68E7B3) >> 128;
            }
            if (xSignifier & 0x20000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000162E525EE054754457D5995292026) >> 128;
            }
            if (xSignifier & 0x10000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000B17255775C040618BF4A4ADE83FC) >> 128;
            }
            if (xSignifier & 0x8000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000058B91B5BC9AE2EED81E9B7D4CFAB) >> 128;
            }
            if (xSignifier & 0x4000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100002C5C89D5EC6CA4D7C8ACC017B7C9) >> 128;
            }
            if (xSignifier & 0x2000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000162E43F4F831060E02D839A9D16D) >> 128;
            }
            if (xSignifier & 0x1000000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000B1721BCFC99D9F890EA06911763) >> 128;
            }
            if (xSignifier & 0x800000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000058B90CF1E6D97F9CA14DBCC1628) >> 128;
            }
            if (xSignifier & 0x400000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000002C5C863B73F016468F6BAC5CA2B) >> 128;
            }
            if (xSignifier & 0x200000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000162E430E5A18F6119E3C02282A5) >> 128;
            }
            if (xSignifier & 0x100000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000B1721835514B86E6D96EFD1BFE) >> 128;
            }
            if (xSignifier & 0x80000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000058B90C0B48C6BE5DF846C5B2EF) >> 128;
            }
            if (xSignifier & 0x40000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000002C5C8601CC6B9E94213C72737A) >> 128;
            }
            if (xSignifier & 0x20000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000162E42FFF037DF38AA2B219F06) >> 128;
            }
            if (xSignifier & 0x10000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000B17217FBA9C739AA5819F44F9) >> 128;
            }
            if (xSignifier & 0x8000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000058B90BFCDEE5ACD3C1CEDC823) >> 128;
            }
            if (xSignifier & 0x4000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000002C5C85FE31F35A6A30DA1BE50) >> 128;
            }
            if (xSignifier & 0x2000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000162E42FF0999CE3541B9FFFCF) >> 128;
            }
            if (xSignifier & 0x1000000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000B17217F80F4EF5AADDA45554) >> 128;
            }
            if (xSignifier & 0x800000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000058B90BFBF8479BD5A81B51AD) >> 128;
            }
            if (xSignifier & 0x400000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000002C5C85FDF84BD62AE30A74CC) >> 128;
            }
            if (xSignifier & 0x200000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000162E42FEFB2FED257559BDAA) >> 128;
            }
            if (xSignifier & 0x100000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000B17217F7D5A7716BBA4A9AE) >> 128;
            }
            if (xSignifier & 0x80000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000058B90BFBE9DDBAC5E109CCE) >> 128;
            }
            if (xSignifier & 0x40000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000002C5C85FDF4B15DE6F17EB0D) >> 128;
            }
            if (xSignifier & 0x20000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000162E42FEFA494F1478FDE05) >> 128;
            }
            if (xSignifier & 0x10000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000B17217F7D20CF927C8E94C) >> 128;
            }
            if (xSignifier & 0x8000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000058B90BFBE8F71CB4E4B33D) >> 128;
            }
            if (xSignifier & 0x4000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000002C5C85FDF477B662B26945) >> 128;
            }
            if (xSignifier & 0x2000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000162E42FEFA3AE53369388C) >> 128;
            }
            if (xSignifier & 0x1000000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000B17217F7D1D351A389D40) >> 128;
            }
            if (xSignifier & 0x800000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000058B90BFBE8E8B2D3D4EDE) >> 128;
            }
            if (xSignifier & 0x400000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000002C5C85FDF4741BEA6E77E) >> 128;
            }
            if (xSignifier & 0x200000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000162E42FEFA39FE95583C2) >> 128;
            }
            if (xSignifier & 0x100000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000B17217F7D1CFB72B45E1) >> 128;
            }
            if (xSignifier & 0x80000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000058B90BFBE8E7CC35C3F0) >> 128;
            }
            if (xSignifier & 0x40000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000002C5C85FDF473E242EA38) >> 128;
            }
            if (xSignifier & 0x20000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000162E42FEFA39F02B772C) >> 128;
            }
            if (xSignifier & 0x10000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000B17217F7D1CF7D83C1A) >> 128;
            }
            if (xSignifier & 0x8000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000058B90BFBE8E7BDCBE2E) >> 128;
            }
            if (xSignifier & 0x4000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000002C5C85FDF473DEA871F) >> 128;
            }
            if (xSignifier & 0x2000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000162E42FEFA39EF44D91) >> 128;
            }
            if (xSignifier & 0x1000000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000B17217F7D1CF79E949) >> 128;
            }
            if (xSignifier & 0x800000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000058B90BFBE8E7BCE544) >> 128;
            }
            if (xSignifier & 0x400000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000002C5C85FDF473DE6ECA) >> 128;
            }
            if (xSignifier & 0x200000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000162E42FEFA39EF366F) >> 128;
            }
            if (xSignifier & 0x100000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000B17217F7D1CF79AFA) >> 128;
            }
            if (xSignifier & 0x80000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000058B90BFBE8E7BCD6D) >> 128;
            }
            if (xSignifier & 0x40000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000002C5C85FDF473DE6B2) >> 128;
            }
            if (xSignifier & 0x20000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000162E42FEFA39EF358) >> 128;
            }
            if (xSignifier & 0x10000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000B17217F7D1CF79AB) >> 128;
            }
            if (xSignifier & 0x8000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000058B90BFBE8E7BCD5) >> 128;
            }
            if (xSignifier & 0x4000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000002C5C85FDF473DE6A) >> 128;
            }
            if (xSignifier & 0x2000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000162E42FEFA39EF34) >> 128;
            }
            if (xSignifier & 0x1000000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000B17217F7D1CF799) >> 128;
            }
            if (xSignifier & 0x800000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000058B90BFBE8E7BCC) >> 128;
            }
            if (xSignifier & 0x400000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000002C5C85FDF473DE5) >> 128;
            }
            if (xSignifier & 0x200000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000162E42FEFA39EF2) >> 128;
            }
            if (xSignifier & 0x100000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000B17217F7D1CF78) >> 128;
            }
            if (xSignifier & 0x80000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000058B90BFBE8E7BB) >> 128;
            }
            if (xSignifier & 0x40000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000002C5C85FDF473DD) >> 128;
            }
            if (xSignifier & 0x20000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000162E42FEFA39EE) >> 128;
            }
            if (xSignifier & 0x10000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000B17217F7D1CF6) >> 128;
            }
            if (xSignifier & 0x8000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000058B90BFBE8E7A) >> 128;
            }
            if (xSignifier & 0x4000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000002C5C85FDF473C) >> 128;
            }
            if (xSignifier & 0x2000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000162E42FEFA39D) >> 128;
            }
            if (xSignifier & 0x1000000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000B17217F7D1CE) >> 128;
            }
            if (xSignifier & 0x800000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000058B90BFBE8E6) >> 128;
            }
            if (xSignifier & 0x400000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000002C5C85FDF472) >> 128;
            }
            if (xSignifier & 0x200000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000162E42FEFA38) >> 128;
            }
            if (xSignifier & 0x100000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000B17217F7D1B) >> 128;
            }
            if (xSignifier & 0x80000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000058B90BFBE8D) >> 128;
            }
            if (xSignifier & 0x40000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000002C5C85FDF46) >> 128;
            }
            if (xSignifier & 0x20000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000162E42FEFA2) >> 128;
            }
            if (xSignifier & 0x10000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000000B17217F7D0) >> 128;
            }
            if (xSignifier & 0x8000000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000058B90BFBE7) >> 128;
            }
            if (xSignifier & 0x4000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000002C5C85FDF3) >> 128;
            }
            if (xSignifier & 0x2000000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000000162E42FEF9) >> 128;
            }
            if (xSignifier & 0x1000000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000000B17217F7C) >> 128;
            }
            if (xSignifier & 0x800000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000000058B90BFBD) >> 128;
            }
            if (xSignifier & 0x400000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000002C5C85FDE) >> 128;
            }
            if (xSignifier & 0x200000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000000162E42FEE) >> 128;
            }
            if (xSignifier & 0x100000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000000B17217F6) >> 128;
            }
            if (xSignifier & 0x80000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000000058B90BFA) >> 128;
            }
            if (xSignifier & 0x40000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000000002C5C85FC) >> 128;
            }
            if (xSignifier & 0x20000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000000162E42FD) >> 128;
            }
            if (xSignifier & 0x10000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000000000B17217E) >> 128;
            }
            if (xSignifier & 0x8000000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000000058B90BE) >> 128;
            }
            if (xSignifier & 0x4000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000000002C5C85E) >> 128;
            }
            if (xSignifier & 0x2000000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000000000162E42E) >> 128;
            }
            if (xSignifier & 0x1000000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000000000B17216) >> 128;
            }
            if (xSignifier & 0x800000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000000000058B90A) >> 128;
            }
            if (xSignifier & 0x400000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000000002C5C84) >> 128;
            }
            if (xSignifier & 0x200000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000000000162E41) >> 128;
            }
            if (xSignifier & 0x100000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000000000B1720) >> 128;
            }
            if (xSignifier & 0x80000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000000000058B8F) >> 128;
            }
            if (xSignifier & 0x40000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000000000002C5C7) >> 128;
            }
            if (xSignifier & 0x20000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000000000162E3) >> 128;
            }
            if (xSignifier & 0x10000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000000000000B171) >> 128;
            }
            if (xSignifier & 0x8000 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000000000058B8) >> 128;
            }
            if (xSignifier & 0x4000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000000000002C5B) >> 128;
            }
            if (xSignifier & 0x2000 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000000000000162D) >> 128;
            }
            if (xSignifier & 0x1000 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000000000000B16) >> 128;
            }
            if (xSignifier & 0x800 > 0) {
                resultSignifier = (resultSignifier * 0x10000000000000000000000000000058A) >> 128;
            }
            if (xSignifier & 0x400 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000000000002C4) >> 128;
            }
            if (xSignifier & 0x200 > 0) {
                resultSignifier = (resultSignifier * 0x100000000000000000000000000000161) >> 128;
            }
            if (xSignifier & 0x100 > 0) {
                resultSignifier = (resultSignifier * 0x1000000000000000000000000000000B0) >> 128;
            }
            if (xSignifier & 0x80 > 0) resultSignifier = (resultSignifier * 0x100000000000000000000000000000057) >> 128;
            if (xSignifier & 0x40 > 0) resultSignifier = (resultSignifier * 0x10000000000000000000000000000002B) >> 128;
            if (xSignifier & 0x20 > 0) resultSignifier = (resultSignifier * 0x100000000000000000000000000000015) >> 128;
            if (xSignifier & 0x10 > 0) resultSignifier = (resultSignifier * 0x10000000000000000000000000000000A) >> 128;
            if (xSignifier & 0x8 > 0) resultSignifier = (resultSignifier * 0x100000000000000000000000000000004) >> 128;
            if (xSignifier & 0x4 > 0) resultSignifier = (resultSignifier * 0x100000000000000000000000000000001) >> 128;

            if (!xNegative) {
                resultSignifier = (resultSignifier >> 15) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
                resultExponent += 0x3FFF;
            } else if (resultExponent <= 0x3FFE) {
                resultSignifier = (resultSignifier >> 15) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
                resultExponent = 0x3FFF - resultExponent;
            } else {
                resultSignifier = resultSignifier >> (resultExponent - 16367);
                resultExponent = 0;
            }

            // If SUBNORMAL, return 0
            if (resultExponent == 0) return ZERO;

            return bytes16(uint128((resultExponent << 112) | resultSignifier));
        }
    }

    /**
     * @notice Calculate x ** y.
     *     @notice Caller must ensure x≤1 & 0≤y
     *     @notice Rounds down
     * 
     *     @param x Quadruple precision number
     *     @return Quadruple precision positive number
     */
    function pow(bytes16 x, bytes16 y) internal pure returns (bytes16) {
        assert(cmp(y, ZERO) >= 0);
        return pow_2(mul(_log_2(x), y));
    }

    function _log_2(bytes16 x) private pure returns (bytes16) {
        unchecked {
            if (x == ONE) {
                return ZERO;
            } else if (x == ZERO) {
                return 0xc00cfff8000000000000000000000000;
            }
            // Not INF but very negative number
            else {
                uint256 xExponent = uint128(x) >> 112;

                assert(uint128(x) <= 0x3FFF0000000000000000000000000000); // Lte 1 and not NEG
                assert(xExponent > 0); // No SUBNORMALS

                uint256 xSignifier =
                    uint256(uint128(x) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF) | 0x10000000000000000000000000000;

                bool resultNegative;
                uint256 resultExponent = 16495;
                uint256 resultSignifier;

                if (xExponent >= 0x3FFF) {
                    resultNegative = false;
                    resultSignifier = xExponent - 0x3FFF;
                    xSignifier <<= 15;
                } else {
                    resultNegative = true;
                    resultSignifier = 0x3FFE - xExponent;
                    xSignifier <<= 15;
                }

                if (xSignifier == 0x80000000000000000000000000000000) {
                    if (resultNegative) resultSignifier += 1;
                    uint256 shift = 112 - mostSignificantBit(resultSignifier);
                    resultSignifier <<= shift;
                    resultExponent -= shift;
                } else {
                    uint256 bb = resultNegative ? 1 : 0;
                    while (resultSignifier < 0x10000000000000000000000000000) {
                        resultSignifier <<= 1;
                        resultExponent -= 1;

                        xSignifier *= xSignifier;
                        uint256 b = xSignifier >> 255;
                        resultSignifier += b ^ bb;
                        xSignifier >>= 127 + b;
                    }
                }

                return bytes16(
                    uint128(
                        (resultNegative ? 0x80000000000000000000000000000000 : 0) | (resultExponent << 112)
                            | (resultSignifier & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    )
                );
            }
        }
    }

    /**
     * /**
     *     @notice Get index of the most significant non-zero bit in binary representation of unsigned integer.
     * 
     *     @param x Unsigned 256-bit non-zero integer
     *     @return Unsigned 256-bit integer
     */
    function mostSignificantBit(uint256 x) private pure returns (uint256) {
        unchecked {
            assert(x > 0);

            uint256 result = 0;

            if (x >= 0x100000000000000000000000000000000) {
                x >>= 128;
                result += 128;
            }
            if (x >= 0x10000000000000000) {
                x >>= 64;
                result += 64;
            }
            if (x >= 0x100000000) {
                x >>= 32;
                result += 32;
            }
            if (x >= 0x10000) {
                x >>= 16;
                result += 16;
            }
            if (x >= 0x100) {
                x >>= 8;
                result += 8;
            }
            if (x >= 0x10) {
                x >>= 4;
                result += 4;
            }
            if (x >= 0x4) {
                x >>= 2;
                result += 2;
            }
            if (x >= 0x2) result += 1; // No need to shift x anymore

            return result;
        }
    }
}
