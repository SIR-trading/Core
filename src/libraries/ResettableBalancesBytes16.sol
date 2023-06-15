// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Libraries
import "./FloatingPoint.sol";

library ResettableBalancesBytes16 {
    using FloatingPoint for bytes16;

    struct TimestampedBalance {
        bytes16 balance;
        uint40 tsLastUpdate;
    }

    struct ResettableBalances {
        uint40 tsLastLiquidation;
        uint216 numLiquidations;
        mapping(address => TimestampedBalance) timestampedBalances;
    }

    function get(ResettableBalances storage resettableBalances, address account) public view returns (bytes16) {
        return resettableBalances.tsLastLiquidation < resettableBalances.timestampedBalances[account].tsLastUpdate
            ? FloatingPoint.ZERO
            : resettableBalances.timestampedBalances[account].balance;
    }

    function set(ResettableBalances storage resettableBalances, address account, bytes16 balance_) internal {
        resettableBalances.timestampedBalances[account].balance = balance_;
        resettableBalances.timestampedBalances[account].tsLastUpdate = uint40(block.timestamp);
    }

    function reset(ResettableBalances storage resettableBalances) internal {
        resettableBalances.tsLastLiquidation = uint40(block.timestamp);
        resettableBalances.numLiquidations++;
    }

    function increase(ResettableBalances storage resettableBalances, address account, bytes16 value) internal {
        set(resettableBalances, account, get(resettableBalances, account).add(value));
    }

    function decrease(ResettableBalances storage resettableBalances, address account, bytes16 value) internal {
        set(resettableBalances, account, get(resettableBalances, account).sub(value));
    }
}
