// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVaultExternal {
    function latestTokenParams()
        external
        returns (
            string memory name,
            string memory symbol,
            uint8 decimals,
            address debtToken,
            address collateralToken,
            int8 leverageTier
        );

    function deployAPE(
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external returns (uint256 vaultId);

    function teaURI(uint256 vaultId, uint256 totalSupply) external view returns (string memory);

    function paramsById(
        uint256 vaultId
    ) external view returns (address debtToken, address collateralToken, int8 leverageTier);
}
