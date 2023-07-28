// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
library SystemConstants {
    // Tokens issued per second
    uint72 public constant ISSUANCE = 1e2 wei;
    uint40 internal constant _THREE_YEARS = 3 * 365 days;
}
