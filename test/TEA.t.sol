// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TEA} from "src/TEA.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {VaultExternal} from "src/libraries/VaultExternal.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {MockERC20} from "src/test/MockERC20.sol";
import {Fees} from "src/libraries/Fees.sol";
import {FullMath} from "src/libraries/FullMath.sol";
import {ErrorComputation} from "./ErrorComputation.sol";

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
            _paramsById.push(
                SirStructs.VaultParameters({debtToken: address(0), collateralToken: address(0), leverageTier: 0})
            );
        }

        _paramsById[VAULT_ID] = SirStructs.VaultParameters({
            debtToken: Addresses.ADDR_USDT,
            collateralToken: collateral_,
            leverageTier: LEVERAGE_TIER
        });

        _paramsById[MAX_VAULT_ID] = SirStructs.VaultParameters({
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

    function test_initialConditions() public view {
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

        transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY - 1);
        mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY - 1);
        tea.mint(from, mintAmountA);

        transferAmountB = _bound(
            transferAmountB,
            1,
            SystemConstants.TEA_MAX_SUPPLY - (VAULT_ID == vaultIdB ? mintAmountA : 0)
        );
        mintAmountB = _bound(
            mintAmountB,
            transferAmountB,
            SystemConstants.TEA_MAX_SUPPLY - (VAULT_ID == vaultIdB ? mintAmountA : 0)
        );
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

        if (VAULT_ID != vaultIdB) {
            if (from == to) {
                assertEq(tea.balanceOf(from, VAULT_ID), mintAmountA);
                assertEq(tea.balanceOf(from, vaultIdB), mintAmountB);
            } else {
                assertEq(tea.balanceOf(from, VAULT_ID), mintAmountA - transferAmountA);
                assertEq(tea.balanceOf(to, VAULT_ID), transferAmountA);
                assertEq(tea.balanceOf(from, vaultIdB), mintAmountB - transferAmountB);
                assertEq(tea.balanceOf(to, vaultIdB), transferAmountB);
            }
        } else {
            if (from == to) {
                assertEq(tea.balanceOf(from, VAULT_ID), mintAmountA + mintAmountB);
            } else {
                assertEq(tea.balanceOf(from, VAULT_ID), mintAmountA + mintAmountB - transferAmountA - transferAmountB);
                assertEq(tea.balanceOf(to, VAULT_ID), transferAmountA + transferAmountB);
            }
        }
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

        transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY - 1);
        mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY - 1);
        tea.mint(from, mintAmountA);

        transferAmountB = _bound(
            transferAmountB,
            1,
            SystemConstants.TEA_MAX_SUPPLY - (VAULT_ID == vaultIdB ? mintAmountA : 0)
        );
        mintAmountB = _bound(
            mintAmountB,
            transferAmountB,
            SystemConstants.TEA_MAX_SUPPLY - (VAULT_ID == vaultIdB ? mintAmountA : 0)
        );
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
        mintAmountA = _bound(mintAmountA, 0, SystemConstants.TEA_MAX_SUPPLY - 1);
        tea.mint(from, mintAmountA);

        mintAmountB = _bound(
            mintAmountB,
            0,
            vaultIdB != VAULT_ID ? SystemConstants.TEA_MAX_SUPPLY - 1 : SystemConstants.TEA_MAX_SUPPLY - 1 - mintAmountA
        );
        transferAmountB = _bound(
            transferAmountB,
            transferAmountA <= mintAmountA ? mintAmountB + 1 : 1,
            SystemConstants.TEA_MAX_SUPPLY
        );

        tea.mint(from, vaultIdB, mintAmountB);

        // Ensure that 1 transfer amount exceeds the balance
        if (vaultIdB == VAULT_ID)
            vm.assume(mintAmountA + mintAmountB < transferAmountA || mintAmountA + mintAmountB < transferAmountB);

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

        transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY - 1);
        mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY - 1);
        tea.mint(from, mintAmountA);

        transferAmountB = _bound(
            transferAmountB,
            1,
            SystemConstants.TEA_MAX_SUPPLY - (VAULT_ID == vaultIdB ? mintAmountA : 0)
        );
        mintAmountB = _bound(
            mintAmountB,
            transferAmountB,
            SystemConstants.TEA_MAX_SUPPLY - (VAULT_ID == vaultIdB ? mintAmountA : 0)
        );
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

        transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY - 1);
        mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY - 1);
        tea.mint(from, mintAmountA);

        transferAmountB = _bound(
            transferAmountB,
            1,
            SystemConstants.TEA_MAX_SUPPLY - (VAULT_ID == vaultIdB ? mintAmountA : 0)
        );
        mintAmountB = _bound(
            mintAmountB,
            transferAmountB,
            SystemConstants.TEA_MAX_SUPPLY - (VAULT_ID == vaultIdB ? mintAmountA : 0)
        );
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

        transferAmountA = _bound(transferAmountA, 1, SystemConstants.TEA_MAX_SUPPLY - 1);
        mintAmountA = _bound(mintAmountA, transferAmountA, SystemConstants.TEA_MAX_SUPPLY - 1);
        tea.mint(from, mintAmountA);

        transferAmountB = _bound(
            transferAmountB,
            1,
            SystemConstants.TEA_MAX_SUPPLY - (VAULT_ID == vaultIdB ? mintAmountA : 0)
        );
        mintAmountB = _bound(
            mintAmountB,
            transferAmountB,
            SystemConstants.TEA_MAX_SUPPLY - (VAULT_ID == vaultIdB ? mintAmountA : 0)
        );
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
}

contract TEAInternal is TEA(address(0), address(0)), Test {
    uint48 constant VAULT_ID = 42;
    uint40 constant MAX_TS = 599 * 365 days;

    MockERC20 collateral;

    address alice;

    uint256[] tsBalance;
    uint256[] senderTeaBalance;
    uint256[] polTeaBalance;

    struct TestMintParams {
        uint144 reserveLPers;
        uint144 collateralDeposited;
        uint40 tsCheck;
    }

    struct TestBurnParams {
        uint144 reserveLPers;
        uint256 tokensBurnt;
        uint40 tsCheck;
    }

    function setUp() public {
        collateral = new MockERC20("Collateral token", "TKN", 18);

        alice = vm.addr(1);
    }

    function _verifyMintAmounts(
        TestMintParams memory testMintParams,
        uint256 collateralTotalSupply0
    ) private view returns (SirStructs.Fees memory fees, uint256 senderAmount) {
        fees = Fees.feeMintTEA(testMintParams.collateralDeposited, _systemParams.lpFee.fee);

        senderAmount =
            senderTeaBalance[tsBalance.length - 1] -
            (tsBalance.length == 1 ? 0 : senderTeaBalance[tsBalance.length - 2]);
        uint256 POLAmount = polTeaBalance[polTeaBalance.length - 1] -
            (polTeaBalance.length == 1 ? 0 : polTeaBalance[polTeaBalance.length - 2]);

        uint256 totalTeaMinted;
        uint256 collateralFeeToProtocol;
        if (tsBalance.length == 1) {
            // First TEA mint
            uint256 newCollateralTotalSupply = testMintParams.collateralDeposited + collateralTotalSupply0;

            // POL gets fee charged to the gentleman + whatever was already from the apes
            collateralFeeToProtocol = uint256(testMintParams.reserveLPers) + fees.collateralFeeToLPers;

            if (newCollateralTotalSupply <= SystemConstants.TEA_MAX_SUPPLY / 1e6) {
                totalTeaMinted = 1e6 * uint256(fees.collateralInOrWithdrawn + collateralFeeToProtocol);
            } else {
                // When the token supply is larger than TEA_MAX_SUPPLY/1e6, we scale down the ratio of TEA minted to collateral
                totalTeaMinted = FullMath.mulDiv(
                    SystemConstants.TEA_MAX_SUPPLY,
                    fees.collateralInOrWithdrawn + collateralFeeToProtocol,
                    newCollateralTotalSupply
                );
            }
        } else {
            // Not the first mint
            totalTeaMinted = FullMath.mulDiv(
                totalSupplyAndBalanceVault[VAULT_ID].totalSupply - senderAmount - POLAmount,
                fees.collateralInOrWithdrawn + fees.collateralFeeToLPers,
                testMintParams.reserveLPers
            );

            // POL gets fee charged to the gentleman
            collateralFeeToProtocol = fees.collateralFeeToLPers;
        }

        // Ensure that the total minted TEA is split correctly between sender and POL
        assertEq(
            senderAmount,
            FullMath.mulDiv(
                fees.collateralInOrWithdrawn,
                totalTeaMinted,
                fees.collateralInOrWithdrawn + collateralFeeToProtocol
            ),
            "Sender minted TEA amount is wrong"
        );
        assertEq(
            POLAmount,
            FullMath.mulDivRoundingUp(
                collateralFeeToProtocol,
                totalTeaMinted,
                fees.collateralInOrWithdrawn + collateralFeeToProtocol
            ),
            "POL minted TEA amount is wrong"
        );
    }

    function _verifyBurnAmounts(
        TestBurnParams memory testBurnParams,
        uint256 totalSupply0
    ) private view returns (uint144 collateralOut) {
        uint256 senderAmount = senderTeaBalance[tsBalance.length - 2] - senderTeaBalance[tsBalance.length - 1];
        uint256 POLAmount = polTeaBalance[polTeaBalance.length - 1] - polTeaBalance[polTeaBalance.length - 2];
        assertLe(POLAmount, 0, "POL minted TEA amount is wrong");
        assertEq(senderAmount, testBurnParams.tokensBurnt, "Sender burnt TEA amount is wrong");

        // Check collateral received by the sender is correct
        collateralOut = uint144(FullMath.mulDiv(testBurnParams.reserveLPers, testBurnParams.tokensBurnt, totalSupply0));
    }

    function _verifyReserveLPers(
        SirStructs.Reserves memory reserves,
        TestMintParams memory testMintParams
    ) private pure {
        assertEq(
            reserves.reserveLPers,
            testMintParams.reserveLPers + testMintParams.collateralDeposited,
            "LP reserve wrong"
        );
    }

    function _verifySIRRewards(uint40 tsCheck) private {
        vm.warp(tsCheck);

        uint256 aggBalanceSender;
        for (uint256 i = 0; i < tsBalance.length; i++) {
            if (tsBalance[i] <= tsCheck) aggBalanceSender += senderTeaBalance[i];
        }
        uint80 rewardsSender = unclaimedRewards(
            VAULT_ID,
            msg.sender,
            senderTeaBalance[tsBalance.length - 1],
            cumulativeSIRPerTEA(VAULT_ID)
        );

        if (aggBalanceSender == 0 || vaultIssuanceParams[VAULT_ID].tax == 0) assertEq(rewardsSender, 0);
        else {
            uint256 timestamp3Years = TIMESTAMP_ISSUANCE_START + SystemConstants.THREE_YEARS;
            uint256 rewardsE;
            uint256 maxErr;
            for (uint256 i = 0; i < tsBalance.length; i++) {
                if (tsBalance[i] <= tsCheck && senderTeaBalance[i] > 0) {
                    uint256 timestampStart = tsBalance[i];
                    uint256 tsEnd = i == tsBalance.length - 1 ? tsCheck : tsBalance[i + 1];
                    if (timestampStart <= timestamp3Years && tsEnd >= timestamp3Years) {
                        rewardsE += SystemConstants.LP_ISSUANCE_FIRST_3_YEARS * (timestamp3Years - timestampStart);
                        rewardsE += SystemConstants.ISSUANCE * (tsEnd - timestamp3Years);
                        maxErr += ErrorComputation.maxErrorBalance(96, senderTeaBalance[i], 2);
                    } else if (timestampStart <= timestamp3Years && tsEnd <= timestamp3Years) {
                        rewardsE += SystemConstants.LP_ISSUANCE_FIRST_3_YEARS * (tsEnd - timestampStart);
                        maxErr += ErrorComputation.maxErrorBalance(96, senderTeaBalance[i], 1);
                    } else {
                        rewardsE += SystemConstants.ISSUANCE * (tsEnd - timestampStart);
                        maxErr += ErrorComputation.maxErrorBalance(96, senderTeaBalance[i], 1);
                    }
                }
            }

            assertLe(rewardsSender, rewardsE);
            assertApproxEqAbs(rewardsSender, rewardsE, maxErr);
        }

        uint256 rewardsPOL = unclaimedRewards(
            VAULT_ID,
            address(this),
            balanceOf(address(this), VAULT_ID),
            cumulativeSIRPerTEA(VAULT_ID)
        );
        assertEq(rewardsPOL, 0);
    }

    function testFuzz_mint1stTime(
        TestMintParams memory testMintParams,
        uint16 lpFee,
        uint8 tax,
        uint256 collateralTotalSupply0
    ) public returns (SirStructs.Reserves memory reserves) {
        collateralTotalSupply0 = _bound(collateralTotalSupply0, 0, type(uint256).max - 1);

        // Bounds the amounts
        testMintParams.collateralDeposited = uint144(
            _bound(testMintParams.collateralDeposited, 1, type(uint256).max - collateralTotalSupply0)
        );
        testMintParams.reserveLPers = uint144(
            _bound(testMintParams.reserveLPers, 0, type(uint144).max - testMintParams.collateralDeposited)
        );
        testMintParams.reserveLPers = uint144(_bound(testMintParams.reserveLPers, 0, collateralTotalSupply0));
        testMintParams.tsCheck = uint40(_bound(testMintParams.tsCheck, TIMESTAMP_ISSUANCE_START, MAX_TS));

        // Initialize system parameters
        _systemParams.lpFee.fee = lpFee;
        _systemParams.cumulativeTax = tax;

        // Initialize vault issuance parameters
        vaultIssuanceParams[VAULT_ID].tax = tax;

        // Initialize reserves
        reserves = SirStructs.Reserves({reserveApes: 0, reserveLPers: testMintParams.reserveLPers, tickPriceX42: 0});

        // Mint collateral
        collateral.mint(alice, collateralTotalSupply0 - testMintParams.reserveLPers);

        // Simulate new deposit
        collateral.mint(address(this), testMintParams.reserveLPers + testMintParams.collateralDeposited);

        // Mint for the first time
        (SirStructs.Fees memory fees, uint256 amount) = mint(
            msg.sender,
            address(collateral),
            VAULT_ID,
            _systemParams,
            vaultIssuanceParams[VAULT_ID],
            reserves,
            testMintParams.collateralDeposited
        );
        tsBalance.push(block.timestamp);
        senderTeaBalance.push(balanceOf(msg.sender, VAULT_ID));
        polTeaBalance.push(balanceOf(address(this), VAULT_ID));

        // Assert balances are correct
        (SirStructs.Fees memory fees_, uint256 amount_) = _verifyMintAmounts(testMintParams, collateralTotalSupply0);
        assertEq(amount, amount_);
        assertEq32(keccak256(abi.encode(fees)), keccak256(abi.encode(fees_)));

        // Assert the LP reserve is correct
        _verifyReserveLPers(reserves, testMintParams);

        // Assert SIR rewards are correct
        _verifySIRRewards(testMintParams.tsCheck);
    }

    function testFuzz_mint(
        TestMintParams memory testMintParams0,
        TestMintParams memory testMintParams,
        uint16 lpFee,
        uint8 tax,
        uint256 collateralTotalSupply0
    ) public returns (SirStructs.Reserves memory reserves) {
        collateralTotalSupply0 = _bound(collateralTotalSupply0, 0, type(uint256).max - 1);
        reserves = testFuzz_mint1stTime(testMintParams0, lpFee, tax, collateralTotalSupply0);

        // In some rare cases collateral deposited could be non-zero and yet mint no TEA (we are not testing the 1st mint)
        vm.assume(totalSupplyAndBalanceVault[VAULT_ID].totalSupply > 0);

        // After the first mint, there must be at least 1e6 units of collateral in the reserve
        uint144 reserve = reserves.reserveApes + reserves.reserveLPers;
        vm.assume(reserve >= 1e6);

        // Bound amounts
        testMintParams.reserveLPers = uint144(_bound(testMintParams.reserveLPers, 1, reserve - 1)); // this simulates any price fluctuation
        testMintParams.collateralDeposited = uint144(
            _bound(
                testMintParams.collateralDeposited,
                0,
                type(uint256).max - collateralTotalSupply0 - testMintParams0.collateralDeposited
            )
        );
        testMintParams.collateralDeposited = uint144(
            _bound(testMintParams.collateralDeposited, 0, type(uint144).max - collateral.balanceOf(address(this)))
        );

        testMintParams.tsCheck = uint40(_bound(testMintParams.tsCheck, block.timestamp, MAX_TS));

        // Update reserves
        reserves.reserveLPers = testMintParams.reserveLPers;
        reserves.reserveApes = reserve - testMintParams.reserveLPers;

        // Condition for not reaching TEA_MAX_SUPPLY
        {
            (bool success, uint256 collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reserves.reserveLPers,
                SystemConstants.TEA_MAX_SUPPLY - totalSupplyAndBalanceVault[VAULT_ID].totalSupply,
                totalSupplyAndBalanceVault[VAULT_ID].totalSupply
            );
            if (success)
                testMintParams.collateralDeposited = uint144(
                    _bound(testMintParams.collateralDeposited, 0, collateralDepositedUpperBound)
                );
        }
        vm.assume(testMintParams.collateralDeposited > 0);

        // Simulate new deposit
        collateral.mint(address(this), testMintParams.collateralDeposited);

        // Mint
        (SirStructs.Fees memory fees, uint256 amount) = mint(
            msg.sender,
            address(collateral),
            VAULT_ID,
            _systemParams,
            vaultIssuanceParams[VAULT_ID],
            reserves,
            testMintParams.collateralDeposited
        );

        tsBalance.push(block.timestamp);
        senderTeaBalance.push(balanceOf(msg.sender, VAULT_ID));
        polTeaBalance.push(balanceOf(address(this), VAULT_ID));

        // Assert balances are correct
        (SirStructs.Fees memory fees_, uint256 amount_) = _verifyMintAmounts(testMintParams, 0);
        assertEq(amount, amount_);
        assertEq32(keccak256(abi.encode(fees_)), keccak256(abi.encode(fees)));

        // Assert the LP reserve is correct
        _verifyReserveLPers(reserves, testMintParams);

        // Assert SIR rewards are correct
        _verifySIRRewards(testMintParams.tsCheck);
    }

    function testFuzz_mintOverflows(uint16 lpFee, uint8 tax) public {
        SirStructs.Reserves memory reserves = testFuzz_mint1stTime(
            TestMintParams({reserveLPers: 0, collateralDeposited: SystemConstants.TEA_MAX_SUPPLY, tsCheck: 0}),
            lpFee,
            tax,
            0
        );

        // Mint max
        uint144 collateralDeposited = type(uint144).max - reserves.reserveLPers;

        // Simulate new deposit
        collateral.mint(address(this), collateralDeposited);

        // Mint
        vm.expectRevert(TEAMaxSupplyExceeded.selector);
        vm.prank(msg.sender);
        mint(
            msg.sender,
            address(collateral),
            VAULT_ID,
            _systemParams,
            vaultIssuanceParams[VAULT_ID],
            reserves,
            collateralDeposited
        );
    }

    function testFuzz_burn(
        TestMintParams memory testMintParams0,
        TestMintParams memory testMintParams,
        TestBurnParams memory testBurnParams,
        uint16 lpFee,
        uint8 tax,
        uint256 collateralTotalSupply0
    ) public {
        SirStructs.Reserves memory reserves = testFuzz_mint(
            testMintParams0,
            testMintParams,
            lpFee,
            tax,
            collateralTotalSupply0
        );

        // After the first mint, there must be at least 1e6 units of collateral in the reserve
        uint144 reserve = reserves.reserveApes + reserves.reserveLPers;
        vm.assume(reserve >= 1e6);

        // Bound amounts
        testBurnParams.reserveLPers = uint144(_bound(testBurnParams.reserveLPers, 1, reserve - 1)); // this simulates any price fluctuation
        testBurnParams.tokensBurnt = _bound(testBurnParams.tokensBurnt, 0, balanceOf(msg.sender, VAULT_ID));
        testBurnParams.tsCheck = uint40(_bound(testBurnParams.tsCheck, block.timestamp, MAX_TS));

        // Update reserves (simulate price fluctuation)
        reserves.reserveLPers = testBurnParams.reserveLPers;
        reserves.reserveApes = reserve - testBurnParams.reserveLPers;

        // Burn
        uint256 totalSupply0 = totalSupplyAndBalanceVault[VAULT_ID].totalSupply;
        vm.prank(msg.sender);
        SirStructs.Fees memory fees = burn(
            VAULT_ID,
            _systemParams,
            vaultIssuanceParams[VAULT_ID],
            reserves,
            testBurnParams.tokensBurnt
        );
        tsBalance.push(block.timestamp);
        senderTeaBalance.push(balanceOf(msg.sender, VAULT_ID));
        polTeaBalance.push(balanceOf(address(this), VAULT_ID));

        // Assert balances are correct
        uint144 collateralOut = _verifyBurnAmounts(testBurnParams, totalSupply0);
        assertEq(collateralOut, fees.collateralInOrWithdrawn);

        // Assert the LP reserve is correct
        assertEq(reserves.reserveLPers, testBurnParams.reserveLPers - collateralOut, "LP reserve wrong");

        // Assert SIR rewards are correct
        _verifySIRRewards(testBurnParams.tsCheck);
    }

    function testFuzz_burnExceedsBalance(
        TestMintParams memory testMintParams0,
        TestMintParams memory testMintParams,
        TestBurnParams memory testBurnParams,
        uint16 lpFee,
        uint8 tax,
        uint256 collateralTotalSupply0
    ) public {
        SirStructs.Reserves memory reserves = testFuzz_mint(
            testMintParams0,
            testMintParams,
            lpFee,
            tax,
            collateralTotalSupply0
        );

        // After the first mint, there must be at least 1e6 units of collateral in the reserve
        uint144 reserve = reserves.reserveApes + reserves.reserveLPers;
        vm.assume(reserve >= 1e6);

        // Bound amounts
        testBurnParams.reserveLPers = uint144(_bound(testBurnParams.reserveLPers, 1, reserve - 1)); // this simulates any price fluctuation
        testBurnParams.tokensBurnt = _bound(
            testBurnParams.tokensBurnt,
            balanceOf(msg.sender, VAULT_ID) + 1,
            type(uint256).max
        );
        testBurnParams.tsCheck = uint40(_bound(testBurnParams.tsCheck, block.timestamp, MAX_TS));

        // Update reserves (simulate price fluctuation)
        reserves.reserveLPers = testBurnParams.reserveLPers;
        reserves.reserveApes = reserve - testBurnParams.reserveLPers;

        // Burn
        vm.expectRevert();
        vm.prank(msg.sender);
        burn(VAULT_ID, _systemParams, vaultIssuanceParams[VAULT_ID], reserves, testBurnParams.tokensBurnt);
    }
}
