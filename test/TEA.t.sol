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
import {Fees} from "src/libraries/Fees.sol";
import {FullMath} from "src/libraries/FullMath.sol";

contract TEATestConstants {
    uint48 constant VAULT_ID = 9; // we test with vault 9
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
        mint(account, VAULT_ID, amount);
    }

    function mint(address account, uint48 vaultId, uint256 amount) public {
        assert(totalSupplyAndBalanceVault[vaultId].totalSupply + amount <= SystemConstants.TEA_MAX_SUPPLY);
        totalSupplyAndBalanceVault[vaultId].totalSupply += uint128(amount);

        if (account == address(this)) totalSupplyAndBalanceVault[vaultId].balanceVault += uint128(amount);
        else balances[account][vaultId] += amount;
    }
}

contract TEATest is Test, TEATestConstants {
    error NotAuthorized();
    error UnsafeRecipient();

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
        // vm.createSelectFork("mainnet", 18128102);

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

    function testFuzz_safeTransferFromVaultFails(
        uint256 operatorId,
        uint256 toId,
        uint256 transferAmount,
        uint256 mintAmount
    ) public {
        address from = address(tea);
        address operator = _idToAddress(operatorId);
        address to = _idToAddress(toId);

        // Bounds the amounts
        transferAmount = _bound(transferAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmount = _bound(mintAmount, transferAmount, SystemConstants.TEA_MAX_SUPPLY);

        // Suppose you have a mint function for TEA, otherwise adapt as necessary
        tea.mint(from, mintAmount);

        // From approves operator to transfer on his behalf
        vm.prank(from);
        tea.setApprovalForAll(operator, true);

        // Transfer
        vm.prank(operator);
        vm.expectRevert();
        tea.safeTransferFrom(from, to, VAULT_ID, transferAmount, "");
    }

    function testFuzz_safeTransferFromExceedBalance(
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
        mintAmount = _bound(mintAmount, 0, transferAmount - 1);

        // Suppose you have a mint function for TEA, otherwise adapt as necessary
        if (mintAmount > 0) tea.mint(from, mintAmount);

        // Bob approves Alice to transfer on his behalf
        vm.prank(from);
        tea.setApprovalForAll(operator, true);

        // Alice transfers from Bob to herself
        vm.prank(operator);
        vm.expectRevert();
        tea.safeTransferFrom(from, to, VAULT_ID, transferAmount, "");
    }

    function testFuzz_safeTransferFromNotAuthorized(
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

        // To ensure that the operator is not the same as the sender
        vm.assume(operator != from);

        // Bounds the amounts
        transferAmount = _bound(transferAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmount = _bound(mintAmount, transferAmount, SystemConstants.TEA_MAX_SUPPLY);

        // Suppose you have a mint function for TEA, otherwise adapt as necessary
        tea.mint(from, mintAmount);

        // Charlie fails to transfer from Bob
        vm.prank(operator);
        vm.expectRevert(NotAuthorized.selector);
        tea.safeTransferFrom(from, to, VAULT_ID, transferAmount, "");
    }

    function testFuzz_safeTransferFromUnknownContract(
        uint256 fromId,
        uint256 operatorId,
        uint256 transferAmount,
        uint256 mintAmount
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = address(this);

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

        // Alice transfers from Bob to Charlie
        vm.prank(operator);
        vm.expectRevert();
        tea.safeTransferFrom(from, to, VAULT_ID, transferAmount, "");
    }

    function testFuzz_safeTransferFromUnsafeRecipient(
        uint256 fromId,
        uint256 operatorId,
        uint256 transferAmount,
        uint256 mintAmount
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = vm.addr(4);

        vm.mockCall(
            address(vm.addr(4)),
            abi.encodeWithSelector(ERC1155TokenReceiver.onERC1155Received.selector),
            abi.encode(TEA.safeBatchTransferFrom.selector) // Wrong selector
        );

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

        // Alice transfers from Bob to Charlie
        vm.prank(operator);
        vm.expectRevert(UnsafeRecipient.selector);
        tea.safeTransferFrom(from, to, VAULT_ID, transferAmount, "");
    }

    // TEST SOMEWHERE THAT TOKENS MINTED AS POL DO NOT COUNT TOWARDS SIR REWARDS

    ////////////////////////////////
    //// safeBatchTransferFrom ////
    //////////////////////////////

    function _convertToDynamicArray(uint256 a, uint256 b) private pure returns (uint256[] memory arrOut) {
        arrOut = new uint256[](2);
        arrOut[0] = a;
        arrOut[1] = b;
    }

    function testFuzz_safeBatchTransferFrom(
        uint256 fromId,
        uint256 operatorId,
        uint256 toId,
        uint256 transferAmountA,
        uint256 transferAmountB,
        uint256 mintAmountA,
        uint256 mintAmountB,
        uint48 vaultIdB
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        // Valt liquidity can never be transfered out
        vm.assume(from != address(tea));

        transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, mintAmountA);

        transferAmountB = _bound(transferAmountB, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountB = _bound(mintAmountB, transferAmountB, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, vaultIdB, mintAmountB);

        // Bob approves Alice to transfer on his behalf
        vm.prank(from);
        tea.setApprovalForAll(operator, true);

        // Expecting the batch transfer event
        vm.expectEmit();
        emit TransferBatch(
            operator,
            from,
            to,
            _convertToDynamicArray(VAULT_ID, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB)
        );

        // Alice batch transfers from Bob to Charlie
        vm.prank(operator);
        tea.safeBatchTransferFrom(
            from,
            to,
            _convertToDynamicArray(VAULT_ID, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB),
            ""
        );

        if (operator != from && operator != to) {
            assertEq(tea.balanceOf(operator, VAULT_ID), 0);
            assertEq(tea.balanceOf(operator, vaultIdB), 0);
        }
        assertEq(tea.balanceOf(from, VAULT_ID), from == to ? mintAmountA : mintAmountA - transferAmountA);
        assertEq(tea.balanceOf(to, VAULT_ID), to == from ? mintAmountA : transferAmountA);
        assertEq(tea.balanceOf(from, vaultIdB), from == to ? mintAmountB : mintAmountB - transferAmountB);
        assertEq(tea.balanceOf(to, vaultIdB), to == from ? mintAmountB : transferAmountB);
    }

    function testFuzz_safeBatchTransferFromVaultFails(
        uint256 operatorId,
        uint256 toId,
        uint256 transferAmountA,
        uint256 transferAmountB,
        uint256 mintAmountA,
        uint256 mintAmountB,
        uint48 vaultIdB
    ) public {
        address operator = _idToAddress(operatorId);
        address from = address(tea);
        address to = _idToAddress(toId);

        transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, mintAmountA);

        transferAmountB = _bound(transferAmountB, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountB = _bound(mintAmountB, transferAmountB, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, vaultIdB, mintAmountB);

        // Bob approves Alice to transfer on his behalf
        vm.prank(from);
        tea.setApprovalForAll(operator, true);

        // Alice batch transfers from Bob to Charlie
        vm.prank(operator);
        vm.expectRevert();
        tea.safeBatchTransferFrom(
            from,
            to,
            _convertToDynamicArray(VAULT_ID, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB),
            ""
        );
    }

    function testFuzz_safeBatchTransferFromExceedBalance(
        uint256 fromId,
        uint256 operatorId,
        uint256 toId,
        uint256 transferAmountA,
        uint256 transferAmountB,
        uint256 mintAmountA,
        uint256 mintAmountB,
        uint48 vaultIdB
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        // Valt liquidity can never be transfered out
        vm.assume(from != address(tea));

        transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountA = _bound(mintAmountA, 0, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, mintAmountA);

        transferAmountB = _bound(transferAmountB, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountB = _bound(mintAmountB, 0, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, vaultIdB, mintAmountB);

        // Ensure that 1 transfer amount exceeds the balance
        vm.assume(mintAmountA < transferAmountA || mintAmountB < transferAmountB);

        // Bob approves Alice to transfer on his behalf
        vm.prank(from);
        tea.setApprovalForAll(operator, true);

        // Alice batch transfers from Bob to Charlie
        vm.prank(operator);
        vm.expectRevert();
        tea.safeBatchTransferFrom(
            from,
            to,
            _convertToDynamicArray(VAULT_ID, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB),
            ""
        );
    }

    function testFuzz_safeBatchTransferFromNotAuthorized(
        uint256 fromId,
        uint256 operatorId,
        uint256 toId,
        uint256 transferAmountA,
        uint256 transferAmountB,
        uint256 mintAmountA,
        uint256 mintAmountB,
        uint48 vaultIdB
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        // Valt liquidity can never be transfered out
        vm.assume(from != address(tea));

        // To ensure that the operator is not the same as the sender
        vm.assume(operator != from);

        transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, mintAmountA);

        transferAmountB = _bound(transferAmountB, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountB = _bound(mintAmountB, transferAmountB, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, vaultIdB, mintAmountB);

        // Alice batch transfers from Bob to Charlie
        vm.prank(operator);
        vm.expectRevert(NotAuthorized.selector);
        tea.safeBatchTransferFrom(
            from,
            to,
            _convertToDynamicArray(VAULT_ID, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB),
            ""
        );
    }

    function testFuzz_safeBatchTransferFromUnknownContract(
        uint256 fromId,
        uint256 operatorId,
        uint256 transferAmountA,
        uint256 transferAmountB,
        uint256 mintAmountA,
        uint256 mintAmountB,
        uint48 vaultIdB
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = address(this);

        // Valt liquidity can never be transfered out
        vm.assume(from != address(tea));

        transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, mintAmountA);

        transferAmountB = _bound(transferAmountB, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountB = _bound(mintAmountB, transferAmountB, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, vaultIdB, mintAmountB);

        // Bob approves Alice to transfer on his behalf
        vm.prank(from);
        tea.setApprovalForAll(operator, true);

        // Alice batch transfers from Bob to Charlie
        vm.prank(operator);
        vm.expectRevert();
        tea.safeBatchTransferFrom(
            from,
            to,
            _convertToDynamicArray(VAULT_ID, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB),
            ""
        );
    }

    function testFuzz_safeBatchTransferFromUnsafeRecipient(
        uint256 fromId,
        uint256 operatorId,
        uint256 transferAmountA,
        uint256 transferAmountB,
        uint256 mintAmountA,
        uint256 mintAmountB,
        uint48 vaultIdB
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = vm.addr(4);

        vm.mockCall(
            address(vm.addr(4)),
            abi.encodeWithSelector(ERC1155TokenReceiver.onERC1155BatchReceived.selector),
            abi.encode(TEA.safeBatchTransferFrom.selector) // Wrong selector
        );

        // Valt liquidity can never be transfered out
        vm.assume(from != address(tea));

        transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, mintAmountA);

        transferAmountB = _bound(transferAmountB, 1, SystemConstants.TEA_MAX_SUPPLY);
        mintAmountB = _bound(mintAmountB, transferAmountB, SystemConstants.TEA_MAX_SUPPLY);
        tea.mint(from, vaultIdB, mintAmountB);

        // Bob approves Alice to transfer on his behalf
        vm.prank(from);
        tea.setApprovalForAll(operator, true);

        // Alice batch transfers from Bob to Charlie
        vm.prank(operator);
        vm.expectRevert(UnsafeRecipient.selector);
        tea.safeBatchTransferFrom(
            from,
            to,
            _convertToDynamicArray(VAULT_ID, vaultIdB),
            _convertToDynamicArray(transferAmountA, transferAmountB),
            ""
        );
    }

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

contract TEATestInternal is TEA, Test {
    uint48 constant VAULT_ID = 42;

    MockERC20 collateral;

    address alice;
    address bob;
    address charlie;

    constructor() TEA(address(0), address(0)) {
        collateral = new MockERC20("Collateral token", "TKN", 18);
        alice = address(1);
        bob = address(2);
        charlie = address(3);
    }

    function setUp() public {
        collateral = new MockERC20("Collateral token", "TKN", 18);

        alice = vm.addr(1);
        bob = vm.addr(2);
        charlie = vm.addr(3);
    }

    function testFuzz_mint1stTime(
        uint8 lpFee,
        uint8 tax,
        uint144 reserveLPers,
        uint144 collateralDeposited,
        uint256 collateralTotalSupply
    ) public {
        // Bounds the amounts
        collateralDeposited = uint144(_bound(collateralDeposited, 0, collateralTotalSupply));
        reserveLPers = uint144(_bound(reserveLPers, 0, collateralTotalSupply - collateralDeposited));
        reserveLPers = uint144(_bound(reserveLPers, 0, type(uint144).max - collateralDeposited));

        VaultStructs.Reserves memory reserves = VaultStructs.Reserves({
            reserveApes: 0,
            reserveLPers: reserveLPers,
            tickPriceX42: 0
        });

        // Mint collateral
        collateral.mint(alice, collateralTotalSupply - collateralDeposited - reserveLPers);
        collateral.mint(address(this), collateralDeposited + reserveLPers);

        // Mint for the first time
        (uint256 amount, ) = mint(
            address(collateral),
            bob,
            VAULT_ID,
            VaultStructs.SystemParameters({
                tsIssuanceStart: 0,
                baseFee: 0,
                lpFee: lpFee,
                mintingStopped: false,
                cumTax: 0
            }),
            VaultStructs.VaultIssuanceParams({tax: tax, tsLastUpdate: 0, cumSIRPerTEAx96: 0}),
            reserves,
            collateralDeposited
        );

        uint256 amountPol = balanceOf(address(this), VAULT_ID);

        // When minting for the first time, all collateral in excess of collateralIn is minted as POL
        uint144 collateralIn;
        uint144 collectedFee;
        uint144 polBalance;
        {
            uint144 lpersFee;
            uint144 polFee;
            (collateralIn, collectedFee, lpersFee, polFee) = Fees.hiddenFeeTEA(collateralDeposited, lpFee, tax);
            polBalance = reserveLPers + lpersFee + polFee;
        }

        assertEq(reserves.reserveLPers, reserveLPers + collateralDeposited - collectedFee, "LP reserve wrong");
        assertEq(amount, balanceOf(bob, VAULT_ID), "Amount of TEA wrong");

        if (collateralTotalSupply <= SystemConstants.TEA_MAX_SUPPLY) {
            assertEq(amount, collateralIn);
            assertEq(amountPol, polBalance);
        } else {
            // When the token supply is larger than TEA_MAX_SUPPLY, we scale down the ratio of TEA minted to collateral
            uint256 amountE = FullMath.mulDiv(SystemConstants.TEA_MAX_SUPPLY, collateralIn, collateralTotalSupply);
            if (polBalance == 0) assertEq(amount, amountE);
            else if (collateralIn == 0) assertEq(amount, 0);
            else {
                // Bounds for the error
                assertLe(amount, amountE);
                uint256 maxErr = uint256(collateralIn - 1) / polBalance + 1;
                if (maxErr < amountE) assertGe(amount, amountE - maxErr);
            }

            assertEq(amountPol, FullMath.mulDiv(SystemConstants.TEA_MAX_SUPPLY, polBalance, collateralTotalSupply));
        }
    }
}
