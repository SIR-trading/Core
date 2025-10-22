// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Contributors {
    /** @dev Total contributor allocation: 30%
     *  LP allocation: 70%
     *
     *  Breakdown:
     *  - 25% to SIR holders (proportional to total SIR including unissued)
     *  - 1% to Hypurr NFT holders (proportional to NFT count)
     *  - 1.05% to HyperEVM contributors (basis point allocations)
     *  - Remainder to treasury
     *
     *  Sum of all allocations must be equal to type(uint56).max.
     */
    mapping(address => uint56) public allocations;

    uint256 public numAllocations;
    uint256 private _remainingInitializeCalls;

    constructor(uint256 numAllocations_) {
        numAllocations = numAllocations_;
        _remainingInitializeCalls = (numAllocations_ + 999) / 1000;
    }

    /** @dev This function sets 1,000 allocations on every call.
     *  One ⌈numAllocations/1000⌉ calls have been performed, the function is disabled.
     */
    function initialize(address[] calldata addr, ) external {


        _remainingInitializeCalls--;
    }
}
