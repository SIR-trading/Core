// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
abstract contract SystemCommons {
    modifier onlySystemControl() {
        require(msg.sender == SYSTEM_CONTROL);
        _;
    }

    struct LPerIssuanceParams {
        uint152 cumSIRPerTEA; // Q104.48, cumulative SIR minted by an LPer per unit of TEA
        uint104 unclaimedRewards; // SIR owed to the LPer. 104 bits is enough to store the balance even if all SIR issued in +1000 years went to a single LPer
    }

    // Tokens issued per second
    uint72 public constant ISSUANCE = 1e2 ether; // Not really "ether" but we use it anyway to simulate 18 decimals

    uint72 internal constant AGG_ISSUANCE_VAULTS = (ISSUANCE * 9) / 10;

    uint40 internal constant THREE_YEARS = 3 * 365 days;

    address internal constant ADDR_UNISWAPV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    address internal immutable SYSTEM_CONTROL;

    constructor(address systemControl) {
        SYSTEM_CONTROL = systemControl;
    }
}
