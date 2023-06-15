// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IMAAM.sol";
import "./IFees.sol";

interface IPool is IMAAM {
    function parameters() external view returns (address debtToken, address collateralToken, int8 leverageTier);

    function syntheticTokens() external view returns (address teaToken, address apeToken);

    function FACTORY() external view returns (address);

    function ORACLE() external view returns (address);

    function stabilityPriceRange() external view returns (bytes16, bytes16);

    function getReserves()
        external
        view
        returns (uint256 DAOFees, uint256 gentlemenReserve, uint256 apesReserve, uint256 LPReserve);

    function quoteMintTEA(uint256 collateralDeposited) external view returns (uint256 amountTEA);

    function quoteBurnTEA(uint256 amountTEA) external view returns (uint256 collateralWithdrawn);

    function quoteMintAPE(uint256 collateralDeposited) external view returns (uint256 amountAPE);

    function quoteBurnAPE(uint256 amountAPE) external view returns (uint256 collateralWithdrawn);

    function initialize(IFees fees_, address oracle_) external;

    function mintTEA() external returns (uint256 amountTEA);

    function burnTEA(uint256 amountTEA) external returns (uint256 collateralWithdrawn);

    function mintAPE() external returns (uint256 amountAPE);

    function burnAPE(uint256 amountAPE) external returns (uint256 collateralWithdrawn);

    function mintMAAM(address LPer) external returns (uint256 reserveLP);

    function burnMAAM(address LPer, uint256 amountMAAM) external returns (uint256 reserveLP);

    function withdrawDAOFees() external returns (uint256);
}
