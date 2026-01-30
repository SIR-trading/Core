// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @notice Stores contributor allocations using packed storage to minimize gas costs.
 * @dev Uses uint16 allocations packed 16 per storage slot (256 bits / 16 bits = 16).
 * Total contributor allocation: 29%, LP allocation: 69%.
 * Sum of all allocations must equal type(uint16).max.
 */
contract Contributors {
    error NotOwner();
    error ArrayLengthMismatch();
    error AddressAlreadyAllocated(address addr);
    error InsufficientRemainingAllocation(uint16 requested, uint16 available);
    error EmptyArray();
    error ZeroAddress();

    /**
     * @dev Packed storage for allocations. Each slot holds 16 uint16 allocations.
     * Layout: [alloc15][alloc14]...[alloc1][alloc0]
     * where each allocation is 16 bits.
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
    uint16 public remainingAllocation = type(uint16).max;

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
    function allocations(address contributor) external view returns (uint16) {
        uint256 index = _contributorIndex[contributor];
        if (index == 0) return 0;

        // Convert 1-based index to 0-based
        uint256 idx = index - 1;
        uint256 slotIndex = idx / 16;
        uint256 positionInSlot = idx % 16;

        uint256 packed = _packedAllocations[slotIndex];
        return uint16(packed >> (positionInSlot * 16));
    }

    /**
     * @notice Allocates tokens to multiple contributors.
     * @dev Owner can allocate until all type(uint16).max is spent.
     * @param addr_ Array of contributor addresses.
     * @param allocations_ Array of allocation amounts.
     */
    function allocate(address[] calldata addr_, uint16[] calldata allocations_) external onlyOwner {
        uint256 length = addr_.length;

        if (length != allocations_.length) revert ArrayLengthMismatch();
        if (length == 0) revert EmptyArray();

        uint16 remainingAllocation_ = remainingAllocation;
        require(remainingAllocation_ > 0);

        uint256 currentCount = contributorCount;

        // Process allocations
        for (uint256 i = 0; i < length; i++) {
            address recipient = addr_[i];
            uint16 amount = allocations_[i];

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
            uint256 slotIndex = idx / 16;
            uint256 positionInSlot = idx % 16;

            // Pack the allocation into the slot
            _packedAllocations[slotIndex] |= uint256(amount) << (positionInSlot * 16);

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
    function allocationAt(uint256 index) external view returns (uint16) {
        if (index >= contributorCount) return 0;

        uint256 slotIndex = index / 16;
        uint256 positionInSlot = index % 16;

        uint256 packed = _packedAllocations[slotIndex];
        return uint16(packed >> (positionInSlot * 16));
    }
}
