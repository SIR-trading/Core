// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {APE} from "src/APE.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";

contract TEAInstance is TEA {
    VaultStructs.Parameters[] private _paramsById;

    constructor(address systemControl_, address sir, address oracle_) SystemState(systemControl_, sir) {
        /** We rely on vaultId == 0 to test if a particular vault exists.
         *  To make sure vault Id 0 is never used, we push one empty element as first entry.
         */
        _paramsById.push(VaultStructs.Parameters(address(0), address(0), 0));

        // Add two vaults to test
        _paramsById.push(VaultStructs.Parameters(Addresses._ADDR_USDC, Addresses._ADDR_WETH, -2));
        _paramsById.push(VaultStructs.Parameters(Addresses._ADDR_ALUSD, Addresses._ADDR_USDC, 1));
    }

    function _updateLPerIssuanceParams(
        uint256 vaultId,
        address lper0,
        address lper1,
        bool sirIsCaller
    ) internal virtual returns (uint104 unclaimedRewards) {}

    function paramsById(
        uint256 vaultId
    ) public view override returns (address debtToken, address collateralToken, int8 leverageTier) {
        debtToken = _paramsById[vaultId].debtToken;
        collateralToken = _paramsById[vaultId].collateralToken;
        leverageTier = _paramsById[vaultId].leverageTier;
    }
}

contract TEATest is Test {
    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 amount
    );

    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] amounts
    );

    TEAInstance tea;
    address alice;
    address bob;

    uint256 constant vaultIdA = 1;
    uint256 constant vaultIdB = 2;

    function setUp() public {
        tea = new TEAInstance();
        alice = vm.addr(1);
        bob = vm.addr(2);
    }

    function test_initialConditions(uint256 vaultId) public {
        assertEq(tea.totalSupply(vaultIdA), 0);
        assertEq(tea.balanceOf(vaultIdA, alice), 0);
        assertEq(tea.balanceOf(vaultIdA, bob), 0);
        assertEq(
            tea.uri(vaultIdA),
            "data:application/json;charset=UTF-8,%7B%22name%22%3A%22LP%20Token%20for%20APE-1%22%2C%22symbol%22%3A%22TEA-1%22%2C%22decimals%22%3A18%2C%22chainId%22%3A1%2C%22debtToken%22%3A%220xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48%22%2C%22collateralToken%22%3A%220xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2%22%2C%22leverageTier%22%3A-2%7D"
        );

        assertEq(tea.totalSupply(vaultIdB), 0);
        assertEq(tea.balanceOf(vaultIdB, alice), 0);
        assertEq(tea.balanceOf(vaultIdB, bob), 0);
        assertEq(
            tea.uri(vaultIdB),
            "data:application/json;charset=UTF-8,%7B%22name%22%3A%22LP%20Token%20for%20APE-2%22%2C%22symbol%22%3A%22TEA-2%22%2C%22decimals%22%3A6%2C%22chainId%22%3A1%2C%22debtToken%22%3A%220xBC6DA0FE9aD5f3b0d58160288917AA56653660E9%22%2C%22collateralToken%22%3A%220xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48%22%2C%22leverageTier%22%3A-2%7D"
        );
    }

    // function testFuzz_mint(uint256 mintAmountA, uint256 mintAmountB) public {
    //     vm.expectEmit();
    //     emit Transfer(address(0), alice, mintAmountA);
    //     tea.mint(alice, mintAmountA);
    //     assertEq(tea.balanceOf(alice), mintAmountA);
    //     assertEq(tea.totalSupply(), mintAmountA);

    //     mintAmountB = bound(mintAmountB, 0, type(uint256).max - mintAmountA);

    //     vm.expectEmit();
    //     emit Transfer(address(0), bob, mintAmountB);
    //     tea.mint(bob, mintAmountB);
    //     assertEq(tea.balanceOf(bob), mintAmountB);
    //     assertEq(tea.totalSupply(), mintAmountA + mintAmountB);
    // }

    // function testFuzz_mintFails(uint256 mintAmountA, uint256 mintAmountB) public {
    //     mintAmountA = bound(mintAmountA, 1, type(uint256).max);
    //     tea.mint(alice, mintAmountA);

    //     mintAmountB = bound(mintAmountB, type(uint256).max - mintAmountA + 1, type(uint256).max);
    //     vm.expectRevert();
    //     tea.mint(bob, mintAmountB);
    // }

    // function testFail_mintByNonOwner() public {
    //     vm.prank(alice);
    //     APE(tea).mint(bob, 1000); // This should fail because bob is not the owner
    // }

    // function testFuzz_burn(uint256 mintAmountA, uint256 mintAmountB, uint256 burnAmountB) public {
    //     mintAmountB = bound(mintAmountB, 0, type(uint256).max - mintAmountA);
    //     burnAmountB = bound(burnAmountB, 0, mintAmountB);

    //     tea.mint(alice, mintAmountA);
    //     tea.mint(bob, mintAmountB);

    //     vm.expectEmit();
    //     emit Transfer(bob, address(0), burnAmountB);
    //     tea.burn(bob, burnAmountB);

    //     assertEq(tea.balanceOf(bob), mintAmountB - burnAmountB);
    //     assertEq(tea.totalSupply(), mintAmountA + mintAmountB - burnAmountB);
    // }

    // function testFuzz_burnMoreThanBalance(uint256 mintAmountA, uint256 mintAmountB, uint256 burnAmountB) public {
    //     mintAmountA = bound(mintAmountA, 0, type(uint256).max - 1);
    //     mintAmountB = bound(mintAmountB, 1, type(uint256).max - mintAmountA);
    //     burnAmountB = bound(burnAmountB, mintAmountB + 1, type(uint256).max);

    //     tea.mint(alice, mintAmountA);
    //     tea.mint(bob, mintAmountB);

    //     vm.expectRevert();
    //     tea.burn(bob, burnAmountB);
    // }

    // function testFuzz_transfer(uint256 transferAmount, uint256 mintAmount) public {
    //     transferAmount = bound(transferAmount, 1, type(uint256).max);
    //     mintAmount = bound(mintAmount, transferAmount, type(uint256).max);

    //     tea.mint(alice, mintAmount);

    //     vm.expectEmit();
    //     emit Transfer(alice, bob, transferAmount);
    //     vm.prank(alice);
    //     assertTrue(tea.transfer(bob, transferAmount));
    //     assertEq(tea.balanceOf(bob), transferAmount);
    //     assertEq(tea.balanceOf(alice), mintAmount - transferAmount);
    // }

    // function testFuzz_transferMoreThanBalance(uint256 transferAmount, uint256 mintAmount) public {
    //     transferAmount = bound(transferAmount, 1, type(uint256).max);
    //     mintAmount = bound(mintAmount, 0, transferAmount - 1);

    //     tea.mint(alice, mintAmount);

    //     vm.expectRevert();
    //     tea.transfer(bob, transferAmount);
    // }

    // function testFuzz_approve(uint256 amount) public {
    //     vm.prank(alice);
    //     assertTrue(tea.approve(bob, amount));
    //     assertEq(tea.allowance(alice, bob), amount);
    // }

    // function testFuzz_transferFrom(uint256 transferAmount, uint256 mintAmount) public {
    //     transferAmount = bound(transferAmount, 1, type(uint256).max);
    //     mintAmount = bound(mintAmount, transferAmount, type(uint256).max);

    //     tea.mint(bob, mintAmount);

    //     vm.prank(bob);
    //     assertTrue(tea.approve(alice, mintAmount));
    //     assertEq(tea.allowance(bob, alice), mintAmount);

    //     vm.expectEmit();
    //     emit Transfer(bob, alice, transferAmount);
    //     vm.prank(alice);
    //     assertTrue(tea.transferFrom(bob, alice, transferAmount));

    //     assertEq(tea.balanceOf(bob), mintAmount - transferAmount);
    //     assertEq(tea.allowance(bob, alice), mintAmount == type(uint256).max ? mintAmount : mintAmount - transferAmount);
    //     assertEq(tea.balanceOf(alice), transferAmount);
    // }

    // function testFuzz_transferFromWithoutApproval(uint256 transferAmount, uint256 mintAmount) public {
    //     transferAmount = bound(transferAmount, 1, type(uint256).max);
    //     mintAmount = bound(mintAmount, transferAmount, type(uint256).max);

    //     tea.mint(bob, mintAmount);

    //     vm.expectRevert();
    //     vm.prank(alice);
    //     tea.transferFrom(bob, alice, transferAmount);
    // }

    // function testFuzz_transferFromExceedAllowance(
    //     uint256 transferAmount,
    //     uint256 mintAmount,
    //     uint256 allowedAmount
    // ) public {
    //     transferAmount = bound(transferAmount, 1, type(uint256).max);
    //     mintAmount = bound(mintAmount, transferAmount, type(uint256).max);
    //     allowedAmount = bound(allowedAmount, 0, transferAmount - 1);

    //     tea.mint(bob, mintAmount);

    //     vm.prank(bob);
    //     tea.approve(alice, allowedAmount);

    //     vm.expectRevert();
    //     vm.prank(alice);
    //     tea.transferFrom(bob, alice, transferAmount);
    // }
}
