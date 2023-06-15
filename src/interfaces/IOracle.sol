// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracle {
    function FACTORY() external view returns (address);

    function TOKEN_A() external view returns (address);

    function TOKEN_B() external view returns (address);

    function feesUniswapV3Pools(uint256 index) external view returns (uint24);

    function addrsUniswapV3Pools(uint24 index) external view returns (address);

    function newFeePool(uint24 fee) external returns (bool);

    function increaseOracleLength(uint16 Nblocks) external;

    function getPrice(address) external view returns (bytes16);

    function updatePriceMemory(address) external returns (bytes16);
}
