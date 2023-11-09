// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {APE} from "src/APE.sol";
import {IVault} from "src/Interfaces/IVault.sol";
import {Addresses} from "src/libraries/Addresses.sol";

contract APETest is Test {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    APE ape;
    address alice;
    address bob;
    address charlie;

    function setUp() public {
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(IVault.latestTokenParams.selector),
            abi.encode(
                "Tokenized ETH/USDC with x1.25 leverage",
                "APE-42",
                uint8(18),
                Addresses.ADDR_USDC,
                Addresses.ADDR_WETH,
                int8(-2)
            )
        );
        ape = new APE();
        alice = vm.addr(1);
        bob = vm.addr(2);
        charlie = vm.addr(3);
    }

    function test_initialConditions() public {
        assertEq(ape.totalSupply(), 0);
        assertEq(ape.balanceOf(alice), 0);
        assertEq(ape.balanceOf(bob), 0);
        assertEq(ape.debtToken(), Addresses.ADDR_USDC);
        assertEq(ape.collateralToken(), Addresses.ADDR_WETH);
        assertEq(ape.leverageTier(), -2);
        assertEq(ape.name(), "Tokenized ETH/USDC with x1.25 leverage");
        assertEq(ape.symbol(), "APE-42");
        assertEq(ape.decimals(), 18);
    }

    function testFuzz_mint(uint256 mintAmountA, uint256 mintAmountB) public {
        vm.expectEmit();
        emit Transfer(address(0), alice, mintAmountA);
        ape.mint(alice, mintAmountA);
        assertEq(ape.balanceOf(alice), mintAmountA);
        assertEq(ape.totalSupply(), mintAmountA);

        mintAmountB = bound(mintAmountB, 0, type(uint256).max - mintAmountA);

        vm.expectEmit();
        emit Transfer(address(0), bob, mintAmountB);
        ape.mint(bob, mintAmountB);
        assertEq(ape.balanceOf(bob), mintAmountB);
        assertEq(ape.totalSupply(), mintAmountA + mintAmountB);
    }

    function testFuzz_mintFails(uint256 mintAmountA, uint256 mintAmountB) public {
        mintAmountA = bound(mintAmountA, 1, type(uint256).max);
        ape.mint(alice, mintAmountA);

        mintAmountB = bound(mintAmountB, type(uint256).max - mintAmountA + 1, type(uint256).max);
        vm.expectRevert();
        ape.mint(bob, mintAmountB);
    }

    function testFail_mintByNonOwner() public {
        vm.prank(alice);
        APE(ape).mint(bob, 1000); // This should fail because bob is not the owner
    }

    function testFuzz_burn(uint256 mintAmountA, uint256 mintAmountB, uint256 burnAmountB) public {
        mintAmountB = bound(mintAmountB, 0, type(uint256).max - mintAmountA);
        burnAmountB = bound(burnAmountB, 0, mintAmountB);

        ape.mint(alice, mintAmountA);
        ape.mint(bob, mintAmountB);

        vm.expectEmit();
        emit Transfer(bob, address(0), burnAmountB);
        ape.burn(bob, burnAmountB);

        assertEq(ape.balanceOf(bob), mintAmountB - burnAmountB);
        assertEq(ape.totalSupply(), mintAmountA + mintAmountB - burnAmountB);
    }

    function testFuzz_burnMoreThanBalance(uint256 mintAmountA, uint256 mintAmountB, uint256 burnAmountB) public {
        mintAmountA = bound(mintAmountA, 0, type(uint256).max - 1);
        mintAmountB = bound(mintAmountB, 1, type(uint256).max - mintAmountA);
        burnAmountB = bound(burnAmountB, mintAmountB + 1, type(uint256).max);

        ape.mint(alice, mintAmountA);
        ape.mint(bob, mintAmountB);

        vm.expectRevert();
        ape.burn(bob, burnAmountB);
    }

    function testFuzz_transfer(uint256 transferAmount, uint256 mintAmount) public {
        transferAmount = bound(transferAmount, 1, type(uint256).max);
        mintAmount = bound(mintAmount, transferAmount, type(uint256).max);

        ape.mint(alice, mintAmount);

        vm.expectEmit();
        emit Transfer(alice, bob, transferAmount);
        vm.prank(alice);
        assertTrue(ape.transfer(bob, transferAmount));
        assertEq(ape.balanceOf(bob), transferAmount);
        assertEq(ape.balanceOf(alice), mintAmount - transferAmount);
    }

    function testFuzz_transferMoreThanBalance(uint256 transferAmount, uint256 mintAmount) public {
        transferAmount = bound(transferAmount, 1, type(uint256).max);
        mintAmount = bound(mintAmount, 0, transferAmount - 1);

        ape.mint(alice, mintAmount);

        vm.expectRevert();
        ape.transfer(bob, transferAmount);
    }

    function testFuzz_approve(uint256 amount) public {
        vm.prank(alice);
        assertTrue(ape.approve(bob, amount));
        assertEq(ape.allowance(alice, bob), amount);
    }

    function testFuzz_transferFrom(uint256 transferAmount, uint256 mintAmount) public {
        transferAmount = bound(transferAmount, 1, type(uint256).max);
        mintAmount = bound(mintAmount, transferAmount, type(uint256).max);

        ape.mint(bob, mintAmount);

        vm.prank(bob);
        assertTrue(ape.approve(alice, mintAmount));
        assertEq(ape.allowance(bob, alice), mintAmount);

        vm.expectEmit();
        emit Transfer(bob, charlie, transferAmount);
        vm.prank(alice);
        assertTrue(ape.transferFrom(bob, charlie, transferAmount));

        assertEq(ape.balanceOf(bob), mintAmount - transferAmount);
        assertEq(ape.allowance(bob, alice), mintAmount == type(uint256).max ? mintAmount : mintAmount - transferAmount);
        assertEq(ape.balanceOf(alice), 0);
        assertEq(ape.balanceOf(charlie), transferAmount);
    }

    function testFuzz_transferFromWithoutApproval(uint256 transferAmount, uint256 mintAmount) public {
        transferAmount = bound(transferAmount, 1, type(uint256).max);
        mintAmount = bound(mintAmount, transferAmount, type(uint256).max);

        ape.mint(bob, mintAmount);

        vm.expectRevert();
        vm.prank(alice);
        ape.transferFrom(bob, alice, transferAmount);
    }

    function testFuzz_transferFromExceedAllowance(
        uint256 transferAmount,
        uint256 mintAmount,
        uint256 allowedAmount
    ) public {
        transferAmount = bound(transferAmount, 1, type(uint256).max);
        mintAmount = bound(mintAmount, transferAmount, type(uint256).max);
        allowedAmount = bound(allowedAmount, 0, transferAmount - 1);

        ape.mint(bob, mintAmount);

        vm.prank(bob);
        ape.approve(alice, allowedAmount);

        vm.expectRevert();
        vm.prank(alice);
        ape.transferFrom(bob, alice, transferAmount);
    }
}
