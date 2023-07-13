// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface VaultStructs {
    struct Parameters {
        address debtToken;
        address collateralToken;
        int8 leverageTier;
    }

    struct Reserves {
        uint256 daoFees;
        uint256 gentlemenReserve;
        uint256 apesReserve;
        uint256 lpReserve;
    }

    /**
     * Use SSTORE2 or SSTORE3 to store the state?!
     * USE uint104 instead of uint232 to save space?!
     * FIRST TEST AS THIS AND THEN CHECK THE OTHER SOLUTIONS TO COMPARE GAS
     */
    struct State {
        uint48 vaultId; // Allows for 281 trillion vaults.
        uint232 daoFees;
        uint232 totalReserves; // totalReserves = gentlemenReserve + apesReserve + lpReserve
        bytes16 pLiq; // Liquidation price. Lower bound of the Price Stability Region is pLow = pLiq * collateralizationFactor
        bytes16 pHigh; // Upper bound of the Price Stability Region
    }
}
