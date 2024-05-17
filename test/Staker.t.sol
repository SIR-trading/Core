// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {Staker} from "src/Staker.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {ErrorComputation} from "./ErrorComputation.sol";

contract StakerTest is Test {
    uint256 constant SLOT_STAKING_PARAMS = 3;
    uint256 constant SLOT_SUPPLY = 4;
    uint256 constant SLOT_BALANCES = 7;
    uint256 constant SLOT_STAKERS_PARAMS = 3;
    uint256 constant SLOT_INITIALIZED = 5;
    uint256 constant SLOT_TOKEN_STATES = 8;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    IWETH9 private constant WETH = IWETH9(Addresses.ADDR_WETH);

    Staker staker;
    address vault;

    address alice;
    address bob;
    address charlie;

    /// @dev Auxiliary function for minting APE tokens
    function _mint(address account, uint80 amount) private {
        // Increase supply
        uint256 slot = uint256(vm.load(address(staker), bytes32(uint256(SLOT_SUPPLY))));
        uint80 balanceOfSIR = uint80(slot) + amount;
        slot >>= 80;
        uint96 unclaimedETH = uint96(slot);
        vm.store(
            address(staker),
            bytes32(uint256(SLOT_SUPPLY)),
            bytes32(abi.encodePacked(uint80(0), unclaimedETH, balanceOfSIR))
        );
        assertEq(staker.supply(), balanceOfSIR, "Wrong supply slot used by vm.store");

        // Increase balance
        slot = uint256(vm.load(address(staker), keccak256(abi.encode(account, bytes32(uint256(SLOT_BALANCES))))));
        balanceOfSIR = uint80(slot) + amount;
        slot >>= 80;
        unclaimedETH = uint96(slot);
        vm.store(
            address(staker),
            keccak256(abi.encode(account, bytes32(uint256(SLOT_BALANCES)))),
            bytes32(abi.encodePacked(uint80(0), unclaimedETH, balanceOfSIR))
        );
        assertEq(staker.balanceOf(account), balanceOfSIR, "Wrong balance slot used by vm.store");
    }

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        staker = new Staker(Addresses.ADDR_WETH);

        vault = address(new Vault(vm.addr(10), address(staker), vm.addr(12)));
        staker.initialize(vault);

        alice = vm.addr(1);
        bob = vm.addr(2);
        charlie = vm.addr(3);
    }

    function _idToAddress(uint256 id) private pure returns (address) {
        id = _bound(id, 1, 3);
        return payable(vm.addr(id));
    }

    function testFail_initializeTwice() public {
        staker.initialize(address(0));
    }

    function test_initializeWrongCaller() public {
        // Reset _initialized to false
        vm.store(address(staker), bytes32(uint256(SLOT_INITIALIZED)), bytes32(0));

        staker.initialize(address(0));
    }

    function testFail_initializeWrongCaller() public {
        // Reset _initialized to false
        vm.store(address(staker), bytes32(uint256(SLOT_INITIALIZED)), bytes32(0));

        vm.prank(alice);
        staker.initialize(address(0));
    }

    function test_initialConditions() public {
        assertEq(staker.supply(), 0);
        assertEq(staker.totalSupply(), 0);
        assertEq(staker.maxTotalSupply(), 0);

        assertEq(staker.balanceOf(alice), 0);
        assertEq(staker.totalBalanceOf(alice), 0);
        assertEq(staker.balanceOf(bob), 0);
        assertEq(staker.totalBalanceOf(bob), 0);

        assertEq(staker.name(), "Safer Investment Rehypothecation");
        assertEq(staker.symbol(), "SIR");
        assertEq(staker.decimals(), SystemConstants.SIR_DECIMALS);
    }

    function test_599yearsOfSIRIssuance() public {
        // 2015M SIR per year
        skip(365 days);
        assertEq(staker.maxTotalSupply() / 10 ** SystemConstants.SIR_DECIMALS, 2015e6);

        // Make sure we can fit 599 years of SIR issuance in uint80
        skip(598 * 365 days);
        assertLe(staker.maxTotalSupply(), type(uint80).max);
    }

    function testFuzz_approve(uint256 amount) public {
        vm.prank(alice);
        assertTrue(staker.approve(bob, amount));
        assertEq(staker.allowance(alice, bob), amount);
    }

    function testFuzz_transfer(uint256 fromId, uint256 toId, uint80 transferAmount, uint80 mintAmount) public {
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        transferAmount = uint80(_bound(transferAmount, 1, type(uint80).max));
        mintAmount = uint80(_bound(mintAmount, transferAmount, type(uint80).max));

        _mint(from, mintAmount);

        vm.expectEmit();
        emit Transfer(from, to, transferAmount);

        vm.prank(from);
        assertTrue(staker.transfer(to, transferAmount));

        assertEq(staker.balanceOf(from), from == to ? mintAmount : mintAmount - transferAmount);
        assertEq(staker.balanceOf(to), to == from ? mintAmount : transferAmount);
    }

    function testFuzz_transferMoreThanBalance(
        uint256 fromId,
        uint256 toId,
        uint80 transferAmount,
        uint80 mintAmount
    ) public {
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        transferAmount = uint80(_bound(transferAmount, 1, type(uint80).max));
        mintAmount = uint80(_bound(mintAmount, 0, transferAmount - 1));

        _mint(from, mintAmount);

        vm.expectRevert();
        staker.transfer(to, transferAmount);
    }

    function testFuzz_transferFrom(
        uint256 fromId,
        uint256 operatorId,
        uint256 toId,
        uint80 transferAmount,
        uint80 mintAmount
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        transferAmount = uint80(_bound(transferAmount, 1, type(uint80).max));
        mintAmount = uint80(_bound(mintAmount, transferAmount, type(uint80).max));

        _mint(from, mintAmount);

        vm.prank(from);
        assertTrue(staker.approve(operator, mintAmount));
        assertEq(staker.allowance(from, operator), mintAmount);

        vm.expectEmit();
        emit Transfer(from, to, transferAmount);

        vm.prank(operator);
        assertTrue(staker.transferFrom(from, to, transferAmount));

        assertEq(staker.allowance(from, operator), mintAmount - transferAmount);
        if (operator != from && operator != to) assertEq(staker.balanceOf(operator), 0); // HERE
        assertEq(staker.balanceOf(from), from == to ? mintAmount : mintAmount - transferAmount);
        assertEq(staker.balanceOf(to), from == to ? mintAmount : transferAmount);
    }

    function testFuzz_transferFromWithoutApproval(
        uint256 fromId,
        uint256 operatorId,
        uint256 toId,
        uint80 transferAmount,
        uint80 mintAmount
    ) public {
        address operator = _idToAddress(operatorId);
        address from = _idToAddress(fromId);
        address to = _idToAddress(toId);

        vm.assume(operator != from);

        transferAmount = uint80(_bound(transferAmount, 1, type(uint80).max));
        mintAmount = uint80(_bound(mintAmount, transferAmount, type(uint80).max));

        _mint(from, mintAmount);

        vm.expectRevert();
        vm.prank(operator);
        staker.transferFrom(from, to, transferAmount);
    }

    function testFuzz_transferFromExceedAllowance(
        uint80 transferAmount,
        uint80 mintAmount,
        uint256 allowedAmount
    ) public {
        transferAmount = uint80(_bound(transferAmount, 1, type(uint80).max));
        mintAmount = uint80(_bound(mintAmount, transferAmount, type(uint80).max));
        allowedAmount = _bound(allowedAmount, 0, transferAmount - 1);

        _mint(bob, mintAmount);

        vm.prank(bob);
        staker.approve(alice, allowedAmount);

        vm.expectRevert();
        vm.prank(alice);
        staker.transferFrom(bob, alice, transferAmount);
    }

    /////////////////////////////////////////////////////////
    //////////////// STAKING SPECIFIC TESTS ////////////////
    ///////////////////////////////////////////////////////

    event Staked(address indexed staker, uint256 amount);
    event DividendsPaid(uint256 amount);

    function testFuzz_stake(
        uint256 id,
        uint80 totalSupplyAmount,
        uint80 mintAmount,
        uint80 stakeAmount
    ) public returns (uint80, uint80) {
        address account = _idToAddress(id);

        mintAmount = uint80(_bound(mintAmount, 0, totalSupplyAmount));
        stakeAmount = uint80(_bound(stakeAmount, 0, mintAmount));

        _mint(account, mintAmount);
        _mint(address(1), totalSupplyAmount - mintAmount);

        vm.expectEmit();
        emit Staked(account, stakeAmount);

        vm.prank(account);
        staker.stake(stakeAmount);

        assertEq(staker.balanceOf(account), mintAmount - stakeAmount, "Wrong balance");
        assertEq(staker.totalBalanceOf(account), mintAmount, "Wrong total balance");
        assertEq(staker.supply(), totalSupplyAmount - stakeAmount, "Wrong supply");
        assertEq(staker.totalSupply(), totalSupplyAmount, "Wrong total supply");

        return (mintAmount, stakeAmount);
    }

    function testFuzz_stake2nd(
        uint256 id1,
        uint256 id2,
        uint80 totalSupplyAmount,
        uint80 mintAmount1,
        uint80 stakeAmount1,
        uint80 mintAmount2,
        uint80 stakeAmount2
    ) public returns (uint80, uint80) {
        totalSupplyAmount = uint80(_bound(totalSupplyAmount, mintAmount2, type(uint80).max));
        stakeAmount2 = uint80(_bound(stakeAmount2, 0, mintAmount2));

        address account1 = _idToAddress(id1);
        address account2 = _idToAddress(id2);

        // 1st staker stakes
        (mintAmount1, stakeAmount1) = testFuzz_stake(id1, totalSupplyAmount - mintAmount2, mintAmount1, stakeAmount1);

        _mint(account2, mintAmount2);

        vm.expectEmit();
        emit Staked(account2, stakeAmount2);

        // 2nd staker stakes
        vm.prank(account2);
        staker.stake(stakeAmount2);

        if (account1 != account2) {
            assertEq(staker.balanceOf(account2), mintAmount2 - stakeAmount2, "Wrong balance of account2");
            assertEq(staker.totalBalanceOf(account2), mintAmount2, "Wrong total balance of account2");
            assertEq(staker.supply(), totalSupplyAmount - stakeAmount1 - stakeAmount2, "Wrong supply of account2");
            assertEq(staker.totalSupply(), totalSupplyAmount, "Wrong total supply of account2");
        } else {
            assertEq(
                staker.balanceOf(account2),
                mintAmount1 + mintAmount2 - stakeAmount1 - stakeAmount2,
                "Wrong balance"
            );
            assertEq(staker.totalBalanceOf(account2), mintAmount1 + mintAmount2, "Wrong total balance of account2");
            assertEq(staker.supply(), totalSupplyAmount - stakeAmount1 - stakeAmount2, "Wrong supply of account2");
            assertEq(staker.totalSupply(), totalSupplyAmount, "Wrong total supply of account2");
        }
        return (stakeAmount1, stakeAmount2);
    }

    function testFuzz_stakeAndGetAvailableETH(
        uint256 id1,
        uint256 id2,
        uint80 totalSupplyAmount,
        uint80 mintAmount1,
        uint80 stakeAmount1,
        uint80 mintAmount2,
        uint80 stakeAmount2,
        uint96 unclaimedWETH,
        uint96 unclaimedETH,
        address randomToken
    ) public {
        address account1 = _idToAddress(id1);
        address account2 = _idToAddress(id2);

        unclaimedWETH = uint96(_bound(unclaimedWETH, 0, 120e6 * 10 ** 18));
        unclaimedETH = uint96(_bound(unclaimedETH, 0, 120e6 * 10 ** 18));
        console.log("unclaimed WETH is", unclaimedWETH, "and unclaimed ETH is", unclaimedETH);

        // Donate ETH to staker
        vm.deal(address(staker), unclaimedWETH + unclaimedETH);

        // Wrap ETH to WETH
        vm.prank(address(staker));
        WETH.deposit{value: unclaimedWETH}();

        // Stake
        (stakeAmount1, stakeAmount2) = testFuzz_stake2nd(
            id1,
            id2,
            totalSupplyAmount,
            mintAmount1,
            stakeAmount1,
            mintAmount2,
            stakeAmount2
        );

        // No dividends
        assertEq(staker.dividends(account1), 0);
        assertEq(staker.dividends(account2), 0);
        vm.prank(account1);
        assertEq(staker.claim(), 0);
        vm.prank(account2);
        assertEq(staker.claim(), 0);

        // This triggers a payment of dividends
        if (unclaimedWETH + unclaimedETH > 0) {
            vm.expectEmit();
            emit DividendsPaid(unclaimedWETH + unclaimedETH);
        }
        staker.collectFeesAndStartAuction(randomToken);

        // Donations
        if (unclaimedWETH + unclaimedETH == 0 || stakeAmount1 + stakeAmount2 == 0) {
            assertEq(staker.dividends(account1), 0, "Dividends of account1 should be 0");
            assertEq(staker.dividends(account2), 0, "Dividends of account2 should be 0");
        } else if (account1 == account2) {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, stakeAmount1 + stakeAmount2, 1);
            assertLe(staker.dividends(account1), unclaimedWETH + unclaimedETH, "Dividends too high");
            assertApproxEqAbs(staker.dividends(account1), unclaimedWETH + unclaimedETH, maxError, "Dividends too low");

            // Claim dividends
            vm.prank(account1);
            assertApproxEqAbs(
                staker.claim(),
                unclaimedWETH + unclaimedETH,
                maxError,
                "Claimed dividends are incorrect"
            );
            assertEq(staker.dividends(account1), 0, "Dividends should be 0 after claim");
            assertApproxEqAbs(account1.balance, unclaimedWETH + unclaimedETH, maxError, "Balance is incorrect");
            assertApproxEqAbs(address(staker).balance, 0, maxError, "Balance staker is incorrect");
        } else {
            // Verify balances of account1
            uint256 dividends = (uint256(unclaimedWETH + unclaimedETH) * stakeAmount1) / (stakeAmount1 + stakeAmount2);
            uint256 maxError1 = ErrorComputation.maxErrorBalance(80, stakeAmount1, 1);
            assertLe(staker.dividends(account1), dividends, "Dividends of account1 too high");
            assertApproxEqAbs(staker.dividends(account1), dividends, maxError1, "Dividends of account1 too low");

            // Claim dividends of account1
            vm.prank(account1);
            assertApproxEqAbs(staker.claim(), dividends, maxError1, "Claimed dividends of account1 are incorrect");
            assertEq(staker.dividends(account1), 0, "Dividends of account1 should be 0 after claim");
            assertApproxEqAbs(account1.balance, dividends, maxError1, "Balance of account1 is incorrect");

            // Verify balances of account2
            dividends = (uint256(unclaimedWETH + unclaimedETH) * stakeAmount2) / (stakeAmount1 + stakeAmount2);
            uint256 maxError2 = ErrorComputation.maxErrorBalance(80, stakeAmount2, 1);
            assertLe(staker.dividends(account2), dividends, "Dividends of account2 too high");
            assertApproxEqAbs(staker.dividends(account2), dividends, maxError2, "Dividends of account2 too low");

            // Claim dividends of account2
            vm.prank(account2);
            assertApproxEqAbs(staker.claim(), dividends, maxError2, "Claimed dividends of account2 are incorrect");
            assertEq(staker.dividends(account1), 0, "Dividends of account2 should be 0 after claim");
            assertApproxEqAbs(account2.balance, dividends, maxError2, "Balance of account2 is incorrect");

            // Verify balances of staker
            assertApproxEqAbs(address(staker).balance, 0, maxError1 + maxError2, "Balance staker is incorrect");
        }
    }

    function testFuzz_stakeExceedsBalance(
        uint256 id,
        uint80 totalSupplyAmount,
        uint80 mintAmount,
        uint80 stakeAmount
    ) public {
        address account = _idToAddress(id);

        totalSupplyAmount = uint80(_bound(totalSupplyAmount, 0, type(uint80).max - 1));
        mintAmount = uint80(_bound(mintAmount, 0, totalSupplyAmount));
        stakeAmount = uint80(_bound(stakeAmount, mintAmount + 1, type(uint80).max));

        _mint(account, mintAmount);
        _mint(address(1), totalSupplyAmount - mintAmount);

        vm.expectRevert();
        vm.prank(account);
        staker.stake(stakeAmount);
    }

    event Unstaked(address indexed staker, uint256 amount);

    function testFuzz_unstake(
        uint256 id,
        uint80 totalSupplyAmount,
        uint80 mintAmount,
        uint80 stakeAmount,
        uint80 unstakeAmount,
        uint96 unclaimedWETH,
        uint96 unclaimedETH,
        address randomToken
    ) public {
        address account = _idToAddress(id);

        // Stakes
        (mintAmount, stakeAmount) = testFuzz_stake(id, totalSupplyAmount, mintAmount, stakeAmount);
        unstakeAmount = uint80(_bound(unstakeAmount, 0, stakeAmount));

        unclaimedWETH = uint96(_bound(unclaimedWETH, 0, 120e6 * 10 ** 18));
        unclaimedETH = uint96(_bound(unclaimedETH, 0, 120e6 * 10 ** 18));

        // Donate ETH to staker
        vm.deal(address(staker), unclaimedWETH + unclaimedETH);

        // Wrap ETH to WETH
        vm.prank(address(staker));
        WETH.deposit{value: unclaimedWETH}();

        // Trigger a payment of dividends
        staker.collectFeesAndStartAuction(randomToken);

        // Check dividends
        console.log("Total dividends are", unclaimedWETH + unclaimedETH);
        console.log("Dividends are", staker.dividends(account));
        if (stakeAmount == 0) {
            assertEq(staker.dividends(account), 0);
        } else {
            assertLe(staker.dividends(account), unclaimedWETH + unclaimedETH);
            assertApproxEqAbs(
                staker.dividends(account),
                unclaimedWETH + unclaimedETH,
                ErrorComputation.maxErrorBalance(80, stakeAmount, 1),
                "Dividends before unstaking too low"
            );
        }

        vm.expectEmit();
        emit Unstaked(account, unstakeAmount);

        // Unstakes
        vm.prank(account);
        staker.unstake(unstakeAmount);
        console.log("Dividends are", staker.dividends(account));

        assertEq(staker.balanceOf(account), mintAmount - stakeAmount + unstakeAmount, "Wrong balance");
        assertEq(staker.totalBalanceOf(account), mintAmount, "Wrong total balance");
        assertEq(staker.supply(), totalSupplyAmount - stakeAmount + unstakeAmount, "Wrong supply");
        assertEq(staker.totalSupply(), totalSupplyAmount, "Wrong total supply");

        // Check dividends still there
        if (stakeAmount == 0) {
            assertEq(staker.dividends(account), 0);
        } else {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, stakeAmount, 1);
            assertLe(staker.dividends(account), unclaimedWETH + unclaimedETH);
            assertApproxEqAbs(
                staker.dividends(account),
                unclaimedWETH + unclaimedETH,
                maxError,
                "Dividends after unstaking too low"
            );

            // Claim dividends
            vm.prank(account);
            assertApproxEqAbs(
                staker.claim(),
                unclaimedWETH + unclaimedETH,
                maxError,
                "Claimed dividends are incorrect"
            );
            assertEq(staker.dividends(account), 0, "Dividends should be 0 after claim");
            assertApproxEqAbs(account.balance, unclaimedWETH + unclaimedETH, maxError, "Balance is incorrect");
        }
    }

    function testFuzz_unstakeExceedsStake(
        uint256 id,
        uint80 totalSupplyAmount,
        uint80 mintAmount,
        uint80 stakeAmount,
        uint80 unstakeAmount
    ) public {
        address account = _idToAddress(id);

        // Stakes
        (mintAmount, stakeAmount) = testFuzz_stake(id, totalSupplyAmount, mintAmount, stakeAmount);

        unstakeAmount = uint80(_bound(unstakeAmount, stakeAmount + 1, type(uint80).max));

        // Unstakes
        vm.prank(account);
        vm.expectRevert();
        staker.unstake(unstakeAmount);
    }

    function _addTokenFeesToVault(address token, uint112 collectedFees, uint144 total) private {
        // Increase fees in Vault
        uint256 slot = uint256(vm.load(vault, keccak256(abi.encode(token, bytes32(uint256(SLOT_TOKEN_STATES))))));
        collectedFees += uint112(slot);
        slot >>= 112;
        total += uint144(slot);
        assert(total >= collectedFees);
        vm.store(
            vault,
            keccak256(abi.encode(token, bytes32(uint256(SLOT_TOKEN_STATES)))),
            bytes32(abi.encodePacked(total, collectedFees))
        );

        (uint112 collectedFees_, ) = Vault(vault).tokenStates(token);
        assertEq(collectedFees, collectedFees_, "Wrong token states slot used by vm.store");
    }

    function _dealWETH(address to, uint256 amount) private {
        vm.deal(to, amount);
        vm.prank(to);
        WETH.deposit{value: amount}();
    }

    function testFuzz_distributeWETH(uint112 fees, uint144 total, uint256 donations) public {
        // Add fees in vault
        fees = uint112(_bound(fees, 0, total));
        _addTokenFeesToVault(Addresses.ADDR_WETH, fees, total);
        _dealWETH(vault, total);

        // Some1 donated tokens to Staker contract
        donations = uint112(_bound(fees, 0, type(uint256).max - total));
        _dealWETH(address(staker), donations);

        // Start auction
        if (fees > 0) {
            vm.expectEmit();
            emit Transfer(vault, address(staker), fees);
            vm.expectEmit();
            emit DividendsPaid(fees + donations);
        }
        assertEq(staker.collectFeesAndStartAuction(Addresses.ADDR_WETH), fees);
    }

    event AuctionStarted(address indexed token);

    function testFuzz_auctionOfBNB(uint112 fees, uint144 total, uint256 donations) public {
        // Add fees in vault
        fees = uint112(_bound(fees, 0, total));
        _addTokenFeesToVault(Addresses.ADDR_BNB, fees, total);
        deal(Addresses.ADDR_BNB, vault, total);

        // Some1 donated tokens to Staker contract
        donations = uint112(_bound(fees, 0, type(uint256).max - total));
        deal(Addresses.ADDR_BNB, address(staker), donations);

        // Start auction
        vm.expectEmit();
        emit AuctionStarted(Addresses.ADDR_BNB);
        if (fees > 0) {
            vm.expectEmit();
            emit Transfer(vault, address(staker), fees);
        }
        assertEq(staker.collectFeesAndStartAuction(Addresses.ADDR_BNB), fees);
    }

    error NewAuctionCannotStartYet(uint40 startTime);

    function testFuzz_auctionOfBNBTooEarly(uint112 fees, uint144 total, uint256 donations, uint40 timeInterval) public {
        testFuzz_auctionOfBNB(fees, total, donations);

        // 2nd auction too early
        timeInterval = uint40(_bound(timeInterval, 0, SystemConstants.AUCTION_COOLDOWN - 1));
        uint256 start = block.timestamp;
        skip(timeInterval);
        vm.expectRevert(
            abi.encodeWithSelector(NewAuctionCannotStartYet.selector, start + SystemConstants.AUCTION_COOLDOWN)
        );
        staker.collectFeesAndStartAuction(Addresses.ADDR_BNB);
    }

    function testFuzz_distributeWETH2ndTime(uint112 fees, uint144 total, uint256 donations) public {
        testFuzz_distributeWETH(fees, total, donations);

        // 2nd auction
        staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);
    }
}
