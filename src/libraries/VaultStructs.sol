// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library VaultStructs {
    struct Parameters {
        address debtToken;
        address collateralToken;
        int8 leverageTier;
    }

    struct TokenParameters {
        string name;
        string symbol;
        uint8 decimals;
    }

    struct Reserves {
        uint152 daoFees;
        uint152 apesReserve;
        uint152 lpReserve;
    }

    /** Data tightly packed into 2 words to save gas.
        tickPriceX42 & timeStampPrice are not really needed here because they can be obtained by calling the oracle,
        but it saves gas if the call has already been made in the same block because they take no extra slots.
     */
    struct State {
        int64 tickPriceX42; // Last stored price from the oracle. Q21.42
        uint40 timeStampPrice; // Timestamp of the last stored price
        uint152 totalReserves; // totalReserves =  apesReserve + lpReserve
        /** Price at the border of the power and saturation zone.
            Q21.42 - Fixed point number with 42 bits of precision after the comma.
            type(int64).max and type(int64).min are used to represent +∞ and -∞ respectively.
         */
        int64 tickPriceSatX42;
        uint40 vaultId; // Allows creation of 1 trillion vaults approx
        uint152 daoFees; // If the uint192 is close to overflow, the DAO can withdraw the fees to unlock the pool
    }

    // UNISWAP V2 USES ONLY 112 BITS FOR THE RESERVES!!!
    // 64 + 32 + 104 + 56
    // If vaultId was not stored, I could use 1 slot only!
}
