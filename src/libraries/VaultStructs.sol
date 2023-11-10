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

    struct SystemParameters {
        // Timestamp when issuance (re)started. 0 => issuance has not started yet
        uint40 tsIssuanceStart;
        /**
         * Base fee in basis points charged to apes per unit of liquidity, so fee = baseFee/1e4*(l-1).
         * For example, in a vaultId with 3x target leverage, apes are charged 2*baseFee/1e4 on minting and on burning.
         */
        uint16 baseFee; // Base fee in basis points. Given type(uint16).max, the max baseFee is 655.35%.
        uint8 lpFee; // Base fee in basis points. Given type(uint8).max, the max baseFee is 2.56%.
        bool emergencyStop;
        uint184 aggTaxesToDAO; // Aggregated taxToDAO of all vaults
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
