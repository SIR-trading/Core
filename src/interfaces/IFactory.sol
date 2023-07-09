// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import "./IVaultLogic.sol";

interface IFactory is IVaultLogic {
    function uniswapFeeTiers(uint256) external view returns (uint24);

    function vaultsAddresses(uint256) external view returns (address);

    function vaultsParameters(address)
        external
        view
        returns (address debtToken, address collateralToken, address oracle, int8 leverageTier);

    function createVault(address debtToken, address collateralToken, int8 leverageTier) external;

    function newUniswapFeeTier(uint24 uniswapFeeTier) external;
}
