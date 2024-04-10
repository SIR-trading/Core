// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

library ErrorComputation {
    function maxErrorBalanceSIR(uint256 balance, uint256 numUpdatesCumSIRPerTea) internal pure returns (uint256) {
        return ((balance * numUpdatesCumSIRPerTea) >> 96) + 1;
    }

    function maxErrorCumSIRPerTEA(uint256 numUpdatesCumSIRPerTea) internal pure returns (uint256) {
        return numUpdatesCumSIRPerTea;
    }
}
