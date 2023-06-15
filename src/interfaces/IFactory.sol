// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import "./IPoolLogic.sol";

interface IFactory is IPoolLogic {
    function uniswapFeeTiers(uint256) external view returns (uint24);

    function poolsAddresses(uint256) external view returns (address);

    function poolsParameters(address)
        external
        view
        returns (
            address debtToken,
            address collateralToken,
            address oracle,
            int8 leverageTier
        );

    function createPool(
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external;

    function newUniswapFeeTier(uint24 uniswapFeeTier) external;
}
