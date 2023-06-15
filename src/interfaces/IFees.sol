// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFees {
    function basisFee() external view returns (uint16);

    function setBasisFee(uint16 basisFee_) external;

    function hiddenFeeMintTEA(
        uint256 collateralIn,
        uint256 reserveTEA,
        uint256 reserveAPE,
        int256 leverageTier
    ) external view returns (uint256 collateralDeposited, uint256 comissionToApes);

    function feeMintTEA(
        uint256 collateralIn,
        uint256 reserveTEA,
        uint256 reserveAPE,
        int256 leverageTier
    ) external view returns (uint256 collateralDeposited, uint256 comissionToApes);

    function hiddenFeeBurnTEA(
        uint256 collateralOut,
        uint256 reserveTEA,
        uint256 reserveAPE,
        int256 leverageTier
    ) external view returns (uint256 collateralToUser, uint256 comissionToGentlemen);

    function feeBurnTEA(
        uint256 collateralOut,
        uint256 reserveTEA,
        uint256 reserveAPE,
        int256 leverageTier
    ) external view returns (uint256 collateralToUser, uint256 comissionToGentlemen);

    function hiddenFeeMintAPE(
        uint256 collateralIn,
        uint256 reserveTEA,
        uint256 reserveAPE,
        int256 leverageTier
    ) external view returns (uint256 collateralDeposited, uint256 comissionToGentlemen);

    function feeMintAPE(
        uint256 collateralIn,
        uint256 reserveTEA,
        uint256 reserveAPE,
        int256 leverageTier
    ) external view returns (uint256 collateralDeposited, uint256 comissionToGentlemen);

    function hiddenFeeBurnAPE(
        uint256 collateralOut,
        uint256 reserveTEA,
        uint256 reserveAPE,
        int256 leverageTier
    ) external view returns (uint256 collateralToUser, uint256 comissionToApes);

    function feeBurnAPE(
        uint256 collateralOut,
        uint256 reserveTEA,
        uint256 reserveAPE,
        int256 leverageTier
    ) external view returns (uint256 collateralToUser, uint256 comissionToApes);
}
