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
        uint216 daoFees;
        uint216 apesReserve;
        uint216 lpReserve;
    }

    /**
     * Data tightly packed into 2 words to save gas.
     */
    struct State {
        uint40 vaultId; // Allows creation of 1 trillion vaults approx
        uint216 totalReserves; // totalReserves =  apesReserve + lpReserve
        int64 tickPriceSatX42; // Price at the border of the power and saturation zone. Q21.42 - Fixed point number with 42 bits of precision after the comma.
        uint192 daoFees; // If the uint192 is close to overflow, the DAO can withdraw the fees to unlock the pool
    }
}
