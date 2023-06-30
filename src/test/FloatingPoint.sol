// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.6.0;

import "../libraries/FloatingPoint.sol";

contract $FloatingPoint {
    bytes32 public __hh_exposed_bytecode_marker = "hardhat-exposed";

    constructor() payable {}

    function $ONE() external pure returns (bytes16) {
        return FloatingPoint.ONE;
    }

    function $ZERO() external pure returns (bytes16) {
        return FloatingPoint.ZERO;
    }

    function $INFINITY() external pure returns (bytes16) {
        return FloatingPoint.INFINITY;
    }

    function $fromInt(int256 x) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.fromInt(x);
    }

    function $fromUInt(uint256 x) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.fromUInt(x);
    }

    function $fromUIntUp(uint256 x) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.fromUIntUp(x);
    }

    function $toUInt(bytes16 x) external pure returns (uint256 ret0) {
        (ret0) = FloatingPoint.toUInt(x);
    }

    function $sign(bytes16 x) external pure returns (int8 ret0) {
        (ret0) = FloatingPoint.sign(x);
    }

    function $cmp(bytes16 x, bytes16 y) external pure returns (int8 ret0) {
        (ret0) = FloatingPoint.cmp(x, y);
    }

    function $add(bytes16 x, bytes16 y) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.add(x, y);
    }

    function $addUp(bytes16 x, bytes16 y) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.addUp(x, y);
    }

    function $inc(bytes16 x) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.inc(x);
    }

    function $sub(bytes16 x, bytes16 y) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.sub(x, y);
    }

    function $subUp(bytes16 x, bytes16 y) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.subUp(x, y);
    }

    function $dec(bytes16 x) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.dec(x);
    }

    function $mul(bytes16 x, bytes16 y) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.mul(x, y);
    }

    function $mulUp(bytes16 x, bytes16 y) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.mulUp(x, y);
    }

    function $div(bytes16 x, bytes16 y) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.div(x, y);
    }

    function $inv(bytes16 x) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.inv(x);
    }

    function $mulu(bytes16 x, uint256 y) external pure returns (uint256 ret0) {
        (ret0) = FloatingPoint.mulu(x, y);
    }

    function $mulDiv(
        bytes16 x,
        uint256 y,
        bytes16 z
    ) external pure returns (uint256 ret0) {
        (ret0) = FloatingPoint.mulDiv(x, y, z);
    }

    function $divu(uint256 x, uint256 y) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.divu(x, y);
    }

    function $mulDivu(
        bytes16 x,
        uint256 y,
        uint256 z
    ) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.mulDivu(x, y, z);
    }

    function $mulDivuUp(
        bytes16 x,
        uint256 y,
        uint256 z
    ) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.mulDivuUp(x, y, z);
    }

    function $pow_2(bytes16 x) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.pow_2(x);
    }

    function $pow(bytes16 x, bytes16 y) external pure returns (bytes16 ret0) {
        (ret0) = FloatingPoint.pow(x, y);
    }

    receive() external payable {}
}
