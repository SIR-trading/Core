// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TEA} from "src/TEA.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {VaultExternal} from "src/VaultExternal.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";

contract TEAInstance is TEA {
    constructor(address vaultExternal) TEA(vaultExternal) {}

    function mintE(address to, uint256 vaultId, uint256 amount) external {
        mint(to, vaultId, amount);
    }

    function updateLPerIssuanceParams(
        bool sirIsCaller,
        uint256 vaultId,
        address lper0,
        address lper1
    ) internal override returns (uint104 unclaimedRewards) {}

    // function paramsById(
    //     uint256 vaultId
    // ) public view override returns (address debtToken, address collateralToken, int8 leverageTier) {
    //     debtToken = _paramsById[vaultId].debtToken;
    //     collateralToken = _paramsById[vaultId].collateralToken;
    //     leverageTier = _paramsById[vaultId].leverageTier;
    // }
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

    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    VaultExternal vaultExternal;
    TEAInstance tea;

    address alice;
    address bob;
    address charlie;

    uint256 constant vaultIdA = 1;
    uint256 constant vaultIdB = 2;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        vaultExternal = new VaultExternal(address(this));
        vaultExternal.deployAPE(Addresses.ADDR_USDC, Addresses.ADDR_WETH, -2);
        vaultExternal.deployAPE(Addresses.ADDR_ALUSD, Addresses.ADDR_USDC, 1);

        tea = new TEAInstance(address(vaultExternal));

        alice = vm.addr(1);
        bob = vm.addr(2);
        charlie = vm.addr(3);
    }

    function test_initialConditions() public {
        assertEq(tea.totalSupply(vaultIdA), 0);
        assertEq(tea.balanceOf(alice, vaultIdA), 0);
        assertEq(tea.balanceOf(bob, vaultIdA), 0);
        assertEq(
            tea.uri(vaultIdA),
            "data:application/json;charset=UTF-8,%7B%22name%22%3A%22LP%20Token%20for%20APE-1%22%2C%22symbol%22%3A%22TEA-1%22%2C%22decimals%22%3A18%2C%22chainId%22%3A1%2C%22debtToken%22%3A%220xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48%22%2C%22collateralToken%22%3A%220xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2%22%2C%22leverageTier%22%3A-2%2C%22totalSupply%22%3A0%7D"
        );

        assertEq(tea.totalSupply(vaultIdB), 0);
        assertEq(tea.balanceOf(alice, vaultIdB), 0);
        assertEq(tea.balanceOf(bob, vaultIdB), 0);
        assertEq(
            tea.uri(vaultIdB),
            "data:application/json;charset=UTF-8,%7B%22name%22%3A%22LP%20Token%20for%20APE-2%22%2C%22symbol%22%3A%22TEA-2%22%2C%22decimals%22%3A6%2C%22chainId%22%3A1%2C%22debtToken%22%3A%220xbc6da0fe9ad5f3b0d58160288917aa56653660e9%22%2C%22collateralToken%22%3A%220xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48%22%2C%22leverageTier%22%3A1%2C%22totalSupply%22%3A0%7D"
        );
    }

    function testFail_initialConditions() public view {
        tea.uri(0);
    }

    function testFuzz_setApprovalForAll(bool approved) public {
        vm.prank(alice); // Setting the sender to 'alice'

        vm.expectEmit();
        emit ApprovalForAll(alice, bob, approved);
        tea.setApprovalForAll(bob, approved); // Setting 'bob' as the operator for 'alice'

        // Asserting the approval
        if (approved) assertTrue(tea.isApprovedForAll(alice, bob));
        else assertTrue(!tea.isApprovedForAll(alice, bob));
    }

    ///////////////////////////
    //// safeTransferForm ////
    /////////////////////////

    function testFuzz_safeTransferFrom(uint256 vaultId, uint256 transferAmount, uint256 mintAmount) public {
        // Bounds the amounts
        transferAmount = bound(transferAmount, 1, type(uint256).max);
        mintAmount = bound(mintAmount, transferAmount, type(uint256).max);

        // Suppose you have a mint function for TEA, otherwise adapt as necessary
        tea.mintE(bob, vaultId, mintAmount);

        // Bob approves Alice to transfer on his behalf
        vm.prank(bob);
        tea.setApprovalForAll(alice, true);

        // Expecting the transfer event
        vm.expectEmit();
        emit TransferSingle(alice, bob, charlie, vaultId, transferAmount);

        // Alice transfers from Bob to Charlie
        vm.prank(alice);
        tea.safeTransferFrom(bob, charlie, vaultId, transferAmount, "");

        // Asserting the post-transfer state
        assertEq(tea.balanceOf(alice, vaultId), 0);
        assertEq(tea.balanceOf(bob, vaultId), mintAmount - transferAmount);
        assertEq(tea.balanceOf(charlie, vaultId), transferAmount);
    }

    function testFuzz_safeTransferFromExceedBalance(
        uint256 vaultId,
        uint256 transferAmount,
        uint256 mintAmount
    ) public {
        // Bounds the amounts
        transferAmount = bound(transferAmount, 1, type(uint256).max);
        mintAmount = bound(mintAmount, 0, transferAmount - 1);

        // Suppose you have a mint function for TEA, otherwise adapt as necessary
        tea.mintE(bob, vaultId, mintAmount);

        // Bob approves Alice to transfer on his behalf
        vm.prank(bob);
        tea.setApprovalForAll(alice, true);

        // Alice transfers from Bob to herself
        vm.prank(alice);
        vm.expectRevert();
        tea.safeTransferFrom(bob, charlie, vaultId, transferAmount, "");
    }

    function testFuzz_safeTransferFromNotAuthorized(
        uint256 vaultId,
        uint256 transferAmount,
        uint256 mintAmount
    ) public {
        // Bounds the amounts
        transferAmount = bound(transferAmount, 1, type(uint256).max);
        mintAmount = bound(mintAmount, transferAmount, type(uint256).max);

        // Suppose you have a mint function for TEA, otherwise adapt as necessary
        tea.mintE(bob, vaultId, mintAmount);

        // Bob approves Alice to transfer on his behalf
        vm.prank(bob);
        tea.setApprovalForAll(alice, true);

        // Charlie fails to transfer from Bob
        vm.prank(charlie);
        vm.expectRevert("NOT_AUTHORIZED");
        tea.safeTransferFrom(bob, alice, vaultId, transferAmount, "");
    }

    function testFuzz_safeTransferFromToContract(uint256 vaultId, uint256 transferAmount, uint256 mintAmount) public {
        // Bounds the amounts
        transferAmount = bound(transferAmount, 1, type(uint256).max);
        mintAmount = bound(mintAmount, transferAmount, type(uint256).max);

        // Suppose you have a mint function for TEA, otherwise adapt as necessary
        tea.mintE(bob, vaultId, mintAmount);

        // Bob approves Alice to transfer on his behalf
        vm.prank(bob);
        tea.setApprovalForAll(alice, true);

        // Alice fails to transfer from Bob to this contract
        vm.prank(alice);
        vm.expectRevert();
        tea.safeTransferFrom(bob, address(this), vaultId, transferAmount, "");
    }

    function testFuzz_safeTransferFromUnsafeRecipient(
        uint256 vaultId,
        uint256 transferAmount,
        uint256 mintAmount
    ) public {
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(ERC1155TokenReceiver.onERC1155Received.selector),
            abi.encode(TEAInstance.mintE.selector) // Wrong selector
        );

        // Bounds the amounts
        transferAmount = bound(transferAmount, 1, type(uint256).max);
        mintAmount = bound(mintAmount, transferAmount, type(uint256).max);

        // Suppose you have a mint function for TEA, otherwise adapt as necessary
        tea.mintE(bob, vaultId, mintAmount);

        // Bob approves Alice to transfer on his behalf
        vm.prank(bob);
        tea.setApprovalForAll(alice, true);

        // Alice fails to transfer from Bob to this contract
        vm.prank(alice);
        vm.expectRevert("UNSAFE_RECIPIENT");
        tea.safeTransferFrom(bob, address(this), vaultId, transferAmount, "");
    }

    function testFuzz_safeTransferFromSafeRecipient(
        uint256 vaultId,
        uint256 transferAmount,
        uint256 mintAmount
    ) public {
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(ERC1155TokenReceiver.onERC1155Received.selector),
            abi.encode(ERC1155TokenReceiver.onERC1155Received.selector)
        );

        // Bounds the amounts
        transferAmount = bound(transferAmount, 1, type(uint256).max);
        mintAmount = bound(mintAmount, transferAmount, type(uint256).max);

        // Suppose you have a mint function for TEA, otherwise adapt as necessary
        tea.mintE(bob, vaultId, mintAmount);

        // Bob approves Alice to transfer on his behalf
        vm.prank(bob);
        tea.setApprovalForAll(alice, true);

        // Expecting the transfer event
        vm.expectEmit();
        emit TransferSingle(alice, bob, address(this), vaultId, transferAmount);

        // Alice transfers from Bob to this contract
        vm.prank(alice);
        tea.safeTransferFrom(bob, address(this), vaultId, transferAmount, "");

        // Asserting the post-transfer state
        assertEq(tea.balanceOf(alice, vaultId), 0);
        assertEq(tea.balanceOf(bob, vaultId), mintAmount - transferAmount);
        assertEq(tea.balanceOf(address(this), vaultId), transferAmount);
    }

    ////////////////////////////////
    //// safeBatchTransferFrom ////
    //////////////////////////////

    function _convertToDynamicArray(uint256 a, uint256 b) private pure returns (uint256[] memory arrOut) {
        arrOut = new uint256[](2);
        arrOut[0] = a;
        arrOut[1] = b;
    }

    function testFuzz_safeBatchTransferFrom1(
        uint256 transferAmountA,
        uint256 transferAmountB,
        uint256 mintAmountA,
        uint256 mintAmountB
    ) public {
        transferAmountA = bound(transferAmountA, 1, type(uint256).max);
        mintAmountA = bound(mintAmountA, transferAmountA, type(uint256).max);
        tea.mintE(bob, vaultIdA, mintAmountA);

        transferAmountB = bound(transferAmountB, 1, type(uint256).max);
        mintAmountB = bound(mintAmountB, transferAmountB, type(uint256).max);
        tea.mintE(bob, vaultIdB, mintAmountB);

        // Bob approves Alice to transfer on his behalf
        vm.prank(bob);
        tea.setApprovalForAll(alice, true);

        // Expecting the batch transfer event
        vm.expectEmit();
        emit TransferBatch(
            alice,
            bob,
            charlie,
            _convertToDynamicArray(vaultIdA, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB)
        );

        // Alice batch transfers from Bob to Charlie
        vm.prank(alice);
        tea.safeBatchTransferFrom(
            bob,
            charlie,
            _convertToDynamicArray(vaultIdA, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB),
            ""
        );

        assertEq(tea.balanceOf(bob, vaultIdA), mintAmountA - transferAmountA);
        assertEq(tea.balanceOf(charlie, vaultIdA), transferAmountA);
        assertEq(tea.balanceOf(bob, vaultIdB), mintAmountB - transferAmountB);
        assertEq(tea.balanceOf(charlie, vaultIdB), transferAmountB);
    }

    function testFuzz_safeBatchTransferFromNotAuthorized(
        uint256 transferAmountA,
        uint256 transferAmountB,
        uint256 mintAmountA,
        uint256 mintAmountB
    ) public {
        transferAmountA = bound(transferAmountA, 1, type(uint256).max);
        mintAmountA = bound(mintAmountA, transferAmountA, type(uint256).max);
        tea.mintE(bob, vaultIdA, mintAmountA);

        transferAmountB = bound(transferAmountB, 1, type(uint256).max);
        mintAmountB = bound(mintAmountB, transferAmountB, type(uint256).max);
        tea.mintE(bob, vaultIdB, mintAmountB);

        // Bob approves Alice to transfer on his behalf
        vm.prank(bob);
        tea.setApprovalForAll(alice, true);

        // Charlie fails to batch transfer from Bob
        vm.prank(charlie);
        vm.expectRevert("NOT_AUTHORIZED");
        tea.safeBatchTransferFrom(
            bob,
            alice,
            _convertToDynamicArray(vaultIdA, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB),
            ""
        );
    }

    function testFuzz_safeBatchTransferFromExceedBalance(
        uint256 transferAmountA,
        uint256 transferAmountB,
        uint256 mintAmountA,
        uint256 mintAmountB
    ) public {
        transferAmountA = bound(transferAmountA, 1, type(uint256).max);
        mintAmountA = bound(mintAmountA, 0, transferAmountA - 1);
        tea.mintE(bob, vaultIdA, mintAmountA);

        transferAmountB = bound(transferAmountB, 1, type(uint256).max);
        mintAmountB = bound(mintAmountB, 0, transferAmountB - 1);
        tea.mintE(bob, vaultIdB, mintAmountB);

        // Bob approves Alice to transfer on his behalf
        vm.prank(bob);
        tea.setApprovalForAll(alice, true);

        // Alice tries to batch transfer from Bob but should fail
        vm.prank(alice);
        vm.expectRevert();
        tea.safeBatchTransferFrom(
            bob,
            charlie,
            _convertToDynamicArray(vaultIdA, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB),
            ""
        );
    }

    function testFuzz_safeBatchTransferFromToContract(
        uint256 transferAmountA,
        uint256 transferAmountB,
        uint256 mintAmountA,
        uint256 mintAmountB
    ) public {
        transferAmountA = bound(transferAmountA, 1, type(uint256).max);
        mintAmountA = bound(mintAmountA, transferAmountA, type(uint256).max);
        tea.mintE(bob, vaultIdA, mintAmountA);

        transferAmountB = bound(transferAmountB, 1, type(uint256).max);
        mintAmountB = bound(mintAmountB, transferAmountB, type(uint256).max);
        tea.mintE(bob, vaultIdB, mintAmountB);

        // Bob approves Alice to transfer on his behalf
        vm.prank(bob);
        tea.setApprovalForAll(alice, true);

        // Alice fails to batch transfer from Bob to this contract
        vm.prank(alice);
        vm.expectRevert();
        tea.safeBatchTransferFrom(
            bob,
            address(this),
            _convertToDynamicArray(vaultIdA, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB),
            ""
        );
    }

    function testFuzz_safeBatchTransferFromUnsafeRecipient(
        uint256 transferAmountA,
        uint256 transferAmountB,
        uint256 mintAmountA,
        uint256 mintAmountB
    ) public {
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(ERC1155TokenReceiver.onERC1155BatchReceived.selector),
            abi.encode(TEAInstance.mintE.selector) // Wrong selector
        );

        transferAmountA = bound(transferAmountA, 1, type(uint256).max);
        mintAmountA = bound(mintAmountA, transferAmountA, type(uint256).max);
        tea.mintE(bob, vaultIdA, mintAmountA);

        transferAmountB = bound(transferAmountB, 1, type(uint256).max);
        mintAmountB = bound(mintAmountB, transferAmountB, type(uint256).max);
        tea.mintE(bob, vaultIdB, mintAmountB);

        // Bob approves Alice to transfer on his behalf
        vm.prank(bob);
        tea.setApprovalForAll(alice, true);

        // Alice fails to batch transfer from Bob to an unsafe recipient
        vm.prank(alice);
        vm.expectRevert();
        tea.safeBatchTransferFrom(
            bob,
            address(this),
            _convertToDynamicArray(vaultIdA, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB),
            ""
        );
    }
}

contract TEATestInternal is Test, TEA(address(0)) {
    address alice;
    address bob;
    address charlie;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        alice = vm.addr(1);
        bob = vm.addr(2);
        charlie = vm.addr(3);
    }

    function updateLPerIssuanceParams(
        bool sirIsCaller,
        uint256 vaultId,
        address lper0,
        address lper1
    ) internal override returns (uint104 unclaimedRewards) {}

    function testFuzz_mint(uint256 vaultId, uint256 mintAmountA, uint256 mintAmountB) public {
        mint(alice, vaultId, mintAmountA);
        assertEq(balanceOf[alice][vaultId], mintAmountA);
        assertEq(totalSupply[vaultId], mintAmountA);

        mintAmountB = bound(mintAmountB, 0, type(uint256).max - mintAmountA);

        vm.expectEmit();
        emit TransferSingle(msg.sender, address(0), bob, vaultId, mintAmountB);
        mint(bob, vaultId, mintAmountB);
        assertEq(balanceOf[bob][vaultId], mintAmountB);
        assertEq(totalSupply[vaultId], mintAmountA + mintAmountB);
    }

    function testFuzz_mintFails(uint256 vaultId, uint256 mintAmountA, uint256 mintAmountB) public {
        mintAmountA = bound(mintAmountA, 1, type(uint256).max);
        mint(alice, vaultId, mintAmountA);

        mintAmountB = bound(mintAmountB, type(uint256).max - mintAmountA + 1, type(uint256).max);
        vm.expectRevert();
        mint(bob, vaultId, mintAmountB);
    }

    function testFuzz_burn(uint256 vaultId, uint256 mintAmountA, uint256 mintAmountB, uint256 burnAmountB) public {
        mintAmountB = bound(mintAmountB, 0, type(uint256).max - mintAmountA);
        burnAmountB = bound(burnAmountB, 0, mintAmountB);

        mint(alice, vaultId, mintAmountA);
        mint(bob, vaultId, mintAmountB);

        vm.expectEmit();
        emit TransferSingle(msg.sender, bob, address(0), vaultId, burnAmountB);
        burn(bob, vaultId, burnAmountB);

        assertEq(balanceOf[bob][vaultId], mintAmountB - burnAmountB);
        assertEq(totalSupply[vaultId], mintAmountA + mintAmountB - burnAmountB);
    }

    function testFuzz_burnMoreThanBalance(
        uint256 vaultId,
        uint256 mintAmountA,
        uint256 mintAmountB,
        uint256 burnAmountB
    ) public {
        mintAmountA = bound(mintAmountA, 1, type(uint256).max - 1);
        mintAmountB = bound(mintAmountB, 1, type(uint256).max - mintAmountA);
        burnAmountB = bound(burnAmountB, mintAmountB + 1, type(uint256).max);

        mint(alice, vaultId, mintAmountA);
        mint(bob, vaultId, mintAmountB);

        vm.expectRevert();
        burn(bob, vaultId, burnAmountB);
    }
}
