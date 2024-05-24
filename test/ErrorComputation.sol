// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

library ErrorComputation {
    function maxErrorBalance(
        uint8 bitsAfterTheComma,
        uint256 balance,
        uint256 numUpdatesCumulative
    ) internal pure returns (uint256) {
        return ((balance * numUpdatesCumulative) >> bitsAfterTheComma) + 1;
    }

    function maxErrorCumumlative(uint256 numUpdatesCumulative) internal pure returns (uint256) {
        return numUpdatesCumulative;
    }
}
