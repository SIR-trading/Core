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
}

contract TEATestInternal is TEA(address(0), address(0)), Test {
    uint48 constant VAULT_ID = 42;
    uint40 constant MAX_TS = 599 * 365 days;

    MockERC20 collateral;

    address alice;
    address bob;
    address charlie;

    uint256[] tsBalance;
    uint256[] bobBalance;
    uint256[] POLBalance;

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
        bob = vm.addr(2);
        charlie = vm.addr(3);

        systemParams.tsIssuanceStart = uint40(block.timestamp);
    }

    function _verifyMintAmounts(
        TestMintParams memory testMintParams,
        uint256 collateralTotalSupply0
    ) private returns (uint256, uint144) {
        (uint144 collateralIn, uint144 collectedFee, uint144 lpersFee, uint144 polFee) = Fees.hiddenFeeTEA(
            testMintParams.collateralDeposited,
            systemParams.lpFee,
            vaultIssuanceParams[VAULT_ID].tax
        );

        uint256 bobAmount = bobBalance[tsBalance.length - 1] -
            (tsBalance.length == 1 ? 0 : bobBalance[tsBalance.length - 2]);
        uint256 POLAmount = POLBalance[POLBalance.length - 1] -
            (POLBalance.length == 1 ? 0 : POLBalance[POLBalance.length - 2]);

        if (tsBalance.length == 1) {
            uint256 newCollateralTotalSupply = testMintParams.collateralDeposited + collateralTotalSupply0;
            uint256 polFees = uint256(testMintParams.reserveLPers) + lpersFee + polFee;

            // First mint
            if (newCollateralTotalSupply <= SystemConstants.TEA_MAX_SUPPLY) {
                assertEq(bobAmount, collateralIn);
                assertEq(POLAmount, polFees);
            } else {
                // When the token supply is larger than TEA_MAX_SUPPLY, we scale down the ratio of TEA minted to collateral
                uint256 bobAmountE = FullMath.mulDiv(
                    SystemConstants.TEA_MAX_SUPPLY,
                    collateralIn,
                    newCollateralTotalSupply
                );

                if (polFees == 0) assertEq(bobAmount, bobAmountE);
                else if (collateralIn == 0) assertEq(bobAmount, 0);
                else {
                    // Bounds for the error
                    assertLe(bobAmount, bobAmountE + 1);
                    uint256 maxErr = uint256(collateralIn - 1) / polFees + 1;
                    if (maxErr < bobAmountE) assertGe(bobAmount, bobAmountE - maxErr);
                }

                assertEq(POLAmount, FullMath.mulDiv(SystemConstants.TEA_MAX_SUPPLY, polFees, newCollateralTotalSupply));
            }
        } else {
            assertEq(
                POLAmount,
                FullMath.mulDiv(
                    totalSupplyAndBalanceVault[VAULT_ID].totalSupply - bobAmount - POLAmount,
                    polFee,
                    testMintParams.reserveLPers + lpersFee
                ),
                "Wrong POL amount"
            );
            uint256 bobAmountE = FullMath.mulDiv(
                totalSupplyAndBalanceVault[VAULT_ID].totalSupply - bobAmount - POLAmount,
                collateralIn,
                testMintParams.reserveLPers + lpersFee
            );
            assertLe(bobAmount, bobAmountE);
            uint256 maxErr = collateralIn / (testMintParams.reserveLPers + lpersFee + polFee) + 1;
            // vm.writeLine(
            //     "debug.log",
            //     string.concat(
            //         "bobAmount: ",
            //         vm.toString(bobAmount),
            //         ", bobAmountE: ",
            //         vm.toString(bobAmountE),
            //         ", maxErr: ",
            //         vm.toString(maxErr)
            //     )
            // );
            if (maxErr < bobAmountE) assertGe(bobAmount, bobAmountE - maxErr);
        }

        return (bobAmount, collectedFee);
    }

    function _verifyBurnAmounts(
        TestBurnParams memory testBurnParams,
        uint256 totalSupply0
    ) private returns (uint144, uint144) {
        uint144 collateralOut = uint144(
            FullMath.mulDiv(testBurnParams.reserveLPers, testBurnParams.tokensBurnt, totalSupply0)
        );

        (uint144 collateralWidthdrawn, uint144 collectedFee, uint144 lpersFee, uint144 polFee) = Fees.hiddenFeeTEA(
            collateralOut,
            systemParams.lpFee,
            vaultIssuanceParams[VAULT_ID].tax
        );

        uint256 bobAmount = bobBalance[tsBalance.length - 2] - bobBalance[tsBalance.length - 1];
        uint256 POLAmount = POLBalance[POLBalance.length - 1] - POLBalance[POLBalance.length - 2];

        assertEq(bobAmount, testBurnParams.tokensBurnt);
        if (bobAmount != totalSupply0) {
            uint256 POLAmountE = FullMath.mulDiv(totalSupply0, polFee, testBurnParams.reserveLPers);
            assertLe(POLAmount, POLAmountE);
            // vm.writeLine(
            //     "debug.log",
            //     string.concat("POLAmount: ", vm.toString(POLAmount), ", POLAmountE: ", vm.toString(POLAmountE))
            // );
        } else if (collateral.totalSupply() <= SystemConstants.TEA_MAX_SUPPLY) {
            assertEq(POLAmount, lpersFee + polFee);
        }

        return (collateralWidthdrawn, collectedFee);
    }

    function _verifyReserveLPers(
        VaultStructs.Reserves memory reserves,
        TestMintParams memory testMintParams,
        uint144 collectedFee
    ) private {
        assertEq(
            reserves.reserveLPers,
            testMintParams.reserveLPers + testMintParams.collateralDeposited - collectedFee,
            "LP reserve wrong"
        );
    }

    function _verifySIRRewards(uint40 tsCheck) private {
        vm.warp(tsCheck);

        uint256 aggBalanceBob;
        for (uint256 i = 0; i < tsBalance.length; i++) {
            if (tsBalance[i] <= tsCheck) aggBalanceBob += bobBalance[i];
        }
        uint80 rewardsBob = unclaimedRewards(
            VAULT_ID,
            bob,
            bobBalance[tsBalance.length - 1],
            cumulativeSIRPerTEA(VAULT_ID)
        );

        if (aggBalanceBob == 0 || vaultIssuanceParams[VAULT_ID].tax == 0) assertEq(rewardsBob, 0);
        else {
            uint256 ts3Years = systemParams.tsIssuanceStart + SystemConstants.THREE_YEARS;
            uint256 rewardsE;
            uint256 maxErr;
            for (uint256 i = 0; i < tsBalance.length; i++) {
                if (tsBalance[i] <= tsCheck && bobBalance[i] > 0) {
                    uint256 tsStart = tsBalance[i];
                    uint256 tsEnd = i == tsBalance.length - 1 ? tsCheck : tsBalance[i + 1];
                    if (tsStart <= ts3Years && tsEnd >= ts3Years) {
                        rewardsE += SystemConstants.ISSUANCE_FIRST_3_YEARS * (ts3Years - tsStart);
                        rewardsE += SystemConstants.ISSUANCE * (tsEnd - ts3Years);
                        maxErr += ErrorComputation.maxErrorBalanceSIR(bobBalance[i], 2);
                    } else if (tsStart <= ts3Years && tsEnd <= ts3Years) {
                        rewardsE += SystemConstants.ISSUANCE_FIRST_3_YEARS * (tsEnd - tsStart);
                        maxErr += ErrorComputation.maxErrorBalanceSIR(bobBalance[i], 1);
                    } else {
                        rewardsE += SystemConstants.ISSUANCE * (tsEnd - tsStart);
                        maxErr += ErrorComputation.maxErrorBalanceSIR(bobBalance[i], 1);
                    }
                }
            }

            assertLe(rewardsBob, rewardsE);
            // vm.writeLine("maxError.log", vm.toString(rewardsBob));
            // vm.writeLine("maxError.log", vm.toString(maxErr < rewardsE ? rewardsE - maxErr : 0));
            assertGe(rewardsBob, maxErr < rewardsE ? rewardsE - maxErr : 0);
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
        uint8 lpFee,
        uint8 tax,
        uint256 collateralTotalSupply0
    ) public returns (VaultStructs.Reserves memory reserves) {
        // Bounds the amounts
        testMintParams.collateralDeposited = uint144(
            _bound(testMintParams.collateralDeposited, 0, type(uint256).max - collateralTotalSupply0)
        );
        testMintParams.reserveLPers = uint144(
            _bound(testMintParams.reserveLPers, 0, type(uint144).max - testMintParams.collateralDeposited)
        );
        testMintParams.reserveLPers = uint144(_bound(testMintParams.reserveLPers, 0, collateralTotalSupply0));
        testMintParams.tsCheck = uint40(_bound(testMintParams.tsCheck, systemParams.tsIssuanceStart, MAX_TS));

        // Initialize system parameters
        systemParams.lpFee = lpFee;
        systemParams.cumTax = tax;

        // Initialize vault issuance parameters
        vaultIssuanceParams[VAULT_ID].tax = tax;

        // Initialize reserves
        reserves = VaultStructs.Reserves({reserveApes: 0, reserveLPers: testMintParams.reserveLPers, tickPriceX42: 0});

        // Mint collateral
        collateral.mint(alice, collateralTotalSupply0 - testMintParams.reserveLPers);

        // Simulate new deposit
        collateral.mint(address(this), testMintParams.reserveLPers + testMintParams.collateralDeposited);

        // Mint for the first time
        (uint256 amount, uint144 collectedFee) = mint(
            address(collateral),
            bob,
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            reserves,
            testMintParams.collateralDeposited
        );
        tsBalance.push(block.timestamp);
        bobBalance.push(balanceOf(bob, VAULT_ID));
        POLBalance.push(balanceOf(address(this), VAULT_ID));

        // Assert balances are correct
        (uint256 amount_, uint144 collectedFee_) = _verifyMintAmounts(testMintParams, collateralTotalSupply0);
        assertEq(amount, amount_);
        assertEq(collectedFee, collectedFee_);

        // Assert the LP reserve is correct
        _verifyReserveLPers(reserves, testMintParams, collectedFee);

        // Assert SIR rewards are correct
        _verifySIRRewards(testMintParams.tsCheck);
    }

    function testFuzz_mintPOL1stTime(
        TestMintParams memory testMintParams,
        uint8 lpFee,
        uint8 tax,
        uint256 collateralTotalSupply0
    ) public returns (VaultStructs.Reserves memory reserves) {
        // Bounds the amounts
        testMintParams.collateralDeposited = uint144(
            _bound(testMintParams.collateralDeposited, 0, type(uint256).max - collateralTotalSupply0)
        );
        testMintParams.reserveLPers = uint144(
            _bound(testMintParams.reserveLPers, 0, type(uint144).max - testMintParams.collateralDeposited)
        );
        testMintParams.reserveLPers = uint144(_bound(testMintParams.reserveLPers, 0, collateralTotalSupply0));
        testMintParams.tsCheck = uint40(_bound(testMintParams.tsCheck, systemParams.tsIssuanceStart, MAX_TS));

        // Initialize system parameters
        systemParams.lpFee = lpFee;
        systemParams.cumTax = tax;

        // Initialize vault issuance parameters
        vaultIssuanceParams[VAULT_ID].tax = tax;

        // Initialize reserves
        reserves = VaultStructs.Reserves({reserveApes: 0, reserveLPers: testMintParams.reserveLPers, tickPriceX42: 0});

        // Mint collateral
        collateral.mint(alice, collateralTotalSupply0 - testMintParams.reserveLPers);

        // Simulate new deposit
        collateral.mint(address(this), testMintParams.reserveLPers + testMintParams.collateralDeposited);

        // Mint for the first time
        (uint256 amount, uint144 collectedFee) = mint(
            address(collateral),
            address(this),
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            reserves,
            testMintParams.collateralDeposited
        );

        // Assert balances are correct
        uint256 newCollateralTotalSupply = testMintParams.collateralDeposited + collateralTotalSupply0;
        if (newCollateralTotalSupply <= SystemConstants.TEA_MAX_SUPPLY) {
            assertEq(amount, testMintParams.reserveLPers + testMintParams.collateralDeposited);
        } else {
            // When the token supply is larger than TEA_MAX_SUPPLY, we scale down the ratio of TEA minted to collateral
            assertEq(
                amount,
                FullMath.mulDiv(
                    SystemConstants.TEA_MAX_SUPPLY,
                    testMintParams.reserveLPers + testMintParams.collateralDeposited,
                    newCollateralTotalSupply
                ),
                "Amount wrong"
            );
        }
        assertEq(collectedFee, 0, "Collected fee wrong");

        // Assert the LP reserve is correct
        assertEq(
            reserves.reserveLPers,
            testMintParams.reserveLPers + testMintParams.collateralDeposited,
            "LP reserve wrong"
        );

        // Assert SIR rewards are correct
        vm.warp(testMintParams.tsCheck);
        uint80 rewardsVault = unclaimedRewards(VAULT_ID, address(this), amount, cumulativeSIRPerTEA(VAULT_ID));
        assertEq(rewardsVault, 0);
    }

    function testFuzz_mint(
        TestMintParams memory testMintParams0,
        TestMintParams memory testMintParams,
        uint8 lpFee,
        uint8 tax,
        uint256 collateralTotalSupply0
    ) public returns (VaultStructs.Reserves memory reserves) {
        reserves = testFuzz_mint1stTime(testMintParams0, lpFee, tax, collateralTotalSupply0);

        // In some rare cases collateral deposited could be non-zero and yet mint no TEA (we are not testing the 1st mint)
        vm.assume(totalSupplyAndBalanceVault[VAULT_ID].totalSupply > 0);

        // After the first mint, there must be at least 2 units of collateral in the reserve
        uint144 reserve = reserves.reserveApes + reserves.reserveLPers;
        vm.assume(reserve >= 2);

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

        if (
            // Condition for the FullMath below to not OF
            SystemConstants.TEA_MAX_SUPPLY < 2 * totalSupplyAndBalanceVault[VAULT_ID].totalSupply ||
            reserves.reserveLPers <=
            FullMath.mulDiv(
                type(uint256).max,
                totalSupplyAndBalanceVault[VAULT_ID].totalSupply,
                SystemConstants.TEA_MAX_SUPPLY - totalSupplyAndBalanceVault[VAULT_ID].totalSupply
            )
        ) {
            // Condition for not reaching TEA_MAX_SUPPLY
            testMintParams.collateralDeposited = uint144(
                _bound(
                    testMintParams.collateralDeposited,
                    0,
                    FullMath.mulDiv(
                        reserves.reserveLPers,
                        SystemConstants.TEA_MAX_SUPPLY - totalSupplyAndBalanceVault[VAULT_ID].totalSupply,
                        totalSupplyAndBalanceVault[VAULT_ID].totalSupply
                    )
                )
            );
        }

        // Simulate new deposit
        collateral.mint(address(this), testMintParams.collateralDeposited);

        // Mint
        (uint256 amount, uint144 collectedFee) = mint(
            address(collateral),
            bob,
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            reserves,
            testMintParams.collateralDeposited
        );
        tsBalance.push(block.timestamp);
        bobBalance.push(balanceOf(bob, VAULT_ID));
        POLBalance.push(balanceOf(address(this), VAULT_ID));

        // Assert balances are correct
        (uint256 amount_, uint144 collectedFee_) = _verifyMintAmounts(testMintParams, 0);
        assertEq(amount, amount_);
        assertEq(collectedFee, collectedFee_);

        // Assert the LP reserve is correct
        _verifyReserveLPers(reserves, testMintParams, collectedFee);

        // Assert SIR rewards are correct
        _verifySIRRewards(testMintParams.tsCheck);
    }

    function testFuzz_mintPOL(
        TestMintParams memory testMintParams0,
        TestMintParams memory testMintParams,
        uint8 lpFee,
        uint8 tax,
        uint256 collateralTotalSupply0
    ) public {
        VaultStructs.Reserves memory reserves = testFuzz_mint1stTime(
            testMintParams0,
            lpFee,
            tax,
            collateralTotalSupply0
        );

        // In some rare cases collateral deposited could be non-zero and yet mint no TEA (we are not testing the 1st mint)
        vm.assume(totalSupplyAndBalanceVault[VAULT_ID].totalSupply > 0);

        // After the first mint, there must be at least 2 units of collateral in the reserve
        uint144 reserve = reserves.reserveApes + reserves.reserveLPers;
        vm.assume(reserve >= 2);

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

        if (
            // Condition for the FullMath below to not OF
            SystemConstants.TEA_MAX_SUPPLY < 2 * totalSupplyAndBalanceVault[VAULT_ID].totalSupply ||
            reserves.reserveLPers <=
            FullMath.mulDiv(
                type(uint256).max,
                totalSupplyAndBalanceVault[VAULT_ID].totalSupply,
                SystemConstants.TEA_MAX_SUPPLY - totalSupplyAndBalanceVault[VAULT_ID].totalSupply
            )
        ) {
            // Condition for not reaching TEA_MAX_SUPPLY
            testMintParams.collateralDeposited = uint144(
                _bound(
                    testMintParams.collateralDeposited,
                    0,
                    FullMath.mulDiv(
                        reserves.reserveLPers,
                        SystemConstants.TEA_MAX_SUPPLY - totalSupplyAndBalanceVault[VAULT_ID].totalSupply,
                        totalSupplyAndBalanceVault[VAULT_ID].totalSupply
                    )
                )
            );
        }

        // Simulate new deposit
        collateral.mint(address(this), testMintParams.collateralDeposited);

        // Mint
        (uint256 amount, uint144 collectedFee) = mint(
            address(collateral),
            address(this),
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            reserves,
            testMintParams.collateralDeposited
        );

        // Assert balances are correct
        assertEq(
            amount,
            FullMath.mulDiv(
                totalSupplyAndBalanceVault[VAULT_ID].totalSupply - amount,
                testMintParams.collateralDeposited,
                testMintParams.reserveLPers
            ),
            "Amount wrong"
        );
        assertEq(collectedFee, 0, "Collected fee wrong");

        // Assert the LP reserve is correct
        assertEq(
            reserves.reserveLPers,
            testMintParams.reserveLPers + testMintParams.collateralDeposited,
            "LP reserve wrong"
        );

        // Assert SIR rewards are correct
        vm.warp(testMintParams.tsCheck);
        uint80 rewardsVault = unclaimedRewards(VAULT_ID, address(this), amount, cumulativeSIRPerTEA(VAULT_ID));
        assertEq(rewardsVault, 0);
    }

    function testFuzz_mintOverflows(uint8 lpFee, uint8 tax) public {
        VaultStructs.Reserves memory reserves = testFuzz_mint1stTime(
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
        mint(
            address(collateral),
            bob,
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            reserves,
            collateralDeposited
        );
    }

    function testFuzz_burn(
        TestMintParams memory testMintParams0,
        TestMintParams memory testMintParams,
        TestBurnParams memory testBurnParams,
        uint8 lpFee,
        uint8 tax,
        uint256 collateralTotalSupply0
    ) public {
        VaultStructs.Reserves memory reserves = testFuzz_mint(
            testMintParams0,
            testMintParams,
            lpFee,
            tax,
            collateralTotalSupply0
        );

        // After the first mint, there must be at least 2 units of collateral in the reserve
        uint144 reserve = reserves.reserveApes + reserves.reserveLPers;
        vm.assume(reserve >= 2);

        // Bound amounts
        testBurnParams.reserveLPers = uint144(_bound(testBurnParams.reserveLPers, 1, reserve - 1)); // this simulates any price fluctuation
        testBurnParams.tokensBurnt = _bound(testBurnParams.tokensBurnt, 0, balanceOf(bob, VAULT_ID));
        testBurnParams.tsCheck = uint40(_bound(testBurnParams.tsCheck, block.timestamp, MAX_TS));

        // Update reserves (simulate price fluctuation)
        reserves.reserveLPers = testBurnParams.reserveLPers;
        reserves.reserveApes = reserve - testBurnParams.reserveLPers;

        // Burn
        uint256 totalSupply0 = totalSupplyAndBalanceVault[VAULT_ID].totalSupply;
        (uint256 collateralWidthdrawn, uint144 collectedFee) = burn(
            address(collateral),
            bob,
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            reserves,
            testBurnParams.tokensBurnt
        );
        tsBalance.push(block.timestamp);
        bobBalance.push(balanceOf(bob, VAULT_ID));
        POLBalance.push(balanceOf(address(this), VAULT_ID));

        // Assert balances are correct
        (uint144 collateralWidthdrawn_, uint144 collectedFee_) = _verifyBurnAmounts(testBurnParams, totalSupply0);
        assertEq(collateralWidthdrawn, collateralWidthdrawn_);
        assertEq(collectedFee, collectedFee_);

        // Assert the LP reserve is correct
        assertEq(
            reserves.reserveLPers,
            testBurnParams.reserveLPers - collateralWidthdrawn - collectedFee,
            "LP reserve wrong"
        );

        // Assert SIR rewards are correct
        _verifySIRRewards(testBurnParams.tsCheck);
    }

    function testFuzz_burnExceedsBalance(
        TestMintParams memory testMintParams0,
        TestMintParams memory testMintParams,
        TestBurnParams memory testBurnParams,
        uint8 lpFee,
        uint8 tax,
        uint256 collateralTotalSupply0
    ) public {
        VaultStructs.Reserves memory reserves = testFuzz_mint(
            testMintParams0,
            testMintParams,
            lpFee,
            tax,
            collateralTotalSupply0
        );

        // After the first mint, there must be at least 2 units of collateral in the reserve
        uint144 reserve = reserves.reserveApes + reserves.reserveLPers;
        vm.assume(reserve >= 2);

        // Bound amounts
        testBurnParams.reserveLPers = uint144(_bound(testBurnParams.reserveLPers, 1, reserve - 1)); // this simulates any price fluctuation
        testBurnParams.tokensBurnt = _bound(
            testBurnParams.tokensBurnt,
            balanceOf(bob, VAULT_ID) + 1,
            type(uint256).max
        );
        testBurnParams.tsCheck = uint40(_bound(testBurnParams.tsCheck, block.timestamp, MAX_TS));

        // Update reserves (simulate price fluctuation)
        reserves.reserveLPers = testBurnParams.reserveLPers;
        reserves.reserveApes = reserve - testBurnParams.reserveLPers;

        // Burn
        vm.expectRevert();
        burn(
            address(collateral),
            bob,
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            reserves,
            testBurnParams.tokensBurnt
        );
    }
}
