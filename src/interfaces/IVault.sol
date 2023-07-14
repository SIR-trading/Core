// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVault {
    function latestParams() external returns (address debtToken, address collateralToken, int8 leverageTier);

    function tokenParameters() external returns (string memory name, string memory symbol, uint8 decimals);
}
