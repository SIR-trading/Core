// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Vault} from "src/Vault.sol";
import {APE} from "src/APE.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {FullMath} from "src/libraries/FullMath.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {Fees} from "src/libraries/Fees.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";

contract APETest is Test {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    int8 constant LEVERAGE_TIER = -1;

    APE ape;
    address alice;
    address bob;
    address charlie;

    struct FeesWrapper {
        uint144 collectedFee;
        uint144 lpersFee;
        uint144 polFee;
    }

    /// @dev Auxiliary function for minting APE tokens
    function _mint(address account, uint256 amount) private {
        uint256 totalSupply = uint256(vm.load(address(ape), bytes32(uint256(2))));
        totalSupply += amount;
        vm.store(address(ape), bytes32(uint256(2)), bytes32(totalSupply));
        assertEq(ape.totalSupply(), totalSupply, "Wrong slot used by vm.store");

        uint256 balance = uint256(vm.load(address(ape), keccak256(abi.encode(account, bytes32(uint256(3))))));
        balance += amount;
        vm.store(address(ape), keccak256(abi.encode(account, bytes32(uint256(3)))), bytes32(balance));
        assertEq(ape.balanceOf(account), balance, "Wrong slot used by vm.store");
    }

    /// @dev Auxiliary function for burning APE tokens
    function _burn(address account, uint256 amount) private {
        uint256 totalSupply = uint256(vm.load(address(ape), bytes32(uint256(2))));
        totalSupply -= amount;
        vm.store(address(ape), bytes32(uint256(2)), bytes32(totalSupply));
        assertEq(ape.totalSupply(), totalSupply, "Wrong slot used by vm.store");

        uint256 balance = uint256(vm.load(address(ape), keccak256(abi.encode(account, bytes32(uint256(3))))));
        balance -= amount;
        vm.store(address(ape), keccak256(abi.encode(account, bytes32(uint256(3)))), bytes32(balance));
        assertEq(ape.balanceOf(account), balance, "Wrong slot used by vm.store");
    }

    function latestTokenParams()
        external
        pure
        returns (
            VaultStructs.TokenParameters memory tokenParameters,
            VaultStructs.VaultParameters memory vaultParameters
        )
    {
        tokenParameters = VaultStructs.TokenParameters({
            name: "Tokenized ETH/USDC with 1.25x leverage",
            symbol: "APE-42",
            decimals: 18
        });
        vaultParameters = VaultStructs.VaultParameters({
            debtToken: Addresses.ADDR_USDC,
            collateralToken: Addresses.ADDR_WETH,
            leverageTier: LEVERAGE_TIER
        });
    }

    function setUp() public {
        ape = new APE();

        alice = vm.addr(1);
        bob = vm.addr(2);
        charlie = vm.addr(3);
    }

    function _idToAddress(uint256 id) private pure returns (address) {
        id = _bound(id, 1, 3);
        return vm.addr(id);
    }

    function test_initialConditions() public {
        assertEq(ape.totalSupply(), 0);
        assertEq(ape.balanceOf(alice), 0);
        assertEq(ape.balanceOf(bob), 0);
        assertEq(ape.debtToken(), Addresses.ADDR_USDC);
        assertEq(ape.collateralToken(), Addresses.ADDR_WETH);
        assertEq(ape.leverageTier(), LEVERAGE_TIER);
        assertEq(ape.name(), "Tokenized ETH/USDC with 1.25x leverage");
        assertEq(ape.symbol(), "APE-42");
        assertEq(ape.decimals(), 18);
    }

    function testFuzz_approve(uint256 amount) public {
        vm.prank(alice);
        assertTrue(ape.approve(bob, amount));
        assertEq(ape.allowance(alice, bob), amount);
    }

    function testFuzz_transfer(uint256 fromId, uint256 toId, uint256 transferAmount, uint256 mintAmount) public {
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        transferAmount = _bound(transferAmount, 1, type(uint256).max);
        mintAmount = _bound(mintAmount, transferAmount, type(uint256).max);

        _mint(from, mintAmount);

        vm.expectEmit();
        emit Transfer(from, to, transferAmount);

        vm.prank(from);
        assertTrue(ape.transfer(to, transferAmount));

        assertEq(ape.balanceOf(from), from == to ? mintAmount : mintAmount - transferAmount);
        assertEq(ape.balanceOf(to), to == from ? mintAmount : transferAmount);
    }

    function testFuzz_transferMoreThanBalance(
        uint256 fromId,
        uint256 toId,
        uint256 transferAmount,
        uint256 mintAmount
    ) public {
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        transferAmount = _bound(transferAmount, 1, type(uint256).max);
        mintAmount = _bound(mintAmount, 0, transferAmount - 1);

        _mint(from, mintAmount);

        vm.expectRevert();
        ape.transfer(to, transferAmount);
    }

    function testFuzz_transferFrom(
        uint256 fromId,
        uint256 operatorId,
        uint256 toId,
        uint256 transferAmount,
        uint256 mintAmount
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        transferAmount = _bound(transferAmount, 1, type(uint256).max);
        mintAmount = _bound(mintAmount, transferAmount, type(uint256).max);

        _mint(from, mintAmount);

        vm.prank(from);
        assertTrue(ape.approve(operator, mintAmount));
        assertEq(ape.allowance(from, operator), mintAmount);

        vm.expectEmit();
        emit Transfer(from, to, transferAmount);

        vm.prank(operator);
        assertTrue(ape.transferFrom(from, to, transferAmount));

        assertEq(
            ape.allowance(from, operator),
            mintAmount == type(uint256).max ? mintAmount : mintAmount - transferAmount
        );
        if (operator != from && operator != to) assertEq(ape.balanceOf(operator), 0); // HERE
        assertEq(ape.balanceOf(from), from == to ? mintAmount : mintAmount - transferAmount);
        assertEq(ape.balanceOf(to), from == to ? mintAmount : transferAmount);
    }

    function testFuzz_transferFromWithoutApproval(
        uint256 fromId,
        uint256 operatorId,
        uint256 toId,
        uint256 transferAmount,
        uint256 mintAmount
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        vm.assume(operator != from);

        transferAmount = _bound(transferAmount, 1, type(uint256).max);
        mintAmount = _bound(mintAmount, transferAmount, type(uint256).max);

        _mint(from, mintAmount);

        vm.expectRevert();
        vm.prank(operator);
        ape.transferFrom(from, to, transferAmount);
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
    function testFuzz_mint1stTime(
        uint144 collateralDeposited,
        uint144 reserveApesInitial,
        uint16 baseFee,
        uint8 tax
    ) public {
        // Valt.sol ensures collateralDeposited + reserveApesInitial < 2^152
        collateralDeposited = uint144(_bound(collateralDeposited, 0, type(uint144).max - reserveApesInitial));

        // // Vault.sol enforces at least 1 unit of collateral to the APE reserve
        vm.assume(collateralDeposited + reserveApesInitial >= 1);

        // Expected fees
        uint144 collateralIn_;
        FeesWrapper memory expectedFees_;
        {
            uint144 collectedFee;
            uint144 lpersFee;
            uint144 polFee;
            (collateralIn_, collectedFee, lpersFee, polFee) = Fees.hiddenFeeAPE(
                collateralDeposited,
                baseFee,
                LEVERAGE_TIER,
                tax
            );
            expectedFees_ = FeesWrapper(collectedFee, lpersFee, polFee);
        }

        // Mint
        vm.expectEmit();
        emit Transfer(address(0), alice, reserveApesInitial + collateralIn_);
        (FeesWrapper memory expectedFees, VaultStructs.Reserves memory newReserves, uint256 amount) = _wrappedMint(
            collateralDeposited,
            reserveApesInitial,
            baseFee,
            tax
        );

        // Check reserves
        assertEq(newReserves.reserveApes, reserveApesInitial + collateralIn_, "1");
        assertEq(newReserves.reserveLPers, expectedFees_.lpersFee, "2");

        // Check amounts
        assertEq(amount, reserveApesInitial + collateralIn_, "3");
        assertEq(amount, ape.balanceOf(alice), "4");
        assertEq(amount, ape.totalSupply(), "5");

        // Verify fees
        assertEq(expectedFees.collectedFee, expectedFees_.collectedFee, "6");
        assertEq(expectedFees.polFee, expectedFees_.polFee, "7");
    }

    /** @dev Test minting APE tokens with an existing supply of APE tokens
     */
    function testFuzz_mint(
        uint144 collateralDeposited,
        uint144 reserveApesInitial,
        uint256 totalSupplyInitial,
        uint16 baseFee,
        uint8 tax
    ) public {
        // Valt.sol ensures collateralDeposited + reserveApesInitial < 2^152
        collateralDeposited = uint144(_bound(collateralDeposited, 0, type(uint144).max - reserveApesInitial));

        // Vault.sol always allocated at least 1 unit of collateral to the APE reserve
        vm.assume(reserveApesInitial >= 1);

        // We assume some1 has minted before
        vm.assume(totalSupplyInitial > 0);

        // Bound the amount of collateral deposited
        if (reserveApesInitial < totalSupplyInitial)
            collateralDeposited = uint144(
                _bound(
                    collateralDeposited,
                    0,
                    FullMath.mulDiv(type(uint144).max, reserveApesInitial, totalSupplyInitial)
                )
            );

        // Expected fees
        uint144 collateralIn_;
        uint256 amount_;
        FeesWrapper memory expectedFees_;
        {
            uint144 collectedFee;
            uint144 lpersFee;
            uint144 polFee;
            (collateralIn_, collectedFee, lpersFee, polFee) = Fees.hiddenFeeAPE(
                collateralDeposited,
                baseFee,
                LEVERAGE_TIER,
                tax
            );
            expectedFees_ = FeesWrapper(collectedFee, lpersFee, polFee);
            amount_ = FullMath.mulDiv(totalSupplyInitial, collateralIn_, reserveApesInitial);
        }
        vm.assume(amount_ <= type(uint256).max - totalSupplyInitial);

        VaultStructs.Reserves memory reserves;
        reserves.reserveApes = reserveApesInitial;

        // Pretend some APE has already been minted
        _mint(bob, totalSupplyInitial);

        // Mint
        vm.expectEmit();
        emit Transfer(address(0), alice, amount_);
        (FeesWrapper memory expectedFees, VaultStructs.Reserves memory newReserves, uint256 amount) = _wrappedMint(
            collateralDeposited,
            reserveApesInitial,
            baseFee,
            tax
        );

        // Check reserves
        assertEq(newReserves.reserveApes, reserveApesInitial + collateralIn_, "1");
        assertEq(newReserves.reserveLPers, expectedFees_.lpersFee, "2");

        // Check amounts
        assertEq(amount, amount_, "3");
        assertEq(amount, ape.balanceOf(alice), "4");
        assertEq(totalSupplyInitial + amount, ape.totalSupply(), "5");

        // Verify fees
        assertEq(expectedFees.collectedFee, expectedFees_.collectedFee, "6");
        assertEq(expectedFees.polFee, expectedFees_.polFee, "7");
    }

    /** @dev Test minting APE tokens with an existing supply of APE tokens, but it fails because
        @dev the supply of APE tokens exceeds 2^256-1
     */
    function testFuzz_mintExceedMaxSupply(
        uint144 collateralDeposited,
        uint144 reserveApesInitial,
        uint256 totalSupplyInitial
    ) public {
        // Valt.sol ensures collateralDeposited + reserveApesInitial < 2^152
        collateralDeposited = uint144(_bound(collateralDeposited, 0, type(uint144).max - reserveApesInitial));

        // Vault.sol always allocated at least 1 unit of collateral to the APE reserve
        vm.assume(reserveApesInitial >= 1);

        // We assume some1 has minted before
        vm.assume(totalSupplyInitial > 0);

        // We assume deposited collateral is non-zero
        vm.assume(collateralDeposited > 0);

        // Condition for exceeding max supply
        totalSupplyInitial = _bound(
            totalSupplyInitial,
            FullMath.mulDivRoundingUp(type(uint256).max, reserveApesInitial, reserveApesInitial + collateralDeposited),
            type(uint256).max
        );

        VaultStructs.Reserves memory reserves;
        reserves.reserveApes = reserveApesInitial;

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
        uint144 reserveApesInitial,
        uint256 totalSupplyInitial,
        uint16 baseFee,
        uint8 tax
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

        // Expected fees
        uint144 collateralOut_;
        uint144 collateralWithdrawn_;
        FeesWrapper memory expectedFees_;
        {
            collateralOut_ = uint144(FullMath.mulDiv(reserveApesInitial, amountBurnt, totalSupplyInitial));

            uint144 collectedFee;
            uint144 lpersFee;
            uint144 polFee;
            (collateralWithdrawn_, collectedFee, lpersFee, polFee) = Fees.hiddenFeeAPE(
                collateralOut_,
                baseFee,
                LEVERAGE_TIER,
                tax
            );
            expectedFees_ = FeesWrapper(collectedFee, lpersFee, polFee);
        }

        // Burn
        vm.expectEmit();
        emit Transfer(alice, address(0), amountBurnt);
        (
            FeesWrapper memory expectedFees,
            VaultStructs.Reserves memory newReserves,
            uint144 collateralWithdrawn
        ) = _wrappedBurn(amountBurnt, reserveApesInitial, baseFee, tax);

        // Check reserves
        assertEq(newReserves.reserveApes, reserveApesInitial - collateralOut_, "1");
        assertEq(newReserves.reserveLPers, expectedFees_.lpersFee, "2");

        // Check amounts
        assertEq(collateralWithdrawn, collateralWithdrawn_, "3");
        assertEq(amountBalance - amountBurnt, ape.balanceOf(alice), "4");
        assertEq(totalSupplyInitial - amountBurnt, ape.totalSupply(), "5");

        // Verify fees
        assertEq(expectedFees.collectedFee, expectedFees_.collectedFee, "6");
        assertEq(expectedFees.polFee, expectedFees_.polFee, "7");
    }

    function testFuzz_burnMoreThanBalance(
        uint256 amountBalance,
        uint256 amountBurnt,
        uint144 reserveApesInitial,
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
        reserves.reserveApes = reserveApesInitial;

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
        reserves.reserveApes = 0;

        vm.expectRevert();
        ape.burn(alice, 0, 0, reserves, amountBurnt);
    }

    function _wrappedMint(
        uint144 collateralDeposited,
        uint144 reserveApesInitial,
        uint16 baseFee,
        uint8 tax
    ) private returns (FeesWrapper memory expectedFees, VaultStructs.Reserves memory newReserves, uint256 amount) {
        VaultStructs.Reserves memory reserves;
        reserves.reserveApes = reserveApesInitial;
        uint144 collectedFee;
        uint144 polFee;
        (newReserves, collectedFee, polFee, amount) = ape.mint(alice, baseFee, tax, reserves, collateralDeposited);
        expectedFees = FeesWrapper(collectedFee, 0, polFee);
    }

    function _wrappedBurn(
        uint256 amount,
        uint144 reserveApesInitial,
        uint16 baseFee,
        uint8 tax
    )
        private
        returns (FeesWrapper memory expectedFees, VaultStructs.Reserves memory newReserves, uint144 collateralWithdrawn)
    {
        VaultStructs.Reserves memory reserves;
        reserves.reserveApes = reserveApesInitial;
        uint144 collectedFee;
        uint144 polFee;
        (newReserves, collectedFee, polFee, collateralWithdrawn) = ape.burn(alice, baseFee, tax, reserves, amount);
        expectedFees = FeesWrapper(collectedFee, 0, polFee);
    }
}

///////////////////////////////////////////////
//// I N V A R I A N T //// T E S T I N G ////
/////////////////////////////////////////////

contract APEHandler is Test {
    int8 constant LEVERAGE_TIER = -1;

    uint256 public collectedFees;
    uint256 public collectedFeesOld;
    uint256 public totalCollateralDeposited;

    // We simulate two APE tokens
    bool[2] public changeReserves;

    uint256[2] public totalSupplyOld;
    uint144[2] public apesReserveOld;

    VaultStructs.Reserves[2] public reserves;
    APE[2] public ape;

    bool[2] public trueIfMintFalseIfBurn;

    function latestTokenParams()
        external
        pure
        returns (
            VaultStructs.TokenParameters memory tokenParameters,
            VaultStructs.VaultParameters memory vaultParameters
        )
    {
        tokenParameters = VaultStructs.TokenParameters({
            name: "Tokenized ETH/USDC with 1.25x leverage",
            symbol: "APE-42",
            decimals: 18
        });
        vaultParameters = VaultStructs.VaultParameters({
            debtToken: Addresses.ADDR_USDC,
            collateralToken: Addresses.ADDR_WETH,
            leverageTier: LEVERAGE_TIER
        });
    }

    function setUp() public {
        ape[0] = new APE();
        ape[1] = new APE();
    }

    // Limit test to 5 accounts
    function _idToAddr(uint id) private pure returns (address) {
        id = _bound(id, 1, 5);
        return vm.addr(id);
    }

    function _changeReserves(uint144 newApesReserve, uint8 rndAPE) private {
        changeReserves[rndAPE] = !changeReserves[rndAPE];
        if (changeReserves[rndAPE]) return;

        uint144 totalCollateral = reserves[rndAPE].reserveApes + reserves[rndAPE].reserveLPers;
        if (totalCollateral == 0) return;

        // At least 1 unit of collateral must be in the LP reserve and APE reserve
        newApesReserve = uint144(_bound(newApesReserve, 1, totalCollateral - 1));

        reserves[rndAPE].reserveApes = newApesReserve;
        reserves[rndAPE].reserveLPers = totalCollateral - reserves[rndAPE].reserveApes;
    }

    function transfer(uint256 fromId, uint256 toId, uint256 amount, uint144 finalApesReserve, uint8 rndAPE) external {
        rndAPE = uint8(_bound(rndAPE, 0, 1));
        address from = _idToAddr(fromId);
        address to = _idToAddr(toId);

        // To avoid underflow
        uint256 preBalance = ape[rndAPE].balanceOf(from);
        amount = _bound(amount, 0, preBalance);

        totalSupplyOld[rndAPE] = ape[rndAPE].totalSupply();
        collectedFeesOld = collectedFees;
        apesReserveOld[rndAPE] = reserves[rndAPE].reserveApes;

        vm.prank(from);
        ape[rndAPE].transfer(to, amount);

        _changeReserves(finalApesReserve, rndAPE);
    }

    function mint(
        uint256 toId,
        uint16 baseFee,
        uint8 tax,
        uint144 collateralDeposited,
        uint144 finalApesReserve,
        uint8 rndAPE
    ) external {
        rndAPE = uint8(_bound(rndAPE, 0, 1));
        baseFee = uint16(_bound(baseFee, 1, type(uint16).max)); // Cannot be 0

        totalSupplyOld[rndAPE] = ape[rndAPE].totalSupply();
        collectedFeesOld = collectedFees;
        apesReserveOld[rndAPE] = reserves[rndAPE].reserveApes;

        // To avoid overflow of totalCollateral
        uint144 totalCollateral = reserves[rndAPE].reserveApes + reserves[rndAPE].reserveLPers;
        collateralDeposited = uint144(
            _bound(collateralDeposited, totalSupplyOld[rndAPE] == 0 ? 2 : 0, type(uint144).max - totalCollateral)
        );

        if (totalSupplyOld[rndAPE] != 0) {
            // Ensure max supply of APE (2^256-1) is not exceeded
            (bool success, uint256 collateralDepositedUpperBound) = FullMath.tryMulDiv(
                reserves[rndAPE].reserveApes,
                type(uint256).max - totalSupplyOld[rndAPE],
                totalSupplyOld[rndAPE]
            );
            if (success && collateralDepositedUpperBound < type(uint144).max)
                collateralDeposited = uint144(_bound(collateralDeposited, 0, collateralDepositedUpperBound));
        }

        // Update totalCollateralDeposited
        totalCollateralDeposited += collateralDeposited;

        address to = _idToAddr(toId);
        uint144 collectedFee;
        uint144 polFee;
        uint256 amount;
        (reserves[rndAPE], collectedFee, polFee, amount) = ape[rndAPE].mint(
            to,
            baseFee,
            tax,
            reserves[rndAPE],
            collateralDeposited
        );
        collectedFees += collectedFee;
        reserves[rndAPE].reserveLPers += polFee;

        _changeReserves(finalApesReserve, rndAPE);
        trueIfMintFalseIfBurn[rndAPE] = true;
    }

    function burn(
        uint256 fromId,
        uint16 baseFee,
        uint8 tax,
        uint256 amount,
        uint144 finalApesReserve,
        uint8 rndAPE
    ) external {
        rndAPE = uint8(_bound(rndAPE, 0, 1));
        baseFee = uint16(_bound(baseFee, 1, type(uint16).max)); // Cannot be 0

        // To avoid underflow
        address from = _idToAddr(fromId);
        uint256 preBalance = ape[rndAPE].balanceOf(from);
        amount = _bound(amount, 0, preBalance);

        totalSupplyOld[rndAPE] = ape[rndAPE].totalSupply();
        collectedFeesOld = collectedFees;
        apesReserveOld[rndAPE] = reserves[rndAPE].reserveApes;
        if (totalSupplyOld[rndAPE] == 0) return;

        // Make sure at least 2 units of collateral are in the LP reserve + APE reserve
        if (reserves[rndAPE].reserveLPers < 2) {
            uint144 collateralWithdrawnMax = reserves[rndAPE].reserveApes + reserves[rndAPE].reserveLPers - 2;
            uint256 amountMax = FullMath.mulDiv(
                totalSupplyOld[rndAPE],
                collateralWithdrawnMax,
                reserves[rndAPE].reserveApes
            );
            amount = _bound(amount, 0, amountMax);
        }

        uint144 collectedFee;
        uint144 polFee;
        uint144 collateralWithdrawn;
        (reserves[rndAPE], collectedFee, polFee, collateralWithdrawn) = ape[rndAPE].burn(
            from,
            baseFee,
            tax,
            reserves[rndAPE],
            amount
        );
        collectedFees += collectedFee;
        reserves[rndAPE].reserveLPers += polFee;

        // Update totalCollateralDeposited
        totalCollateralDeposited -= collateralWithdrawn;

        _changeReserves(finalApesReserve, rndAPE);
        trueIfMintFalseIfBurn[rndAPE] = false;
    }
}

contract APEInvariantTest is Test {
    APEHandler apeHandler;
    APE[2] ape;

    function setUp() public {
        apeHandler = new APEHandler();
        apeHandler.setUp();
        ape[0] = APE(apeHandler.ape(0));
        ape[1] = APE(apeHandler.ape(1));

        targetContract(address(apeHandler));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = apeHandler.transfer.selector;
        selectors[1] = apeHandler.mint.selector;
        selectors[2] = apeHandler.burn.selector;
        targetSelector(FuzzSelector({addr: address(apeHandler), selectors: selectors}));
    }

    function invariant_collateralCheck() public {
        uint256 totalCollateralDeposited = apeHandler.totalCollateralDeposited();
        (uint144 reserveApes, uint144 reserveLPers, ) = apeHandler.reserves(0);
        uint256 totalCollateral = apeHandler.collectedFees() + reserveApes + reserveLPers;
        (reserveApes, reserveLPers, ) = apeHandler.reserves(1);
        totalCollateral += reserveApes + reserveLPers;

        assertEq(totalCollateralDeposited, totalCollateral);
    }

    function invariant_treasuryAlwaysIncreases() public {
        uint256 collectedFees = apeHandler.collectedFees();
        uint256 collectedFeesOld = apeHandler.collectedFeesOld();

        assertGe(collectedFees, collectedFeesOld);
    }

    function invariant_ratioReservesAreProportionalToSupply() public {
        bool changeReserves = apeHandler.changeReserves(0);
        if (changeReserves) {
            uint256 totalSupplyOld = apeHandler.totalSupplyOld(0);
            if (totalSupplyOld > 0) {
                uint256 totalSupply = ape[0].totalSupply();

                (uint144 reserveApes, , ) = apeHandler.reserves(0);
                uint144 apesReserveOld = apeHandler.apesReserveOld(0);

                bool trueIfMintFalseIfBurn = apeHandler.trueIfMintFalseIfBurn(0);
                if (trueIfMintFalseIfBurn) {
                    uint256 totalSupplyExpected = FullMath.mulDiv(reserveApes, totalSupplyOld, apesReserveOld);
                    assertLe(totalSupply, totalSupplyExpected);
                    assertGe(totalSupply, totalSupplyExpected - 1);
                } else {
                    uint144 apesReserveExpected = uint144(FullMath.mulDiv(totalSupply, apesReserveOld, totalSupplyOld));
                    assertGe(reserveApes, apesReserveExpected);
                    assertLe(reserveApes, apesReserveExpected + 1);
                }
            }
        }

        changeReserves = apeHandler.changeReserves(1);
        if (changeReserves) {
            uint256 totalSupplyOld = apeHandler.totalSupplyOld(1);
            if (totalSupplyOld > 0) {
                uint256 totalSupply = ape[1].totalSupply();

                (uint144 reserveApes, , ) = apeHandler.reserves(1);
                uint144 apesReserveOld = apeHandler.apesReserveOld(1);

                bool trueIfMintFalseIfBurn = apeHandler.trueIfMintFalseIfBurn(1);
                if (trueIfMintFalseIfBurn) {
                    uint256 totalSupplyExpected = FullMath.mulDiv(reserveApes, totalSupplyOld, apesReserveOld);
                    assertLe(totalSupply, totalSupplyExpected);
                    assertGe(totalSupply, totalSupplyExpected - 1);
                } else {
                    uint144 apesReserveExpected = uint144(FullMath.mulDiv(totalSupply, apesReserveOld, totalSupplyOld));
                    assertGe(reserveApes, apesReserveExpected);
                    assertLe(reserveApes, apesReserveExpected + 1);
                }
            }
        }
    }
}
