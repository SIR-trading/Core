// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Libraries
import {FloatingPoint} from "./FloatingPoint.sol";

library ResettableBalancesBytes16 {
    error ZeroBalance();

    using FloatingPoint for bytes16;

    struct TimestampedBalance {
        bytes16 balance;
        uint40 tsLastUpdate;
    }

    struct ResettableBalances {
        bytes16 nonRebasingSupply;
        uint40 tsLastLiquidation;
        uint88 numLiquidations;
        mapping(address => TimestampedBalance) timestampedBalances;
    }

    function getBalance(ResettableBalances storage resettableBalances, address account) public view returns (bytes16) {
        return
            resettableBalances.tsLastLiquidation < resettableBalances.timestampedBalances[account].tsLastUpdate
                ? FloatingPoint.ZERO
                : resettableBalances.timestampedBalances[account].balance;
    }

    function setBalance(ResettableBalances storage resettableBalances, address account, bytes16 balance) private {
        resettableBalances.timestampedBalances[account] = TimestampedBalance({
            balance: balance,
            tsLastUpdate: uint40(block.timestamp)
        });
    }

    function transfer(
        ResettableBalances storage resettableBalances,
        address from,
        address to,
        bytes16 amount
    ) internal {
        if (resettableBalances.nonRebasingSupply == FloatingPoint.ZERO) revert ZeroBalance();

        setBalance(resettableBalances, from, getBalance(resettableBalances, from).sub(amount));
        setBalance(resettableBalances, to, getBalance(resettableBalances, to).add(amount));
    }

    function transfer(
        ResettableBalances storage resettableBalances,
        address from,
        address to,
        uint256 amount,
        uint256 totalSupply
    ) internal {
        if (resettableBalances.nonRebasingSupply == FloatingPoint.ZERO || totalSupply == 0) revert ZeroBalance();

        setBalance(
            resettableBalances,
            from,
            getBalance(resettableBalances, from).sub(
                resettableBalances.nonRebasingSupply.mulDivuUp(amount, totalSupply)
            )
        );
        setBalance(
            resettableBalances,
            to,
            getBalance(resettableBalances, to).add(resettableBalances.nonRebasingSupply.mulDivu(amount, totalSupply))
        );
    }

    function mint(
        ResettableBalances storage resettableBalances,
        address account,
        uint256 amount,
        uint256 totalSupply
    ) internal returns (bool lpersLiquidated) {
        if (totalSupply == 0) {
            // Liquidate previous LPers if the LP reserve is empty
            if (resettableBalances.nonRebasingSupply.cmp(FloatingPoint.ZERO) > 0) {
                resettableBalances.nonRebasingSupply = FloatingPoint.ZERO;
                resettableBalances.tsLastLiquidation = uint40(block.timestamp);
                resettableBalances.numLiquidations++;
                lpersLiquidated = true;
            }

            // Update balance
            setBalance(
                resettableBalances,
                account,
                getBalance(resettableBalances, account).add(FloatingPoint.fromUInt(amount))
            );

            // Update supply
            resettableBalances.nonRebasingSupply = resettableBalances.nonRebasingSupply.addUp(
                FloatingPoint.fromUIntUp(amount)
            );
        } else {
            // Mint protocol owned liquidity (POL) if the LP reserve has collateral but there are no LPers
            if (resettableBalances.nonRebasingSupply == FloatingPoint.ZERO) {
                bytes16 POL = FloatingPoint.fromUInt(totalSupply);
                setBalance(resettableBalances, address(this), POL);
                resettableBalances.nonRebasingSupply = POL;
            }

            // Update balance
            setBalance(
                resettableBalances,
                account,
                getBalance(resettableBalances, account).add(
                    resettableBalances.nonRebasingSupply.mulDivu(amount, totalSupply)
                )
            );

            // Update supply
            resettableBalances.nonRebasingSupply = resettableBalances.nonRebasingSupply.addUp(
                resettableBalances.nonRebasingSupply.mulDivuUp(amount, totalSupply)
            );
        }
    }

    function burn(
        ResettableBalances storage resettableBalances,
        address account,
        uint256 amount,
        uint256 totalSupply
    ) internal {
        if (resettableBalances.nonRebasingSupply == FloatingPoint.ZERO || totalSupply == 0) revert ZeroBalance();

        // Update balance
        setBalance(
            resettableBalances,
            account,
            getBalance(resettableBalances, account).sub(
                resettableBalances.nonRebasingSupply.mulDivuUp(amount, totalSupply)
            )
        );

        // Update supply
        resettableBalances.nonRebasingSupply = resettableBalances.nonRebasingSupply.subUp(
            resettableBalances.nonRebasingSupply.mulDivu(amount, totalSupply)
        );
    }
}
