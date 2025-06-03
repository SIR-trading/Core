// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {SirStructs} from "../libraries/SirStructs.sol";

interface IOracle {
    error NoUniswapPool();
    error OracleNotInitialized();
    error UniswapFeeTierIndexOutOfBounds();

    event OracleFeeTierChanged(uint24 feeTierPrevious, uint24 feeTierSelected);
    event OracleInitialized(
        address indexed token0,
        address indexed token1,
        uint24 feeTierSelected,
        uint136 avLiquidity,
        uint40 period
    );
    event PriceUpdated(address indexed token0, address indexed token1, bool priceTruncated, int64 priceTickX42);
    event UniswapFeeTierAdded(uint24 fee);
    event UniswapOracleProbed(uint24 fee, uint136 avLiquidity, uint40 period, uint16 cardinalityToIncrease);

    function TWAP_DURATION() external view returns (uint40);
    function getPrice(address collateralToken, address debtToken) external view returns (int64);
    function getUniswapFeeTiers() external view returns (SirStructs.UniswapFeeTier[] memory uniswapFeeTiers);
    function initialize(address tokenA, address tokenB) external;
    function newUniswapFeeTier(uint24 fee) external;
    function state(address token0, address token1) external view returns (SirStructs.OracleState memory);
    function uniswapFeeTierAddressOf(address tokenA, address tokenB) external view returns (address);
    function uniswapFeeTierOf(address tokenA, address tokenB) external view returns (uint24);
    function updateOracleState(
        address collateralToken,
        address debtToken
    ) external returns (int64 tickPriceX42, address uniswapPoolAddress);
}
