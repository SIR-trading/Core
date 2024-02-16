// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TEA} from "src/TEA.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {VaultExternal} from "src/libraries/VaultExternal.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {MockERC20} from "src/test/MockERC20.sol";

contract TEATestConstants {
    uint256 constant VAULT_ID = 9; // we test with vault 9
    uint256 constant MAX_VAULT_ID = 15; // 15 vauls instantiated
    int8 constant LEVERAGE_TIER = -3;
}

contract TEAInstance is TEA, TEATestConstants {
    address collateral;

    constructor(address collateral_) TEA(address(0), address(0)) {
        collateral = collateral_;

        // Initialize array
        for (uint256 vaultId = 0; vaultId <= MAX_VAULT_ID; vaultId++) {
            paramsById.push(
                VaultStructs.VaultParameters({debtToken: address(0), collateralToken: address(0), leverageTier: 0})
            );
        }

        paramsById[VAULT_ID] = VaultStructs.VaultParameters({
            debtToken: Addresses.ADDR_USDT,
            collateralToken: collateral_,
            leverageTier: LEVERAGE_TIER
        });

        paramsById[MAX_VAULT_ID] = VaultStructs.VaultParameters({
            debtToken: Addresses.ADDR_USDT,
            collateralToken: collateral_,
            leverageTier: LEVERAGE_TIER
        });
    }

    function mint(address account, uint256 amount) external {
        assert(totalSupplyAndBalanceVault[VAULT_ID].totalSupply + amount <= SystemConstants.TEA_MAX_SUPPLY);
        totalSupplyAndBalanceVault[VAULT_ID].totalSupply += uint128(amount);

        if (account == address(this)) totalSupplyAndBalanceVault[VAULT_ID].balanceVault += uint128(amount);
        else balances[account][VAULT_ID] += amount;
    }
}

contract TEATest is Test, TEATestConstants {
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

    uint8 constant DECIMALS = 18;

    TEAInstance tea;
    MockERC20 collateral;

    address alice;
    address bob;
    address charlie;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        collateral = new MockERC20("Collateral token", "TKN", DECIMALS);
        tea = new TEAInstance(address(collateral));

        alice = vm.addr(1);
        bob = vm.addr(2);
        charlie = vm.addr(3);
    }

    function _idToAddress(uint256 id) private view returns (address) {
        id = _bound(id, 0, 3);
        return id == 0 ? address(tea) : vm.addr(id);
    }

    function test_initialConditions() public {
        assertEq(tea.totalSupply(VAULT_ID), 0);
        assertEq(tea.balanceOf(alice, VAULT_ID), 0);
        assertEq(tea.balanceOf(bob, VAULT_ID), 0);
        assertEq(
            tea.uri(VAULT_ID),
            string.concat(
                "data:application/json;charset=UTF-8,%7B%22name%22%3A%22LP%20Token%20for%20APE-",
                vm.toString(VAULT_ID),
                "%22%2C%22symbol%22%3A%22TEA-",
                vm.toString(VAULT_ID),
                "%22%2C%22decimals%22%3A",
                vm.toString(DECIMALS),
                "%2C%22chain_id%22%3A1%2C%22vault_id%22%3A",
                vm.toString(VAULT_ID),
                "%2C%22debt_token%22%3A%22",
                vm.toString(abi.encodePacked(Addresses.ADDR_USDT)),
                "%22%2C%22collateral_token%22%3A%22",
                vm.toString(abi.encodePacked(address(collateral))),
                "%22%2C%22leverage_tier%22%3A",
                vm.toString(LEVERAGE_TIER),
                "%2C%22total_supply%22%3A0",
                "%7D"
            )
        );
    }

    function testFail_initialConditionsVaultId0() public view {
        tea.uri(0);
    }

    function test_initialConditionsVaultIdLargetThanLength() public {
        tea.uri(MAX_VAULT_ID);
        vm.expectRevert();
        tea.uri(MAX_VAULT_ID + 1);
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

    function testFuzz_safeTransferFrom(
        uint256 fromId,
        uint256 operatorId,
        uint256 toId,
        uint256 transferAmount,
        uint256 mintAmount
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        // Valt liquidity can never be transfered out
        vm.assume(from != address(tea));

        // Bounds the amounts
        transferAmount = _bound(transferAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmount = _bound(mintAmount, transferAmount, SystemConstants.TEA_MAX_SUPPLY);

        // Suppose you have a mint function for TEA, otherwise adapt as necessary
        tea.mint(from, mintAmount);

        // From approves operator to transfer on his behalf
        vm.prank(from);
        tea.setApprovalForAll(operator, true);

        // Expecting the transfer event
        vm.expectEmit();
        emit TransferSingle(operator, from, to, VAULT_ID, transferAmount);

        // Alice transfers from Bob to Charlie
        vm.prank(operator);
        tea.safeTransferFrom(from, to, VAULT_ID, transferAmount, "");

        // Asserting balances
        if (operator != from && operator != to) assertEq(tea.balanceOf(operator, VAULT_ID), 0);
        assertEq(tea.balanceOf(from, VAULT_ID), from == to ? mintAmount : mintAmount - transferAmount);
        assertEq(tea.balanceOf(to, VAULT_ID), to == from ? mintAmount : transferAmount);
    }

    // function testFuzz_safeTransferFromExceedBalance(uint256 transferAmount, uint256 mintAmount) public {
    //     // Bounds the amounts
    //     transferAmount = _bound(transferAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
    //     mintAmount = _bound(mintAmount, 0, transferAmount - 1);

    //     // Suppose you have a mint function for TEA, otherwise adapt as necessary
    //     if (mintAmount > 0) tea.mint(bob, mintAmount);

    //     // Bob approves Alice to transfer on his behalf
    //     vm.prank(bob);
    //     tea.setApprovalForAll(alice, true);

    //     // Alice transfers from Bob to herself
    //     vm.prank(alice);
    //     vm.expectRevert();
    //     tea.safeTransferFrom(bob, charlie, VAULT_ID, transferAmount, "");
    // }

    // function testFuzz_safeTransferFromNotAuthorized(uint256 transferAmount, uint256 mintAmount) public {
    //     // Bounds the amounts
    //     transferAmount = _bound(transferAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
    //     mintAmount = _bound(mintAmount, transferAmount, SystemConstants.TEA_MAX_SUPPLY);

    //     // Suppose you have a mint function for TEA, otherwise adapt as necessary
    //     tea.mint(bob, mintAmount);

    //     // Bob approves Alice to transfer on his behalf
    //     vm.prank(bob);
    //     tea.setApprovalForAll(alice, true);

    //     // Charlie fails to transfer from Bob
    //     vm.prank(charlie);
    //     vm.expectRevert("NOT_AUTHORIZED");
    //     tea.safeTransferFrom(bob, alice, VAULT_ID, transferAmount, "");
    // }

    // function testFuzz_safeTransferFromToContract(uint256 transferAmount, uint256 mintAmount) public {
    //     // Bounds the amounts
    //     transferAmount = _bound(transferAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
    //     mintAmount = _bound(mintAmount, transferAmount, SystemConstants.TEA_MAX_SUPPLY);

    //     // Suppose you have a mint function for TEA, otherwise adapt as necessary
    //     tea.mint(bob, mintAmount);

    //     // Bob approves Alice to transfer on his behalf
    //     vm.prank(bob);
    //     tea.setApprovalForAll(alice, true);

    //     // Alice fails to transfer from Bob to this contract
    //     vm.prank(alice);
    //     vm.expectRevert();
    //     tea.safeTransferFrom(bob, address(this), VAULT_ID, transferAmount, "");
    // }

    // function testFuzz_safeTransferFromUnsafeRecipient(uint256 transferAmount, uint256 mintAmount) public {
    //     vm.mockCall(
    //         address(this),
    //         abi.encodeWithSelector(ERC1155TokenReceiver.onERC1155Received.selector),
    //         abi.encode(TEAInstance.mint.selector) // Wrong selector
    //     );

    //     // Bounds the amounts
    //     transferAmount = _bound(transferAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
    //     mintAmount = _bound(mintAmount, transferAmount, SystemConstants.TEA_MAX_SUPPLY);

    //     // Suppose you have a mint function for TEA, otherwise adapt as necessary
    //     tea.mint(bob, mintAmount);

    //     // Bob approves Alice to transfer on his behalf
    //     vm.prank(bob);
    //     tea.setApprovalForAll(alice, true);

    //     // Alice fails to transfer from Bob to this contract
    //     vm.prank(alice);
    //     vm.expectRevert("UNSAFE_RECIPIENT");
    //     tea.safeTransferFrom(bob, address(this), VAULT_ID, transferAmount, "");
    // }

    // function testFuzz_safeTransferFromSafeRecipient(uint256 transferAmount, uint256 mintAmount) public {
    //     vm.mockCall(
    //         address(this),
    //         abi.encodeWithSelector(ERC1155TokenReceiver.onERC1155Received.selector),
    //         abi.encode(ERC1155TokenReceiver.onERC1155Received.selector)
    //     );

    //     // Bounds the amounts
    //     transferAmount = _bound(transferAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
    //     mintAmount = _bound(mintAmount, transferAmount, SystemConstants.TEA_MAX_SUPPLY);

    //     // Suppose you have a mint function for TEA, otherwise adapt as necessary
    //     tea.mint(bob, mintAmount);

    //     // Bob approves Alice to transfer on his behalf
    //     vm.prank(bob);
    //     tea.setApprovalForAll(alice, true);

    //     // Expecting the transfer event
    //     vm.expectEmit();
    //     emit TransferSingle(alice, bob, address(this), VAULT_ID, transferAmount);

    //     // Alice transfers from Bob to this contract
    //     vm.prank(alice);
    //     tea.safeTransferFrom(bob, address(this), VAULT_ID, transferAmount, "");

    //     // Asserting the post-transfer vaultState
    //     assertEq(tea.balanceOf(alice, VAULT_ID), 0);
    //     assertEq(tea.balanceOf(bob, VAULT_ID), mintAmount - transferAmount);
    //     assertEq(tea.balanceOf(address(this), VAULT_ID), transferAmount);
    // }

    //     ////////////////////////////////
    //     //// safeBatchTransferFrom ////
    //     //////////////////////////////

    //     function _convertToDynamicArray(uint256 a, uint256 b) private pure returns (uint256[] memory arrOut) {
    //         arrOut = new uint256[](2);
    //         arrOut[0] = a;
    //         arrOut[1] = b;
    //     }

    //     function testFuzz_safeBatchTransferFrom(
    //         uint256 transferAmountA,
    //         uint256 transferAmountB,
    //         uint256 mintAmountA,
    //         uint256 mintAmountB
    //     ) public {
    //         transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
    //         mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY);
    //         tea.mint(bob,  mintAmountA);

    //         transferAmountB = _bound(transferAmountB, 1, SystemConstants.TEA_MAX_SUPPLY);
    //         mintAmountB = _bound(mintAmountB, transferAmountB, SystemConstants.TEA_MAX_SUPPLY);
    //         tea.mint(bob, vaultIdB, mintAmountB);

    //         // Bob approves Alice to transfer on his behalf
    //         vm.prank(bob);
    //         tea.setApprovalForAll(alice, true);

    //         // Expecting the batch transfer event
    //         vm.expectEmit();
    //         emit TransferBatch(
    //             alice,
    //             bob,
    //             charlie,
    //             _convertToDynamicArray(VAULT_ID, vaultIdB),
    //             _convertToDynamicArray(transferAmountA, transferAmountB)
    //         );

    //         // Alice batch transfers from Bob to Charlie
    //         vm.prank(alice);
    //         tea.safeBatchTransferFrom(
    //             bob,
    //             charlie,
    //             _convertToDynamicArray(VAULT_ID, vaultIdB),
    //             _convertToDynamicArray(transferAmountA, transferAmountB),
    //             ""
    //         );

    //         assertEq(tea.balanceOf(bob, VAULT_ID), mintAmountA - transferAmountA);
    //         assertEq(tea.balanceOf(charlie, VAULT_ID), transferAmountA);
    //         assertEq(tea.balanceOf(bob, vaultIdB), mintAmountB - transferAmountB);
    //         assertEq(tea.balanceOf(charlie, vaultIdB), transferAmountB);
    //     }

    //     function testFuzz_safeBatchTransferFromNotAuthorized(
    //         uint256 transferAmountA,
    //         uint256 transferAmountB,
    //         uint256 mintAmountA,
    //         uint256 mintAmountB
    //     ) public {
    //         transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
    //         mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY);
    //         tea.mint(bob,  mintAmountA);

    //         transferAmountB = _bound(transferAmountB, 1, SystemConstants.TEA_MAX_SUPPLY);
    //         mintAmountB = _bound(mintAmountB, transferAmountB, SystemConstants.TEA_MAX_SUPPLY);
    //         tea.mint(bob, vaultIdB, mintAmountB);

    //         // Bob approves Alice to transfer on his behalf
    //         vm.prank(bob);
    //         tea.setApprovalForAll(alice, true);

    //         // Charlie fails to batch transfer from Bob
    //         vm.prank(charlie);
    //         vm.expectRevert("NOT_AUTHORIZED");
    //         tea.safeBatchTransferFrom(
    //             bob,
    //             alice,
    //             _convertToDynamicArray(VAULT_ID, vaultIdB),
    //             _convertToDynamicArray(transferAmountA, transferAmountB),
    //             ""
    //         );
    //     }

    //     function testFuzz_safeBatchTransferFromExceedBalance(
    //         uint256 transferAmountA,
    //         uint256 transferAmountB,
    //         uint256 mintAmountA,
    //         uint256 mintAmountB
    //     ) public {
    //         transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
    //         mintAmountA = _bound(mintAmountA, 0, transferAmountA - 1);
    //         tea.mint(bob,  mintAmountA);

    //         transferAmountB = _bound(transferAmountB, 1, SystemConstants.TEA_MAX_SUPPLY);
    //         mintAmountB = _bound(mintAmountB, 0, transferAmountB - 1);
    //         tea.mint(bob, vaultIdB, mintAmountB);

    //         // Bob approves Alice to transfer on his behalf
    //         vm.prank(bob);
    //         tea.setApprovalForAll(alice, true);

    //         // Alice tries to batch transfer from Bob but should fail
    //         vm.prank(alice);
    //         vm.expectRevert();
    //         tea.safeBatchTransferFrom(
    //             bob,
    //             charlie,
    //             _convertToDynamicArray(VAULT_ID, vaultIdB),
    //             _convertToDynamicArray(transferAmountA, transferAmountB),
    //             ""
    //         );
    //     }

    //     function testFuzz_safeBatchTransferFromToContract(
    //         uint256 transferAmountA,
    //         uint256 transferAmountB,
    //         uint256 mintAmountA,
    //         uint256 mintAmountB
    //     ) public {
    //         transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
    //         mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY);
    //         tea.mint(bob,  mintAmountA);

    //         transferAmountB = _bound(transferAmountB, 1, SystemConstants.TEA_MAX_SUPPLY);
    //         mintAmountB = _bound(mintAmountB, transferAmountB, SystemConstants.TEA_MAX_SUPPLY);
    //         tea.mint(bob, vaultIdB, mintAmountB);

    //         // Bob approves Alice to transfer on his behalf
    //         vm.prank(bob);
    //         tea.setApprovalForAll(alice, true);

    //         // Alice fails to batch transfer from Bob to this contract
    //         vm.prank(alice);
    //         vm.expectRevert();
    //         tea.safeBatchTransferFrom(
    //             bob,
    //             address(this),
    //             _convertToDynamicArray(VAULT_ID, vaultIdB),
    //             _convertToDynamicArray(transferAmountA, transferAmountB),
    //             ""
    //         );
    //     }

    //     function testFuzz_safeBatchTransferFromUnsafeRecipient(
    //         uint256 transferAmountA,
    //         uint256 transferAmountB,
    //         uint256 mintAmountA,
    //         uint256 mintAmountB
    //     ) public {
    //         vm.mockCall(
    //             address(this),
    //             abi.encodeWithSelector(ERC1155TokenReceiver.onERC1155BatchReceived.selector),
    //             abi.encode(TEAInstance.mint.selector) // Wrong selector
    //         );

    //         transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
    //         mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY);
    //         tea.mint(bob,  mintAmountA);

    //         transferAmountB = _bound(transferAmountB, 1, SystemConstants.TEA_MAX_SUPPLY);
    //         mintAmountB = _bound(mintAmountB, transferAmountB, SystemConstants.TEA_MAX_SUPPLY);
    //         tea.mint(bob, vaultIdB, mintAmountB);

    //         // Bob approves Alice to transfer on his behalf
    //         vm.prank(bob);
    //         tea.setApprovalForAll(alice, true);

    //         // Alice fails to batch transfer from Bob to an unsafe recipient
    //         vm.prank(alice);
    //         vm.expectRevert();
    //         tea.safeBatchTransferFrom(
    //             bob,
    //             address(this),
    //             _convertToDynamicArray(VAULT_ID, vaultIdB),
    //             _convertToDynamicArray(transferAmountA, transferAmountB),
    //             ""
    //         );
    //     }
    // }

    // contract TEATestInternal is Test, TEA(address(0), address(0)) {
    //     address alice;
    //     address bob;
    //     address charlie;

    //     function setUp() public {
    //         vm.createSelectFork("mainnet", 18128102);

    //         alice = vm.addr(1);
    //         bob = vm.addr(2);
    //         charlie = vm.addr(3);
    //     }

    //     function updateLPerIssuanceParams(
    //         bool sirIsCaller,
    //         uint256 vaultId,
    //         address lper0,
    //         address lper1
    //     ) internal override returns (uint80 unclaimedRewards) {}

    //     function testFuzz_mint(uint256 vaultId, uint256 mintAmountA, uint256 mintAmountB) public {
    //         mintAmountA = _bound(mintAmountA, 1, SystemConstants.TEA_MAX_SUPPLY - 1);

    //         mint(alice, vaultId, mintAmountA);
    //         assertEq(balanceOf[alice][vaultId], mintAmountA);
    //         assertEq(totalSupply[vaultId], mintAmountA);

    //         mintAmountB = _bound(mintAmountB, 1, SystemConstants.TEA_MAX_SUPPLY - mintAmountA);

    //         vm.expectEmit();
    //         emit TransferSingle(msg.sender, address(0), bob, vaultId, mintAmountB);
    //         mint(bob, vaultId, mintAmountB);
    //         assertEq(balanceOf[bob][vaultId], mintAmountB);
    //         assertEq(totalSupply[vaultId], mintAmountA + mintAmountB);
    //     }

    //     function testFuzz_mintFails(uint256 vaultId, uint256 mintAmountA, uint256 mintAmountB) public {
    //         mintAmountA = _bound(mintAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
    //         mint(alice, vaultId, mintAmountA);

    //         mintAmountB = _bound(mintAmountB, SystemConstants.TEA_MAX_SUPPLY - mintAmountA + 1, type(uint256).max);
    //         vm.expectRevert();
    //         mint(bob, vaultId, mintAmountB);
    //     }

    //     function testFuzz_burn(uint256 vaultId, uint256 mintAmountA, uint256 mintAmountB, uint256 burnAmountB) public {
    //         mintAmountA = _bound(mintAmountA, 1, SystemConstants.TEA_MAX_SUPPLY - 1);
    //         mintAmountB = _bound(mintAmountB, 1, SystemConstants.TEA_MAX_SUPPLY - mintAmountA);
    //         burnAmountB = _bound(burnAmountB, 0, mintAmountB);

    //         mint(alice, vaultId, mintAmountA);
    //         mint(bob, vaultId, mintAmountB);

    //         vm.expectEmit();
    //         emit TransferSingle(msg.sender, bob, address(0), vaultId, burnAmountB);
    //         burn(bob, vaultId, burnAmountB);

    //         assertEq(balanceOf[bob][vaultId], mintAmountB - burnAmountB);
    //         assertEq(totalSupply[vaultId], mintAmountA + mintAmountB - burnAmountB);
    //     }

    //     function testFuzz_burnMoreThanBalance(
    //         uint256 vaultId,
    //         uint256 mintAmountA,
    //         uint256 mintAmountB,
    //         uint256 burnAmountB
    //     ) public {
    //         mintAmountA = _bound(mintAmountA, 1, SystemConstants.TEA_MAX_SUPPLY - 1);
    //         mintAmountB = _bound(mintAmountB, 1, SystemConstants.TEA_MAX_SUPPLY - mintAmountA);
    //         burnAmountB = _bound(burnAmountB, mintAmountB + 1, type(uint256).max);

    //         mint(alice, vaultId, mintAmountA);
    //         mint(bob, vaultId, mintAmountB);

    //         vm.expectRevert();
    //         burn(bob, vaultId, burnAmountB);
    //     }
}
