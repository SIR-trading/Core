// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
abstract contract SystemCommons {
    modifier onlySystemControl() {
        require(msg.sender == SYSTEM_CONTROL);
        _;
    }

    uint8 internal constant SIR_DECIMALS = 12;

    /** SIR Token Issuance Rate
        If we want to issue 2,015,000,000 SIR per year, this implies an issuance rate of 63.9 SIR/s.
     */
    uint72 public constant ISSUANCE = uint72(2015000000 * 10 ** SIR_DECIMALS) / 365 days; // [sir/s]

    // During the first 3 years, 20% of the emissions are diverged to contributors.
    uint72 internal constant AGG_ISSUANCE_VAULTS = (ISSUANCE * 8) / 10;

    uint256 internal constant TEA_MAX_SUPPLY = (uint256(AGG_ISSUANCE_VAULTS) << 96) / type(uint16).max;

    uint40 internal constant THREE_YEARS = 3 * 365 days;

    address internal constant ADDR_UNISWAPV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    address internal immutable SYSTEM_CONTROL;

    constructor(address systemControl) {
        SYSTEM_CONTROL = systemControl;
    }
}
