// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
interface ISIR {
    function lPerMint(uint256 vaultId, address to) external;

    function treasuryMint(uint256 vaultId, address to) external;
}
