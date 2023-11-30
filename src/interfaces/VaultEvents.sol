// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface VaultEvents {
    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId
    );
}
