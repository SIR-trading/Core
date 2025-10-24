// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Contributors} from "src/Contributors.sol";
import "forge-std/Test.sol";

contract ContributorsTest is Test {
    Contributors public contributors;
    address public owner;

    function setUp() public {
        owner = address(this);
        contributors = new Contributors();
    }

    function testFuzz_allocateRevertsIfNotOwner(address caller) public {
        vm.assume(caller != owner);

        address[] memory addr = new address[](1);
        uint56[] memory alloc = new uint56[](1);
        addr[0] = vm.addr(1);
        alloc[0] = 1000;

        vm.prank(caller);
        vm.expectRevert(Contributors.NotOwner.selector);
        contributors.allocate(addr, alloc);
    }

    function test_allocateRevertsWhenExhausted() public {
        // First allocate uint56.max to one user
        address[] memory addr1 = new address[](1);
        uint56[] memory alloc1 = new uint56[](1);
        addr1[0] = vm.addr(1);
        alloc1[0] = type(uint56).max;

        contributors.allocate(addr1, alloc1);

        // Verify remaining allocation is 0
        assertEq(contributors.remainingAllocation(), 0);

        // Try to allocate to another user - should revert
        // Note: The contract has a require(remainingAllocation_ > 0) check that reverts without data
        address[] memory addr2 = new address[](1);
        uint56[] memory alloc2 = new uint56[](1);
        addr2[0] = vm.addr(2);
        alloc2[0] = 1;

        vm.expectRevert();
        contributors.allocate(addr2, alloc2);
    }

    function test_allocateRevertsWhenExceedingMax() public {
        // Try to allocate more than uint56.max in a single allocation
        address[] memory addr = new address[](2);
        uint56[] memory alloc = new uint56[](2);
        addr[0] = vm.addr(1);
        addr[1] = vm.addr(2);
        alloc[0] = type(uint56).max;
        alloc[1] = 1; // This will cause overflow

        vm.expectRevert(
            abi.encodeWithSelector(
                Contributors.InsufficientRemainingAllocation.selector,
                uint56(1),
                uint56(0)
            )
        );
        contributors.allocate(addr, alloc);
    }

    function test_allocateRevertsOnArrayMismatch() public {
        address[] memory addr = new address[](2);
        uint56[] memory alloc = new uint56[](1);
        addr[0] = vm.addr(1);
        addr[1] = vm.addr(2);
        alloc[0] = 1000;

        vm.expectRevert(Contributors.ArrayLengthMismatch.selector);
        contributors.allocate(addr, alloc);
    }

    function test_allocateRevertsOnZeroAddress() public {
        address[] memory addr = new address[](1);
        uint56[] memory alloc = new uint56[](1);
        addr[0] = address(0);
        alloc[0] = 1000;

        vm.expectRevert(Contributors.ZeroAddress.selector);
        contributors.allocate(addr, alloc);
    }

    function test_allocateRevertsOnDuplicateAllocation() public {
        // First allocation succeeds
        address[] memory addr1 = new address[](1);
        uint56[] memory alloc1 = new uint56[](1);
        addr1[0] = vm.addr(1);
        alloc1[0] = 1000;

        contributors.allocate(addr1, alloc1);

        // Second allocation to same address should revert
        address[] memory addr2 = new address[](1);
        uint56[] memory alloc2 = new uint56[](1);
        addr2[0] = vm.addr(1);
        alloc2[0] = 500;

        vm.expectRevert(
            abi.encodeWithSelector(
                Contributors.AddressAlreadyAllocated.selector,
                vm.addr(1)
            )
        );
        contributors.allocate(addr2, alloc2);
    }

    function test_allocateRevertsOnEmptyArray() public {
        address[] memory addr = new address[](0);
        uint56[] memory alloc = new uint56[](0);

        vm.expectRevert(Contributors.EmptyArray.selector);
        contributors.allocate(addr, alloc);
    }

    function test_allocateSucceeds() public {
        address[] memory addr = new address[](2);
        uint56[] memory alloc = new uint56[](2);
        addr[0] = vm.addr(1);
        addr[1] = vm.addr(2);
        alloc[0] = 1000;
        alloc[1] = 2000;

        uint56 initialRemaining = contributors.remainingAllocation();

        contributors.allocate(addr, alloc);

        assertEq(contributors.allocations(vm.addr(1)), 1000);
        assertEq(contributors.allocations(vm.addr(2)), 2000);
        assertEq(contributors.remainingAllocation(), initialRemaining - 3000);
    }
}
