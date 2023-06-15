// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import "./ISyntheticToken.sol";
import "./PoolStructs.sol";
import "./ISystemState.sol";

interface IPoolLogic is ISystemState {
    function quoteMint(
        PoolStructs.State memory state,
        int8 leverageTier,
        bytes16 price,
        uint256 syntheticSupply,
        address collateralToken,
        bool isTEA
    ) external view returns (PoolStructs.Reserves memory reservesPre, uint256 amountSyntheticToken, uint256 feeToPOL);

    function quoteBurn(
        PoolStructs.State memory state,
        int8 leverageTier,
        bytes16 price,
        uint256 syntheticSupply,
        uint256 amountSyntheticToken,
        bool isTEA
    ) external view returns (PoolStructs.Reserves memory reservesPre, uint256 collateralWithdrawn, uint256 feeToPOL);

    function quoteMintMAAM(PoolStructs.State memory state, int8 leverageTier, bytes16 price, address collateralToken)
        external
        view
        returns (uint256 LPReservePre, uint256 collateralDeposited);

    function quoteBurnMAAM(PoolStructs.State memory state, int8 leverageTier, bytes16 price, uint256 amountMAAM)
        external
        view
        returns (uint256 LPReservePre);

    function getReserves(PoolStructs.State memory state, int8 leverageTier, bytes16 price)
        external
        view
        returns (PoolStructs.Reserves memory reserves);

    function priceStabilityRange(PoolStructs.State memory state, int8 leverageTier)
        external
        pure
        returns (bytes16 pLiq, bytes16 pLow, bytes16 pHigh);
}
