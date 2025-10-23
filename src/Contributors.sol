// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Contributors {
    /** @dev Total contributor allocation: 30%
     *  LP allocation: 70%
     *
     *  Breakdown:
     *  - 25% to SIR holders (proportional to total SIR including unissued)
     *  - 1% to Hypurr NFT holders (proportional to NFT count)
     *  - Between 1% and 5% to HyperEVM contributors and treasury
     *  Sum of all allocations must be equal to type(uint56).max.
     */

    error NotOwner();
    error ArrayLengthMismatch();
    error AddressAlreadyAllocated(address addr);
    error InsufficientRemainingAllocation(uint56 requested, uint56 available);
    error EmptyArray();
    error ZeroAddress();

    mapping(address => uint56) public allocations;

    address public owner;
    uint56 public remainingAllocation = type(uint56).max;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /** @dev Owner can allocate until all type(uint56).max is spent.
     */
    function allocate(address[] calldata addr_, uint56[] calldata allocations_) external onlyOwner {
        uint256 length = addr_.length;

        if (length != allocations_.length) revert ArrayLengthMismatch();
        if (length == 0) revert EmptyArray();

        uint56 remainingAllocation_ = remainingAllocation;
        require(remainingAllocation_ > 0);
        for (uint256 i = 0; i < length; i++) {
            address recipient = addr_[i];
            uint56 amount = allocations_[i];

            // Validate inputs
            if (recipient == address(0)) revert ZeroAddress();
            if (allocations[recipient] > 0) revert AddressAlreadyAllocated(recipient);

            // Check for underflow before subtracting
            if (remainingAllocation_ < amount) {
                revert InsufficientRemainingAllocation(amount, remainingAllocation_);
            }

            allocations[recipient] = allocations_[i];

            remainingAllocation_ -= allocations_[i];
        }

        remainingAllocation = remainingAllocation_;
    }
}
