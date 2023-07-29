// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
abstract contract SystemCommons {
    modifier onlySystemControl() {
        _onlySystemControl();
        _;
    }

    // Tokens issued per second
    uint72 public constant ISSUANCE = 1e2 ether; // Not really "ether" but just for the decimals
    uint40 internal constant _THREE_YEARS = 3 * 365 days;

    address public immutable systemControl;

    constructor(address systemControl_) {
        systemControl = systemControl_;
    }

    function _onlySystemControl() private view {
        require(msg.sender == systemControl);
    }
}
