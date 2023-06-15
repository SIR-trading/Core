// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library ResettableBalancesUInt216 {
    struct TimestampedBalance {
        uint216 balance;
        uint40 tsLastUpdate;
    }

    struct ResettableBalances {
        uint216 numLiquidations;
        uint40 tsLastLiquidation;
        mapping(address => TimestampedBalance) timestampedBalances;
    }

    function get(ResettableBalances storage resettableBalances, address account) public view returns (uint216) {
        return resettableBalances.tsLastLiquidation < resettableBalances.timestampedBalances[account].tsLastUpdate
            ? 0
            : resettableBalances.timestampedBalances[account].balance;
    }

    function set(ResettableBalances storage resettableBalances, address account, uint256 value) external {
        uint216 value_ = uint216(value);
        require(value_ == value);
        resettableBalances.timestampedBalances[account].balance = value_;
        resettableBalances.timestampedBalances[account].tsLastUpdate = uint40(block.timestamp);
    }

    function reset(ResettableBalances storage resettableBalances) internal {
        resettableBalances.tsLastLiquidation = uint40(block.timestamp);
        resettableBalances.numLiquidations++;
    }

    function increase(ResettableBalances storage resettableBalances, address account, uint256 value) internal {
        uint216 value_ = uint216(value);
        require(value_ == value);
        resettableBalances.timestampedBalances[account].balance = get(resettableBalances, account) + value_;
        resettableBalances.timestampedBalances[account].tsLastUpdate = uint40(block.timestamp);
    }

    function decrease(ResettableBalances storage resettableBalances, address account, uint256 value) internal {
        uint216 value_ = uint216(value);
        require(value_ == value);
        resettableBalances.timestampedBalances[account].balance = get(resettableBalances, account) - value_;
        resettableBalances.timestampedBalances[account].tsLastUpdate = uint40(block.timestamp);
    }
}
