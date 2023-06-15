// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface PoolStructs {
    struct Reserves {
        uint256 DAOFees;
        uint256 gentlemenReserve;
        uint256 apesReserve;
        uint256 LPReserve;
    }

    struct State {
        uint256 DAOFees;
        uint256 totalReserves; // totalReserves = gentlemenReserve + apesReserve + LPReserve
        bytes16 pLiq; // Liquidation price. Lower bound of the Price Stability Region is pLow = pLiq * collateralizationFactor
        bytes16 pHigh; // Upper bound of the Price Stability Region
    }
}
