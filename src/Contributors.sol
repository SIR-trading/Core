// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @notice Stores contributor allocations using packed storage to minimize gas costs.
 * @dev Uses uint24 allocations packed 10 per storage slot (256 bits / 24 bits = 10.67, so 10 fit).
 * Total contributor allocation: 30%, LP allocation: 70%.
 * Sum of all allocations must equal type(uint24).max.
 */
contract Contributors {
    error NotOwner();
    error ArrayLengthMismatch();
    error AddressAlreadyAllocated(address addr);
    error InsufficientRemainingAllocation(uint24 requested, uint24 available);
    error EmptyArray();
    error ZeroAddress();

    /**
     * @dev Packed storage for allocations. Each slot holds 10 uint24 allocations.
     * Layout: [16 unused bits][alloc9][alloc8][alloc7][alloc6][alloc5][alloc4][alloc3][alloc2][alloc1][alloc0]
     * where each allocation is 24 bits.
     */
    mapping(uint256 slotIndex => uint256 packedAllocations) internal _packedAllocations;

    /**
     * @dev Maps contributor address to their index (1-based to distinguish from unset).
     * Index 0 means not allocated.
     */
    mapping(address contributor => uint256 index) internal _contributorIndex;

    /// @notice Total number of contributors allocated so far.
    uint256 public contributorCount;

    address public owner;
    uint24 public remainingAllocation = type(uint24).max;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Returns the allocation for a contributor.
     * @param contributor The address to query.
     * @return allocation The contributor's allocation (0 if not allocated).
     */
    function allocations(address contributor) external view returns (uint24) {
        uint256 index = _contributorIndex[contributor];
        if (index == 0) return 0;

        // Convert 1-based index to 0-based
        uint256 idx = index - 1;
        uint256 slotIndex = idx / 10;
        uint256 positionInSlot = idx % 10;

        uint256 packed = _packedAllocations[slotIndex];
        return uint24(packed >> (positionInSlot * 24));
    }

    /**
     * @notice Allocates tokens to multiple contributors.
     * @dev Owner can allocate until all type(uint24).max is spent.
     * @param addr_ Array of contributor addresses.
     * @param allocations_ Array of allocation amounts.
     */
    function allocate(address[] calldata addr_, uint24[] calldata allocations_) external onlyOwner {
        uint256 length = addr_.length;

        if (length != allocations_.length) revert ArrayLengthMismatch();
        if (length == 0) revert EmptyArray();

        uint24 remainingAllocation_ = remainingAllocation;
        require(remainingAllocation_ > 0);

        uint256 currentCount = contributorCount;

        // Process allocations
        for (uint256 i = 0; i < length; i++) {
            address recipient = addr_[i];
            uint24 amount = allocations_[i];

            // Validate inputs
            if (recipient == address(0)) revert ZeroAddress();
            if (_contributorIndex[recipient] != 0) revert AddressAlreadyAllocated(recipient);

            // Check for underflow before subtracting
            if (remainingAllocation_ < amount) {
                revert InsufficientRemainingAllocation(amount, remainingAllocation_);
            }

            // Assign 1-based index to contributor
            uint256 newIndex = currentCount + i + 1;
            _contributorIndex[recipient] = newIndex;

            // Calculate slot and position (0-based index)
            uint256 idx = newIndex - 1;
            uint256 slotIndex = idx / 10;
            uint256 positionInSlot = idx % 10;

            // Pack the allocation into the slot
            _packedAllocations[slotIndex] |= uint256(amount) << (positionInSlot * 24);

            remainingAllocation_ -= amount;
        }

        contributorCount = currentCount + length;
        remainingAllocation = remainingAllocation_;
    }

    /**
     * @notice Returns the contributor address at a given index.
     * @dev This is O(n) and should only be used off-chain.
     * @param index The 0-based index of the contributor.
     * @return The allocation at that index.
     */
    function allocationAt(uint256 index) external view returns (uint24) {
        if (index >= contributorCount) return 0;

        uint256 slotIndex = index / 10;
        uint256 positionInSlot = index % 10;

        uint256 packed = _packedAllocations[slotIndex];
        return uint24(packed >> (positionInSlot * 24));
    }
}
