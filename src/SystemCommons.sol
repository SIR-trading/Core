// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
abstract contract SystemCommons {
    modifier onlySystemControl() {
        require(msg.sender == systemControl);
        _;
    }

    // Tokens issued per second
    uint72 public constant ISSUANCE = 1e2 ether; // Not really "ether" but we use it anyway to simulate 18 decimals

    uint72 internal constant _AGG_ISSUANCE_VAULTS = ISSUANCE / 10;

    uint40 internal constant _THREE_YEARS = 3 * 365 days;

    address internal constant _ADDR_UNISWAPV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    address private immutable systemControl;

    constructor(address systemControl_) {
        systemControl = systemControl_;
    }
}
