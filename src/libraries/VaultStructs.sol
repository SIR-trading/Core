// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library VaultStructs {
    struct VaultIssuanceParams {
        uint8 tax; // (tax / type(uint8).max * 10%) of its fee revenue is directed to the Treasury.
        uint40 tsLastUpdate; // timestamp of the last time cumSIRPerTEAx96 was updated. 0 => use systemParams.tsIssuanceStart instead
        uint176 cumSIRPerTEAx96; // Q104.96, cumulative SIR minted by the vaultId per unit of TEA.
    }

    struct VaultParameters {
        address debtToken;
        address collateralToken;
        int8 leverageTier;
    }

    struct TokenParameters {
        string name;
        string symbol;
        uint8 decimals;
    }

    struct SystemParameters {
        // Timestamp when issuance (re)started. 0 => issuance has not started yet
        uint40 tsIssuanceStart;
        /** Base fee in basis points charged to apes per unit of liquidity, so fee = baseFee/1e4*(l-1).
            For example, in a vaultId with 3x target leverage, apes are charged 2*baseFee/1e4 on minting and on burning.
         */
        uint16 baseFee; // Base fee in basis points. Given type(uint16).max, the max baseFee is 655.35%.
        uint16 lpFee; // Base fee in basis points.
        bool mintingStopped; // If true, no minting of TEA/APE
        /** Aggregated taxes for all vaults. Choice of uint16 type.
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

    /** collectedFees: Sum of fees collected for a specific type of collateral
        reservesTotal: Sum of 'reserve' for all vaults for a specific type of collateral
     */
    struct TokenState {
        uint112 collectedFees; // 112 bits for fees because we expect them to be emptied by the stakers on a regular basis
        uint144 total; // TOTAL amount of collateral stored by all vaults (including fees)
    }

    /** Collateral owned by the apes and LPers in a vault
     */
    struct Reserves {
        uint144 reserveApes;
        uint144 reserveLPers;
        int64 tickPriceX42;
    }

    /** Data needed for recoverying the amount of collateral owned by the apes and LPers in a vault
     */
    struct VaultState {
        uint144 reserve; // reserve =  reserveApes + reserveLPers
        /** Price at the border of the power and saturation zone.
            Q21.42 - Fixed point number with 42 bits of precision after the comma.
            type(int64).max and type(int64).min are used to represent +∞ and -∞ respectively.
         */
        int64 tickPriceSatX42; // Saturation price in Q21.42 fixed point
        uint48 vaultId; // Allows the creation of approximately 281 trillion vaults
    }
}
