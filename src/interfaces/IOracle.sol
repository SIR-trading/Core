// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracle {
    function TWAP_DELTA() external pure returns (uint16);

    function TWAP_DURATION() external pure returns (uint16);

    function newUniswapFeeTier(uint24 fee) external;

    function initialize(address tokenA, address tokenB) external;

    function updateOracleState(address collateralToken, address debtToken) external returns (bytes16);

    function getPrice(address collateralToken, address debtToken) external view returns (bytes16);
}
