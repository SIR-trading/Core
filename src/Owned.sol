// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

abstract contract Owned {
    address public immutable OWNER;

    modifier onlyOwner() { 
        require(OWNER == msg.sender);
        _;
    }

    constructor() {
        OWNER = msg.sender;
    }
}
