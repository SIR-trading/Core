// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library VaultStructs {
    struct VaultIssuanceParams {
        uint8 tax; // (tax / type(uint8).max * 10%) of its fee revenue is directed to the Treasury.
        uint40 tsLastUpdate; // timestamp of the last time cumSIRPerTEAx96 was updated. 0 => use systemParams.tsIssuanceStart instead
        uint176 cumSIRPerTEAx96; // Q104.96, cumulative SIR minted by the vaultId per unit of TEA.
    }

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
        uint152 treasury;
        uint152 apesReserve;
        uint152 lpReserve;
    }

    struct SystemParameters {
        // Timestamp when issuance (re)started. 0 => issuance has not started yet
        uint40 tsIssuanceStart;
        /** Base fee in basis points charged to apes per unit of liquidity, so fee = baseFee/1e4*(l-1).
            For example, in a vaultId with 3x target leverage, apes are charged 2*baseFee/1e4 on minting and on burning.
         */
        uint16 baseFee; // Base fee in basis points. Given type(uint16).max, the max baseFee is 655.35%.
        uint8 lpFee; // Base fee in basis points. Given type(uint8).max, the max baseFee is 2.56%.
        bool emergencyStop;
        /** Aggregated taxes for all vaults. Choice of uint32 type.
            For vault i, (tax_i / type(uint8).max)*10% is charged, where tax_i is of type uint8.
            They must satisfy the condition
                Σ_i (tax_i / type(uint8).max)^2 ≤ 0.1^2
            Under this constraint, cumTax = Σ_i tax_i is maximized when all taxes are equal (tax_i = tax for all i) and
                tax = type(uint8).max / sqrt(Nvaults)
            Since the lowest non-zero value is tax=1, the maximum number of vaults with non-zero tax is
                Nvaults = type(uint8).max^2 < type(uint16).max
         */
        uint16 cumTax;
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
        uint152 treasury; // If the uint192 is close to overflow, the Treasury can withdraw the fees to unlock the pool
    }

    // UNISWAP V2 USES ONLY 112 BITS FOR THE RESERVES!!!
    // 64 + 32 + 104 + 56
    // If vaultId was not stored, I could use 1 slot only!
}
