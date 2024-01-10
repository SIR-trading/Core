// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Vault} from "src/Vault.sol";
import {APE} from "src/APE.sol";
import {IVaultExternal} from "src/Interfaces/IVaultExternal.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {FullMath} from "src/libraries/FullMath.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

contract APETest is Test {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    APE ape;
    address alice;
    address bob;
    address charlie;

    /// @dev Auxiliary function for minting APE tokens
    function _mint(address account, uint256 amount) private {
        uint256 totalSupply = uint256(vm.load(address(ape), bytes32(uint256(2))));
        totalSupply += amount;
        vm.store(address(ape), bytes32(uint256(2)), bytes32(totalSupply));

        uint256 balance = uint256(vm.load(address(ape), keccak256(abi.encode(account, bytes32(uint256(3))))));
        balance += amount;
        vm.store(address(ape), keccak256(abi.encode(account, bytes32(uint256(3)))), bytes32(balance));
    }

    /// @dev Auxiliary function for burning APE tokens
    function _burn(address account, uint256 amount) private {
        uint256 totalSupply = uint256(vm.load(address(ape), bytes32(uint256(2))));
        totalSupply -= amount;
        vm.store(address(ape), bytes32(uint256(2)), bytes32(totalSupply));

        uint256 balance = uint256(vm.load(address(ape), keccak256(abi.encode(account, bytes32(uint256(3))))));
        balance -= amount;
        vm.store(address(ape), keccak256(abi.encode(account, bytes32(uint256(3)))), bytes32(balance));
    }

    function setUp() public {
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(Vault.latestTokenParams.selector),
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

    function testFuzz_transfer(uint256 transferAmount, uint256 mintAmount) public {
        transferAmount = _bound(transferAmount, 1, type(uint256).max);
        mintAmount = _bound(mintAmount, transferAmount, type(uint256).max);

        _mint(alice, mintAmount);

        vm.expectEmit();
        emit Transfer(alice, bob, transferAmount);
        vm.prank(alice);
        assertTrue(ape.transfer(bob, transferAmount));
        assertEq(ape.balanceOf(bob), transferAmount);
        assertEq(ape.balanceOf(alice), mintAmount - transferAmount);
    }

    function testFuzz_transferMoreThanBalance(uint256 transferAmount, uint256 mintAmount) public {
        transferAmount = _bound(transferAmount, 1, type(uint256).max);
        mintAmount = _bound(mintAmount, 0, transferAmount - 1);

        _mint(alice, mintAmount);

        vm.expectRevert();
        ape.transfer(bob, transferAmount);
    }

    function testFuzz_approve(uint256 amount) public {
        vm.prank(alice);
        assertTrue(ape.approve(bob, amount));
        assertEq(ape.allowance(alice, bob), amount);
    }

    function testFuzz_transferFrom(uint256 transferAmount, uint256 mintAmount) public {
        transferAmount = _bound(transferAmount, 1, type(uint256).max);
        mintAmount = _bound(mintAmount, transferAmount, type(uint256).max);

        _mint(bob, mintAmount);

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
        transferAmount = _bound(transferAmount, 1, type(uint256).max);
        mintAmount = _bound(mintAmount, transferAmount, type(uint256).max);

        _mint(bob, mintAmount);

        vm.expectRevert();
        vm.prank(alice);
        ape.transferFrom(bob, alice, transferAmount);
    }

    function testFuzz_transferFromExceedAllowance(
        uint256 transferAmount,
        uint256 mintAmount,
        uint256 allowedAmount
    ) public {
        transferAmount = _bound(transferAmount, 1, type(uint256).max);
        mintAmount = _bound(mintAmount, transferAmount, type(uint256).max);
        allowedAmount = _bound(allowedAmount, 0, transferAmount - 1);

        _mint(bob, mintAmount);

        vm.prank(bob);
        ape.approve(alice, allowedAmount);

        vm.expectRevert();
        vm.prank(alice);
        ape.transferFrom(bob, alice, transferAmount);
    }

    /** @dev Test minting APE tokens when the APE token supply is 0
     */
    function testFuzz_mint1stTime(uint152 collateralDeposited, uint152 apesReserveInitial) public {
        // Valt.sol ensures collateralDeposited + apesReserveInitial < 2^152
        collateralDeposited = uint152(_bound(collateralDeposited, 0, type(uint152).max - apesReserveInitial));

        // // Vault.sol enforces at least 1 unit of collateral to the APE reserve
        vm.assume(collateralDeposited + apesReserveInitial >= 1);

        VaultStructs.Reserves memory reserves;
        reserves.apesReserve = apesReserveInitial;

        vm.expectEmit();
        emit Transfer(address(0), alice, collateralDeposited + apesReserveInitial);
        (VaultStructs.Reserves memory newReserves, uint152 polFee, uint256 amount) = ape.mint(
            alice,
            0,
            0,
            reserves,
            collateralDeposited
        );
        assertEq(amount, collateralDeposited + apesReserveInitial);
        assertEq(ape.balanceOf(alice), collateralDeposited + apesReserveInitial);
        assertEq(ape.totalSupply(), collateralDeposited + apesReserveInitial);
        assertEq(polFee, 0);
        assertEq(newReserves.apesReserve, reserves.apesReserve + collateralDeposited);
    }

    /** @dev Test minting APE tokens with an existing supply of APE tokens
     */
    function testFuzz_mint(uint152 collateralDeposited, uint152 apesReserveInitial, uint256 totalSupplyInitial) public {
        // Valt.sol ensures collateralDeposited + apesReserveInitial < 2^152
        collateralDeposited = uint152(_bound(collateralDeposited, 0, type(uint152).max - apesReserveInitial));

        // Vault.sol always allocated at least 1 unit of collateral to the APE reserve
        vm.assume(apesReserveInitial >= 1);

        // We assume some1 has minted before
        vm.assume(totalSupplyInitial > 0);

        // Calculate the amount of APE tokens that should be minted
        if (apesReserveInitial < totalSupplyInitial)
            collateralDeposited = uint152(
                _bound(
                    collateralDeposited,
                    0,
                    FullMath.mulDiv(type(uint152).max, apesReserveInitial, totalSupplyInitial)
                )
            );
        uint256 amountExpected = FullMath.mulDiv(totalSupplyInitial, collateralDeposited, apesReserveInitial);
        vm.assume(amountExpected <= type(uint256).max - totalSupplyInitial);

        VaultStructs.Reserves memory reserves;
        reserves.apesReserve = apesReserveInitial;

        // Pretend some APE has already been minted
        _mint(alice, totalSupplyInitial);

        vm.expectEmit();
        emit Transfer(address(0), bob, amountExpected);
        (VaultStructs.Reserves memory newReserves, uint152 polFee, uint256 amount) = ape.mint(
            bob,
            0,
            0,
            reserves,
            collateralDeposited
        );

        assertEq(amount, amountExpected, "Amount is not correct");
        assertEq(ape.balanceOf(bob), amountExpected, "Alice balance is not correct");
        assertEq(ape.totalSupply(), totalSupplyInitial + amountExpected, "Total supply is not correct");
        assertEq(polFee, 0, "Pol fee is not correct");
        assertEq(newReserves.apesReserve, reserves.apesReserve + collateralDeposited, "New reserves are not correct");
    }

    /** @dev Test minting APE tokens with an existing supply of APE tokens, but it fails because
        @dev the supply of APE tokens exceeds 2^256-1
     */
    function testFuzz_mintExceedMaxSupply(
        uint152 collateralDeposited,
        uint152 apesReserveInitial,
        uint256 totalSupplyInitial
    ) public {
        // Valt.sol ensures collateralDeposited + apesReserveInitial < 2^152
        collateralDeposited = uint152(_bound(collateralDeposited, 0, type(uint152).max - apesReserveInitial));

        // Vault.sol always allocated at least 1 unit of collateral to the APE reserve
        vm.assume(apesReserveInitial >= 1);

        // We assume some1 has minted before
        vm.assume(totalSupplyInitial > 0);

        // We assume deposited collateral is non-zero
        vm.assume(collateralDeposited > 0);

        // Condition for exceeding max supply
        totalSupplyInitial = _bound(
            totalSupplyInitial,
            FullMath.mulDivRoundingUp(type(uint256).max, apesReserveInitial, apesReserveInitial + collateralDeposited),
            type(uint256).max
        );

        VaultStructs.Reserves memory reserves;
        reserves.apesReserve = apesReserveInitial;

        // Pretend some APE has already been minted
        _mint(alice, totalSupplyInitial);

        vm.expectRevert();
        ape.mint(bob, 0, 0, reserves, collateralDeposited);
    }

    function testFail_mintByNonOwner() public {
        VaultStructs.Reserves memory reserves;
        vm.prank(alice);
        ape.mint(bob, 0, 0, reserves, 10); // This should fail because bob is not the owner
    }

    function testFuzz_burn(
        uint256 amountBalance,
        uint256 amountBurnt,
        uint152 apesReserveInitial,
        uint256 totalSupplyInitial
    ) public {
        // We assume some1 has minted before
        vm.assume(totalSupplyInitial > 0);

        // Balance must be smaller than total supply
        amountBalance = _bound(amountBalance, 0, totalSupplyInitial);

        // Cannot burn more than total supply
        amountBurnt = _bound(amountBurnt, 0, amountBalance);

        // Mint balances
        _mint(alice, amountBalance);
        _mint(bob, totalSupplyInitial - amountBalance);

        VaultStructs.Reserves memory reserves;
        reserves.apesReserve = apesReserveInitial;

        vm.expectEmit();
        emit Transfer(alice, address(0), amountBurnt);
        (VaultStructs.Reserves memory newReserves, uint152 polFee, uint152 collateralWidthdrawn) = ape.burn(
            alice,
            0,
            0,
            reserves,
            amountBurnt
        );

        uint256 collateralWidthdrawnExpected = FullMath.mulDiv(apesReserveInitial, amountBurnt, totalSupplyInitial);

        assertEq(collateralWidthdrawn, collateralWidthdrawnExpected, "Collateral withdrawn is not correct");
        assertEq(ape.balanceOf(alice), amountBalance - amountBurnt, "Alice balance is not correct");
        assertEq(ape.totalSupply(), totalSupplyInitial - amountBurnt, "Total supply is not correct");
        assertEq(polFee, 0, "Pol fee is not correct");
        assertEq(newReserves.apesReserve, reserves.apesReserve - collateralWidthdrawn, "New reserves are not correct");
    }

    function testFuzz_burnMoreThanBalance(
        uint256 amountBalance,
        uint256 amountBurnt,
        uint152 apesReserveInitial,
        uint256 totalSupplyInitial
    ) public {
        // We assume some1 has minted before
        vm.assume(totalSupplyInitial > 0 && totalSupplyInitial < type(uint256).max);

        // Balance must be smaller than total supply
        amountBalance = _bound(amountBalance, 0, totalSupplyInitial);

        // Cannot burn more than total supply
        amountBurnt = _bound(amountBurnt, amountBalance + 1, type(uint256).max);

        // Mint balances
        _mint(alice, amountBalance);
        _mint(bob, totalSupplyInitial - amountBalance);

        VaultStructs.Reserves memory reserves;
        reserves.apesReserve = apesReserveInitial;

        vm.expectRevert();
        ape.burn(alice, 0, 0, reserves, amountBurnt);
    }

    function testFuzz_failsCuzSupplyIsZero(
        uint256 amountBalance,
        uint256 amountBurnt,
        uint256 totalSupplyInitial
    ) public {
        // We assume some1 has minted before
        vm.assume(totalSupplyInitial > 0 && totalSupplyInitial < type(uint256).max);

        // Balance must be smaller than total supply
        amountBalance = _bound(amountBalance, 0, totalSupplyInitial);

        // Cannot burn more than total supply
        amountBurnt = _bound(amountBurnt, amountBalance + 1, type(uint256).max);

        // Mint balances
        _mint(alice, amountBalance);
        _mint(bob, totalSupplyInitial - amountBalance);

        VaultStructs.Reserves memory reserves;
        reserves.apesReserve = 0;

        vm.expectRevert();
        ape.burn(alice, 0, 0, reserves, amountBurnt);
    }
}

///////////////////////////////////////////////
//// I N V A R I A N T //// T E S T I N G ////
/////////////////////////////////////////////

contract APEHandler is Test {
    VaultStructs.Reserves public reserves;
    APE public ape;
    uint256 public totalCollateralDeposited;

    constructor() {
        // This mocked parameters do not matter, they are just so that they function does not fail.
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(Vault.latestTokenParams.selector),
            abi.encode(
                "Name does not matter",
                "Token symbol does not matter",
                uint8(18),
                address(0),
                address(0),
                int8(0)
            )
        );
        ape = new APE();
    }

    // Limit test to 5 accounts
    function _idToAddr(uint id) private pure returns (address) {
        id = _bound(id, 1, 5);
        return vm.addr(id);
    }

    function _changeReserves(uint152 newApesReserve) private {
        uint152 totalCollateral = reserves.apesReserve + reserves.treasury + reserves.lpReserve;
        if (totalCollateral == 0) return;

        // Treasury is left untouched and at least 1 unit of collateral must be in the LP reserve and APE reserve
        newApesReserve = uint152(_bound(newApesReserve, 1, totalCollateral - reserves.treasury - 1));

        reserves.apesReserve = newApesReserve;
        reserves.lpReserve = totalCollateral - reserves.treasury - reserves.apesReserve;
    }

    function transfer(uint256 fromId, uint256 toId, uint256 amount, uint152 finalApesReserve) external {
        address from = _idToAddr(fromId);
        address to = _idToAddr(toId);

        // To avoid underflow
        uint256 preBalance = ape.balanceOf(from);
        amount = _bound(amount, 0, preBalance);

        vm.prank(from);
        ape.transfer(to, amount);

        _changeReserves(finalApesReserve);
    }

    function mint(
        uint256 toId,
        uint16 baseFee,
        uint8 tax,
        uint152 collateralDeposited,
        uint152 finalApesReserve
    ) external {
        baseFee = uint16(_bound(baseFee, 1, type(uint16).max)); // Cannot be 0

        // To avoid overflow of totalCollateral
        uint152 totalCollateral = reserves.apesReserve + reserves.treasury + reserves.lpReserve;
        collateralDeposited = uint152(_bound(collateralDeposited, 0, type(uint152).max - totalCollateral));

        uint256 totalSupply = ape.totalSupply();
        uint256 amountMax = type(uint256).max - totalSupply;
        if (totalSupply > FullMath.mulDivRoundingUp(reserves.apesReserve, amountMax, type(uint256).max)) {
            // Ensure max supply of APE (2^256-1) is not exceeded
            collateralDeposited = uint152(
                _bound(collateralDeposited, 0, FullMath.mulDiv(reserves.apesReserve, amountMax, totalSupply))
            );
        } else if (totalSupply == 0) {
            if (collateralDeposited < 2) return;
            collateralDeposited = uint152(_bound(collateralDeposited, 2, collateralDeposited));
        }

        // Update totalCollateralDeposited
        totalCollateralDeposited += collateralDeposited;

        address to = _idToAddr(toId);
        uint152 polFee;
        uint256 amount;
        (reserves, polFee, amount) = ape.mint(to, baseFee, tax, reserves, collateralDeposited);
        reserves.lpReserve += polFee;

        _changeReserves(finalApesReserve);
    }

    function burn(uint256 fromId, uint16 baseFee, uint8 tax, uint256 amount, uint152 finalApesReserve) external {
        baseFee = uint16(_bound(baseFee, 1, type(uint16).max)); // Cannot be 0

        // To avoid underflow
        address from = _idToAddr(fromId);
        uint256 preBalance = ape.balanceOf(from);
        amount = _bound(amount, 0, preBalance);

        uint256 totalSupply = ape.totalSupply();
        if (reserves.apesReserve == 0 && totalSupply == 0) return;

        // Make sure at least 2 units of collateral are in the LP reserve + APE reserve
        if (reserves.lpReserve < 2) {
            uint152 collateralWidthdrawnMax = reserves.apesReserve + reserves.lpReserve - 2;
            uint256 amountMax = FullMath.mulDiv(totalSupply, collateralWidthdrawnMax, reserves.apesReserve);
            amount = _bound(amount, 0, amountMax);
        }

        uint152 polFee;
        uint152 collateralWidthdrawn;
        (reserves, polFee, collateralWidthdrawn) = ape.burn(from, baseFee, tax, reserves, amount);
        reserves.lpReserve += polFee;

        // Update totalCollateralDeposited
        totalCollateralDeposited -= collateralWidthdrawn;

        _changeReserves(finalApesReserve);
    }
}

contract APEInvariantTest is Test {
    APEHandler apeHandler;
    APE ape;
    uint152 treasuryPrevious;
    bool firstMint = false;

    function setUp() public {
        apeHandler = new APEHandler();
        ape = APE(apeHandler.ape());

        targetContract(address(apeHandler));
    }

    function invariant_collateralCheck() public {
        uint256 totalCollateralDeposited = apeHandler.totalCollateralDeposited();
        (uint152 treasury, uint152 apesReserve, uint152 lpReserve) = apeHandler.reserves();
        uint256 totalCollateral = treasury + apesReserve + lpReserve;

        assertEq(totalCollateralDeposited, totalCollateral);
    }

    function invariant_treasuryAlwaysIncreases() public {
        (uint152 treasury, , ) = apeHandler.reserves();

        assertGe(treasury, treasuryPrevious);

        treasuryPrevious = treasury;
    }

    function invariant_supplyNeverGoesBackToZero() public {
        uint256 totalSupply = ape.totalSupply();
        if (!firstMint) {
            if (totalSupply > 0) firstMint = true;
        } else assertGt(totalSupply, 0);
    }
}
