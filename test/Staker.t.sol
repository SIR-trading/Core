// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {Staker} from "src/Staker.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {ErrorComputation} from "./ErrorComputation.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {TransferHelper} from "v3-core/libraries/TransferHelper.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {APE} from "src/APE.sol";

contract Auxiliary is Test {
    struct Bidder {
        uint256 id;
        uint96 amount;
    }

    struct TokenFees {
        uint112 fees;
        uint144 total;
        uint256 donations;
    }

    struct Donations {
        uint96 donationsETH;
        uint96 donationsWETH;
    }

    uint256 constant SLOT_SUPPLY = 2;
    uint256 constant SLOT_BALANCES = 5;
    uint256 constant SLOT_INITIALIZED = 3;
    uint256 constant SLOT_TOKEN_STATES = 8;

    uint96 constant ETH_SUPPLY = 120e6 * 10 ** 18;

    IWETH9 internal constant WETH = IWETH9(Addresses.ADDR_WETH);

    Staker public staker;
    address public vault;

    /// @dev Auxiliary function for minting SIR tokens
    function _mint(address account, uint80 amount) internal {
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

    function _idToAddress(uint256 id) internal pure returns (address) {
        id = _bound(id, 1, 3);
        return payable(vm.addr(id));
    }

    function _setFees(address token, TokenFees memory tokenFees) internal {
        // Add fees in vault
        if (token == Addresses.ADDR_WETH) tokenFees.total = uint144(_bound(tokenFees.total, 0, ETH_SUPPLY));
        tokenFees.fees = uint112(_bound(tokenFees.fees, 0, tokenFees.total));
        _incrementFeesVariableInVault(token, tokenFees.fees, tokenFees.total);
        if (token == Addresses.ADDR_WETH) _dealWETH(vault, tokenFees.total);
        else _dealToken(token, vault, tokenFees.total);

        // Donated tokens to Staker contract
        tokenFees.donations = _bound(tokenFees.donations, 0, type(uint256).max - tokenFees.total);
        if (token == Addresses.ADDR_WETH) _dealWETH(address(staker), tokenFees.donations);
        else _dealToken(token, address(staker), tokenFees.donations);
    }

    function _setDonations(Donations memory donations) internal {
        donations.donationsWETH = uint96(_bound(donations.donationsWETH, 0, ETH_SUPPLY));
        donations.donationsETH = uint96(_bound(donations.donationsETH, 0, ETH_SUPPLY));

        // Donated (W)ETH to Staker contract
        _dealWETH(address(staker), donations.donationsWETH);
        _dealETH(address(staker), donations.donationsETH);
    }

    function _incrementFeesVariableInVault(address token, uint112 totalFeesToStakers, uint144 total) internal {
        // Increase fees in Vault
        uint256 slot = uint256(vm.load(vault, keccak256(abi.encode(token, bytes32(uint256(SLOT_TOKEN_STATES))))));
        totalFeesToStakers += uint112(slot);
        slot >>= 112;
        total += uint144(slot);
        assert(total >= totalFeesToStakers);
        vm.store(
            vault,
            keccak256(abi.encode(token, bytes32(uint256(SLOT_TOKEN_STATES)))),
            bytes32(abi.encodePacked(total, totalFeesToStakers))
        );

        SirStructs.CollateralState memory collateralState_ = Vault(vault).collateralStates(token);
        assertEq(totalFeesToStakers, collateralState_.totalFeesToStakers, "Wrong token states slot used by vm.store");
    }

    /// @dev The Foundry deal function is not good for WETH because it doesn't update total supply correctly
    function _dealWETH(address to, uint256 amount) internal {
        hoax(address(1), amount);
        WETH.deposit{value: amount}();
        vm.prank(address(1));
        WETH.transfer(address(to), amount);
    }

    function _dealETH(address to, uint256 amount) internal {
        vm.deal(address(1), amount);
        vm.prank(address(1));
        payable(address(to)).transfer(amount);
    }

    function _dealToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        deal(token, address(1), amount);
        vm.prank(address(1));
        TransferHelper.safeTransfer(token, to, amount);
    }

    function _assertAuction(Bidder memory bidder_, uint256 timeStamp) internal view {
        SirStructs.Auction memory auction = staker.auctions(Addresses.ADDR_BNB);
        assertEq(auction.bidder, bidder_.amount == 0 ? address(0) : _idToAddress(bidder_.id), "Wrong bidder");
        assertEq(auction.bid, bidder_.amount, "Wrong bid");
        assertEq(auction.startTime, timeStamp, "Wrong start time");
    }
}

contract StakerTest is Auxiliary {
    error NoFeesCollectedYet();
    error NoAuctionLot();
    error AuctionIsNotOver();
    error BidTooLow();
    error NoAuction();
    error NewAuctionCannotStartYet();

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Staked(address indexed staker, uint256 amount);
    event DividendsPaid(uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);
    event AuctionStarted(address indexed token);
    event BidReceived(address indexed bidder, address indexed token, uint96 previousBid, uint96 newBid);
    event AuctionedTokensSentToWinner(address indexed winner, address indexed token, uint256 reward);

    struct User {
        uint256 id;
        uint80 mintAmount;
        uint80 stakeAmount;
    }

    address alice;
    address bob;
    address charlie;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        staker = new Staker(Addresses.ADDR_WETH);

        APE ape = new APE();

        vault = address(new Vault(vm.addr(10), address(staker), vm.addr(12), address(ape)));
        staker.initialize(vault);

        alice = vm.addr(1);
        bob = vm.addr(2);
        charlie = vm.addr(3);
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

    function test_initialConditions() public view {
        assertEq(staker.supply(), 0);
        assertEq(staker.totalSupply(), 0);
        assertEq(staker.maxTotalSupply(), 0);

        assertEq(staker.balanceOf(alice), 0);
        assertEq(staker.totalBalanceOf(alice), 0);
        assertEq(staker.balanceOf(bob), 0);
        assertEq(staker.totalBalanceOf(bob), 0);

        assertEq(staker.name(), "Synthetics Implemented Right");
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
    /////////////////// STAKING // TESTS ///////////////////
    ///////////////////////////////////////////////////////

    function testFuzz_stake(User memory user, uint80 totalSupplyAmount) public {
        address account = _idToAddress(user.id);

        user.mintAmount = uint80(_bound(user.mintAmount, 0, totalSupplyAmount));
        user.stakeAmount = uint80(_bound(user.stakeAmount, 0, user.mintAmount));

        // Mint
        _mint(account, user.mintAmount);
        _mint(address(1), totalSupplyAmount - user.mintAmount); // Mint the rest to another account

        // Stake
        vm.expectEmit();
        emit Staked(account, user.stakeAmount);
        vm.prank(account);
        staker.stake(user.stakeAmount);

        assertEq(staker.balanceOf(account), user.mintAmount - user.stakeAmount, "Wrong balance");
        assertEq(staker.totalBalanceOf(account), user.mintAmount, "Wrong total balance");
        assertEq(staker.supply(), totalSupplyAmount - user.stakeAmount, "Wrong supply");
        assertEq(staker.totalSupply(), totalSupplyAmount, "Wrong total supply");
    }

    function testFuzz_stakeTwice(User memory user1, User memory user2, uint80 totalSupplyAmount) public {
        totalSupplyAmount = uint80(_bound(totalSupplyAmount, user2.mintAmount, type(uint80).max));

        address account1 = _idToAddress(user1.id);
        address account2 = _idToAddress(user2.id);

        // 1st staker stakes
        testFuzz_stake(user1, totalSupplyAmount - user2.mintAmount);

        // 2nd staker stakes
        user2.stakeAmount = uint80(_bound(user2.stakeAmount, 0, user2.mintAmount));
        _mint(account2, user2.mintAmount);
        vm.expectEmit();
        emit Staked(account2, user2.stakeAmount);
        vm.prank(account2);
        staker.stake(user2.stakeAmount);

        // Verify balances
        if (account1 != account2) {
            assertEq(staker.balanceOf(account2), user2.mintAmount - user2.stakeAmount, "Wrong balance of account2");
            assertEq(staker.totalBalanceOf(account2), user2.mintAmount, "Wrong total balance of account2");
            assertEq(
                staker.supply(),
                totalSupplyAmount - user1.stakeAmount - user2.stakeAmount,
                "Wrong supply of account2"
            );
            assertEq(staker.totalSupply(), totalSupplyAmount, "Wrong total supply of account2");
        } else {
            assertEq(
                staker.balanceOf(account2),
                user1.mintAmount + user2.mintAmount - user1.stakeAmount - user2.stakeAmount,
                "Wrong balance"
            );
            assertEq(
                staker.totalBalanceOf(account2),
                user1.mintAmount + user2.mintAmount,
                "Wrong total balance of account2"
            );
            assertEq(
                staker.supply(),
                totalSupplyAmount - user1.stakeAmount - user2.stakeAmount,
                "Wrong supply of account2"
            );
            assertEq(staker.totalSupply(), totalSupplyAmount, "Wrong total supply of account2");
        }
    }

    function testFuzz_stakeTwiceAndGetDividends(
        User memory user1,
        User memory user2,
        uint80 totalSupplyAmount,
        Donations memory donations
    ) public {
        address account1 = _idToAddress(user1.id);
        address account2 = _idToAddress(user2.id);

        // Set up donations
        _setDonations(donations);

        // Stake
        testFuzz_stakeTwice(user1, user2, totalSupplyAmount);

        // No dividends before claiming
        assertEq(staker.dividends(account1), 0);
        assertEq(staker.dividends(account2), 0);
        vm.prank(account1);
        assertEq(staker.claim(), 0);
        vm.prank(account2);
        assertEq(staker.claim(), 0);

        // This triggers a payment of dividends
        if (donations.donationsWETH + donations.donationsETH > 0 && user1.stakeAmount + user2.stakeAmount > 0) {
            vm.expectEmit();
            emit DividendsPaid(donations.donationsWETH + donations.donationsETH);
        } else {
            vm.expectRevert(NoFeesCollectedYet.selector);
        }
        staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);

        // Donations
        if (donations.donationsWETH + donations.donationsETH == 0 || user1.stakeAmount + user2.stakeAmount == 0) {
            assertEq(staker.dividends(account1), 0, "Donations of account1 should be 0");
            assertEq(staker.dividends(account2), 0, "Donations of account2 should be 0");
        } else if (account1 == account2) {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, user1.stakeAmount + user2.stakeAmount, 1);
            assertLe(
                staker.dividends(account1),
                donations.donationsWETH + donations.donationsETH,
                "Donations too high"
            );
            assertApproxEqAbs(
                staker.dividends(account1),
                donations.donationsWETH + donations.donationsETH,
                maxError,
                "Donations too low"
            );

            // Claim dividends
            vm.prank(account1);
            assertApproxEqAbs(
                staker.claim(),
                donations.donationsWETH + donations.donationsETH,
                maxError,
                "Claimed dividends are incorrect"
            );
            assertEq(staker.dividends(account1), 0, "Donations should be 0 after claim");
            assertApproxEqAbs(
                account1.balance,
                donations.donationsWETH + donations.donationsETH,
                maxError,
                "Balance is incorrect"
            );
            assertApproxEqAbs(address(staker).balance, 0, maxError, "Balance staker is incorrect");
        } else {
            // Verify balances of account1
            uint256 dividends = (uint256(donations.donationsWETH + donations.donationsETH) * user1.stakeAmount) /
                (user1.stakeAmount + user2.stakeAmount);
            uint256 maxError1 = ErrorComputation.maxErrorBalance(80, user1.stakeAmount, 1);
            assertLe(staker.dividends(account1), dividends, "Donations of account1 too high");
            assertApproxEqAbs(staker.dividends(account1), dividends, maxError1, "Donations of account1 too low");

            // Claim dividends of account1
            vm.prank(account1);
            assertApproxEqAbs(staker.claim(), dividends, maxError1, "Claimed dividends of account1 are incorrect");
            assertEq(staker.dividends(account1), 0, "Donations of account1 should be 0 after claim");
            assertApproxEqAbs(account1.balance, dividends, maxError1, "Balance of account1 is incorrect");

            // Verify balances of account2
            dividends =
                (uint256(donations.donationsWETH + donations.donationsETH) * user2.stakeAmount) /
                (user1.stakeAmount + user2.stakeAmount);
            uint256 maxError2 = ErrorComputation.maxErrorBalance(80, user2.stakeAmount, 1);
            assertLe(staker.dividends(account2), dividends, "Donations of account2 too high");
            assertApproxEqAbs(staker.dividends(account2), dividends, maxError2, "Donations of account2 too low");

            // Claim dividends of account2
            vm.prank(account2);
            assertApproxEqAbs(staker.claim(), dividends, maxError2, "Claimed dividends of account2 are incorrect");
            assertEq(staker.dividends(account1), 0, "Donations of account2 should be 0 after claim");
            assertApproxEqAbs(account2.balance, dividends, maxError2, "Balance of account2 is incorrect");

            // Verify balances of staker
            assertApproxEqAbs(address(staker).balance, 0, maxError1 + maxError2, "Balance staker is incorrect");
        }
    }

    function testFuzz_stakeExceedsBalance(User memory user, uint80 totalSupplyAmount) public {
        address account = _idToAddress(user.id);

        totalSupplyAmount = uint80(_bound(totalSupplyAmount, 1, type(uint80).max));
        user.mintAmount = uint80(_bound(user.mintAmount, 0, totalSupplyAmount - 1));
        user.stakeAmount = uint80(_bound(user.stakeAmount, user.mintAmount + 1, totalSupplyAmount));

        _mint(account, user.mintAmount);
        _mint(address(1), totalSupplyAmount - user.mintAmount);

        vm.expectRevert();
        vm.prank(account);
        staker.stake(user.stakeAmount);
    }

    function testFuzz_collectFeesAndStartAuctionNoFees(address token) public {
        vm.expectRevert(NoFeesCollectedYet.selector);
        staker.collectFeesAndStartAuction(token);
    }

    function testFuzz_unstake(
        User memory user,
        uint80 totalSupplyAmount,
        Donations memory donations,
        uint80 unstakeAmount
    ) public {
        address account = _idToAddress(user.id);

        // Stakes
        testFuzz_stake(user, totalSupplyAmount);
        unstakeAmount = uint80(_bound(unstakeAmount, 0, user.stakeAmount));

        // Set up donations
        _setDonations(donations);

        // Trigger a payment of dividends
        console.log(donations.donationsWETH, donations.donationsETH, user.stakeAmount);
        if (donations.donationsWETH + donations.donationsETH > 0 && user.stakeAmount > 0) {
            vm.expectEmit();
            emit DividendsPaid(donations.donationsWETH + donations.donationsETH);
        } else {
            vm.expectRevert(NoFeesCollectedYet.selector);
        }
        staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.dividends(account), 0);
        } else {
            assertLe(staker.dividends(account), donations.donationsWETH + donations.donationsETH);
            assertApproxEqAbs(
                staker.dividends(account),
                donations.donationsWETH + donations.donationsETH,
                ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1),
                "Donations before unstaking too low"
            );
        }

        // Unstakes
        vm.expectEmit();
        emit Unstaked(account, unstakeAmount);
        vm.prank(account);
        staker.unstake(unstakeAmount);

        assertEq(staker.balanceOf(account), user.mintAmount - user.stakeAmount + unstakeAmount, "Wrong balance");
        assertEq(staker.totalBalanceOf(account), user.mintAmount, "Wrong total balance");
        assertEq(staker.supply(), totalSupplyAmount - user.stakeAmount + unstakeAmount, "Wrong supply");
        assertEq(staker.totalSupply(), totalSupplyAmount, "Wrong total supply");

        // Check dividends still there
        if (user.stakeAmount == 0) {
            assertEq(staker.dividends(account), 0);
        } else {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1);
            assertLe(staker.dividends(account), donations.donationsWETH + donations.donationsETH);
            assertApproxEqAbs(
                staker.dividends(account),
                donations.donationsWETH + donations.donationsETH,
                maxError,
                "Donations after unstaking too low"
            );

            // Claim dividends
            vm.prank(account);
            assertApproxEqAbs(
                staker.claim(),
                donations.donationsWETH + donations.donationsETH,
                maxError,
                "Claimed dividends are incorrect"
            );
            assertEq(staker.dividends(account), 0, "Donations should be 0 after claim");
            assertApproxEqAbs(
                account.balance,
                donations.donationsWETH + donations.donationsETH,
                maxError,
                "Balance is incorrect"
            );
        }
    }

    function testFuzz_unstakeAndClaim(
        User memory user,
        uint80 totalSupplyAmount,
        Donations memory donations,
        uint80 unstakeAmount
    ) public {
        address account = _idToAddress(user.id);

        // Stakes
        testFuzz_stake(user, totalSupplyAmount);
        unstakeAmount = uint80(_bound(unstakeAmount, 0, user.stakeAmount));

        // Set up donations
        _setDonations(donations);

        // Trigger a payment of dividends
        uint96 dividends = donations.donationsWETH + donations.donationsETH;
        if (dividends > 0 && user.stakeAmount > 0) {
            vm.expectEmit();
            emit DividendsPaid(dividends);
        } else {
            vm.expectRevert(NoFeesCollectedYet.selector);
        }
        staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.dividends(account), 0);
        } else {
            assertLe(staker.dividends(account), donations.donationsWETH + donations.donationsETH);
            assertApproxEqAbs(
                staker.dividends(account),
                donations.donationsWETH + donations.donationsETH,
                ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1),
                "Donations before unstaking too low"
            );
        }

        // Unstakes
        vm.expectEmit();
        emit Unstaked(account, unstakeAmount);
        vm.prank(account);
        uint96 dividends_ = staker.unstakeAndClaim(unstakeAmount);
        assertEq(staker.dividends(account), 0);

        assertEq(staker.balanceOf(account), user.mintAmount - user.stakeAmount + unstakeAmount, "Wrong balance");
        assertEq(staker.totalBalanceOf(account), user.mintAmount, "Wrong total balance");
        assertEq(staker.supply(), totalSupplyAmount - user.stakeAmount + unstakeAmount, "Wrong supply");
        assertEq(staker.totalSupply(), totalSupplyAmount, "Wrong total supply");

        // Check dividends still there
        assertEq(staker.dividends(account), 0);
        if (user.stakeAmount == 0) {
            assertEq(dividends_, 0);
        } else {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1);
            assertLe(dividends_, dividends);
            assertApproxEqAbs(
                dividends_,
                donations.donationsWETH + donations.donationsETH,
                maxError,
                "Donations after unstaking too low"
            );
        }
    }

    function testFuzz_unstakeExceedsStake(
        User memory user,
        uint80 totalSupplyAmount,
        Donations memory donations,
        uint80 unstakeAmount
    ) public {
        address account = _idToAddress(user.id);

        // Stakes
        user.stakeAmount = uint80(_bound(user.stakeAmount, 0, type(uint80).max - 1));
        testFuzz_stake(user, totalSupplyAmount);
        unstakeAmount = uint80(_bound(unstakeAmount, user.stakeAmount + 1, type(uint80).max));

        // Set up donations
        _setDonations(donations);

        // Trigger a payment of dividends
        vm.assume(donations.donationsWETH + donations.donationsETH > 0 && user.stakeAmount > 0);
        staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.dividends(account), 0);
        } else {
            assertLe(staker.dividends(account), donations.donationsWETH + donations.donationsETH);
            assertApproxEqAbs(
                staker.dividends(account),
                donations.donationsWETH + donations.donationsETH,
                ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1),
                "Donations before unstaking too low"
            );
        }

        // Unstakes
        vm.prank(account);
        vm.expectRevert();
        vm.prank(account);
        staker.unstake(unstakeAmount);
    }

    function testFuzz_unstakeAndClaimExceedsStake(
        User memory user,
        uint80 totalSupplyAmount,
        Donations memory donations,
        uint80 unstakeAmount
    ) public {
        address account = _idToAddress(user.id);

        // Stakes
        user.stakeAmount = uint80(_bound(user.stakeAmount, 0, type(uint80).max - 1));
        testFuzz_stake(user, totalSupplyAmount);
        unstakeAmount = uint80(_bound(unstakeAmount, user.stakeAmount + 1, type(uint80).max));

        // Set up donations
        _setDonations(donations);

        // Trigger a payment of dividends
        vm.assume(donations.donationsWETH + donations.donationsETH > 0 && user.stakeAmount > 0);
        staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.dividends(account), 0);
        } else {
            assertLe(staker.dividends(account), donations.donationsWETH + donations.donationsETH);
            assertApproxEqAbs(
                staker.dividends(account),
                donations.donationsWETH + donations.donationsETH,
                ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1),
                "Donations before unstaking too low"
            );
        }

        // Unstakes
        vm.prank(account);
        vm.expectRevert();
        vm.prank(account);
        staker.unstakeAndClaim(unstakeAmount);
    }

    /////////////////////////////////////////////////////////
    ///////////// AUCTION // AND // DIVIDENDS /////////////
    ///////////////////////////////////////////////////////

    function testFuzz_payAuctionWinnerNoAuction(address token) public {
        vm.expectRevert(NoAuctionLot.selector);
        staker.payAuctionWinner(token);
    }

    function testFuzz_nonAuctionOfWETH(
        TokenFees memory tokenFees,
        Donations memory donations,
        User memory user,
        uint80 totalSupplyAmount
    ) public {
        // Set up fees
        tokenFees.donations = 0; // Since token is WETH, tokenFees.donations is redundant with donations.donationsWETH
        _setFees(Addresses.ADDR_WETH, tokenFees);

        // Set up donations
        _setDonations(donations);

        // Stake
        testFuzz_stake(user, totalSupplyAmount);

        bool noFees = uint256(tokenFees.fees) + donations.donationsWETH + donations.donationsETH == 0 ||
            user.stakeAmount == 0;
        if (noFees) {
            vm.expectRevert(NoFeesCollectedYet.selector);
        } else {
            if (tokenFees.fees > 0) {
                // Transfer event if there are WETH fees
                vm.expectEmit();
                emit Transfer(vault, address(staker), tokenFees.fees);
            }
            // DividendsPaid event if there are any WETH fees or (W)ETH donations
            vm.expectEmit();
            emit DividendsPaid(uint256(tokenFees.fees) + donations.donationsWETH + donations.donationsETH);
        }

        // Pay WETH fees and donations
        uint256 fees = staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);
        if (!noFees) assertEq(fees, tokenFees.fees);
    }

    function testFuzz_nonAuctionOfWETH2ndTime(
        TokenFees memory tokenFees,
        Donations memory donations,
        User memory user,
        uint80 totalSupplyAmount,
        uint40 timeSkip,
        TokenFees memory tokenFees2,
        Donations memory donations2
    ) public {
        testFuzz_nonAuctionOfWETH(tokenFees, donations, user, totalSupplyAmount);

        // Set up fees
        tokenFees2.donations = 0; // Since token is WETH, tokenFees.donations is redundant with donations.donationsWETH
        _setFees(Addresses.ADDR_WETH, tokenFees2);

        // Set up donations
        _setDonations(donations2);

        // 2nd auction
        skip(timeSkip);
        bool noFees = uint256(tokenFees2.fees) + donations2.donationsWETH + donations2.donationsETH == 0 ||
            user.stakeAmount == 0;
        if (noFees) {
            vm.expectRevert(NoFeesCollectedYet.selector);
        } else {
            if (tokenFees2.fees > 0) {
                // Transfer event if there are WETH fees
                vm.expectEmit();
                emit Transfer(vault, address(staker), tokenFees2.fees);
            }
            // DividendsPaid event if there are any WETH fees or (W)ETH donations
            vm.expectEmit();
            emit DividendsPaid(uint256(tokenFees2.fees) + donations2.donationsWETH + donations2.donationsETH);
        }
        uint256 fees = staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);
        if (!noFees) assertEq(fees, tokenFees2.fees);
    }

    function testFuzz_auctionWinnerAlreadyPaid(
        TokenFees memory tokenFees,
        Donations memory donations,
        User memory user,
        uint80 totalSupplyAmount
    ) public {
        testFuzz_nonAuctionOfWETH(tokenFees, donations, user, totalSupplyAmount);
        vm.assume(tokenFees.fees > 0);

        // Reverts because prize has already been paid
        vm.expectRevert(NoAuctionLot.selector);
        staker.payAuctionWinner(Addresses.ADDR_WETH);

        vm.expectRevert(NoFeesCollectedYet.selector);
        staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);
    }

    function testFuzz_startAuctionOfBNB(
        User memory user,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations
    ) public {
        // User stakes
        testFuzz_stake(user, totalSupplyAmount);

        // Set up fees
        _setFees(Addresses.ADDR_BNB, tokenFees);
        vm.assume(tokenFees.fees > 0);

        // Set up donations
        _setDonations(donations);

        // Start auction
        vm.expectEmit();
        emit AuctionStarted(Addresses.ADDR_BNB);
        vm.expectEmit();
        emit Transfer(vault, address(staker), tokenFees.fees);
        if (user.stakeAmount > 0 && donations.donationsETH + donations.donationsWETH > 0) {
            vm.expectEmit();
            emit DividendsPaid(donations.donationsETH + donations.donationsWETH);
        }
        console.log("Staker ETH balance is", address(staker).balance);
        assertEq(staker.collectFeesAndStartAuction(Addresses.ADDR_BNB), tokenFees.fees);
        console.log("Staker ETH balance is", address(staker).balance);
    }

    function testFuzz_auctionOfWETHFails(
        User memory user,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations,
        uint96 amount
    ) public {
        // User stakes
        testFuzz_stake(user, totalSupplyAmount);
        vm.assume(user.stakeAmount > 0);

        // Set up fees
        tokenFees.donations = 0; // Since token is WETH, tokenFees.donations is redundant with donations.donationsWETH
        _setFees(Addresses.ADDR_WETH, tokenFees);
        vm.assume(tokenFees.fees + donations.donationsWETH + donations.donationsETH > 0);

        // Set up donations
        _setDonations(donations);

        // Start auction?
        staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);

        // No auction
        WETH.approve(address(staker), amount);
        vm.expectRevert(NoAuction.selector);
        staker.bid(Addresses.ADDR_WETH, amount);

        SirStructs.Auction memory auction = staker.auctions(Addresses.ADDR_WETH);
        assertEq(auction.bidder, address(0), "Bidder should be 0");
        assertEq(auction.bid, 0, "Bid should be 0");
        assertEq(auction.startTime, 0, "Start time should be 0");

        WETH.approve(address(staker), amount);
        vm.expectRevert(NoAuction.selector);
        staker.bid(Addresses.ADDR_WETH, amount);
    }

    function testFuzz_startAuctionOfBNBNoFees(
        User memory user,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations
    ) public {
        // User stakes
        testFuzz_stake(user, totalSupplyAmount);

        // Set up fees
        tokenFees.fees = 0;
        _setFees(Addresses.ADDR_BNB, tokenFees);

        // Set up donations
        _setDonations(donations);

        // Start auction
        vm.expectRevert(NoFeesCollectedYet.selector);
        assertEq(staker.collectFeesAndStartAuction(Addresses.ADDR_BNB), tokenFees.fees);
    }

    function testFuzz_payAuctionWinnerTooSoon(
        User memory user,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations
    ) public {
        testFuzz_startAuctionOfBNB(user, totalSupplyAmount, tokenFees, donations);
        vm.assume(tokenFees.fees > 0);

        skip(SystemConstants.AUCTION_DURATION - 1);
        vm.expectRevert(AuctionIsNotOver.selector);
        staker.payAuctionWinner(Addresses.ADDR_BNB);
    }

    function testFuzz_payAuctionWinnerNoBids(
        User memory user,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations
    ) public {
        testFuzz_startAuctionOfBNB(user, totalSupplyAmount, tokenFees, donations);
        vm.assume(tokenFees.fees > 0);

        skip(SystemConstants.AUCTION_DURATION);
        vm.expectRevert(NoAuctionLot.selector);
        staker.payAuctionWinner(Addresses.ADDR_BNB);
    }

    function testFuzz_auctionOfBNB(
        User memory user,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations,
        Bidder memory bidder1,
        Bidder memory bidder2,
        Bidder memory bidder3
    ) public returns (uint256 start) {
        start = block.timestamp;

        testFuzz_startAuctionOfBNB(user, totalSupplyAmount, tokenFees, donations);

        bidder1.amount = uint96(_bound(bidder1.amount, 0, ETH_SUPPLY));
        bidder2.amount = uint96(_bound(bidder1.amount, 0, ETH_SUPPLY));
        bidder3.amount = uint96(_bound(bidder1.amount, 0, ETH_SUPPLY));

        // Bidder 1
        _dealWETH(_idToAddress(bidder1.id), bidder1.amount);
        vm.prank(_idToAddress(bidder1.id));
        WETH.approve(address(staker), bidder1.amount);
        if (bidder1.amount > 0) {
            console.log("bidder1 amount is", bidder1.amount);
            vm.expectEmit();
            emit BidReceived(_idToAddress(bidder1.id), Addresses.ADDR_BNB, 0, bidder1.amount);
        } else {
            vm.expectRevert(BidTooLow.selector);
        }
        vm.prank(_idToAddress(bidder1.id));
        staker.bid(Addresses.ADDR_BNB, bidder1.amount);

        // Assert auction parameters
        if (bidder1.amount > 0) _assertAuction(bidder1, start);
        else _assertAuction(Bidder(0, 0), start);

        // Bidder 2
        skip(SystemConstants.AUCTION_DURATION - 1);
        _dealWETH(_idToAddress(bidder2.id), bidder2.amount);
        vm.prank(_idToAddress(bidder2.id));
        WETH.approve(address(staker), bidder2.amount);
        if (_idToAddress(bidder1.id) == _idToAddress(bidder2.id)) {
            if (bidder2.amount > 0) {
                // Bidder increases its own bid
                console.log("bidder1 increments bid by", bidder2.amount);
                vm.expectEmit();
                emit BidReceived(
                    _idToAddress(bidder2.id),
                    Addresses.ADDR_BNB,
                    bidder1.amount,
                    bidder1.amount + bidder2.amount
                );
            } else {
                // Bidder fails to increase its own bid
                vm.expectRevert(BidTooLow.selector);
            }
        } else if (bidder2.amount > bidder1.amount) {
            // Bidder2 outbids bidder1
            console.log("bidder2 amount is", bidder2.amount);
            vm.expectEmit();
            emit BidReceived(_idToAddress(bidder2.id), Addresses.ADDR_BNB, bidder1.amount, bidder2.amount);
        } else {
            // Bidder2 fails to outbid bidder1
            vm.expectRevert(BidTooLow.selector);
        }
        vm.prank(_idToAddress(bidder2.id));
        staker.bid(Addresses.ADDR_BNB, bidder2.amount);

        // Assert auction parameters
        if (_idToAddress(bidder1.id) == _idToAddress(bidder2.id)) {
            if (bidder2.amount > 0) {
                _assertAuction(Bidder(bidder2.id, bidder1.amount + bidder2.amount), start);
            } else {
                if (bidder1.amount > 0) _assertAuction(bidder1, start);
                else _assertAuction(Bidder(0, 0), start);
            }
        } else if (bidder2.amount > bidder1.amount) {
            _assertAuction(bidder2, start);
        } else {
            if (bidder1.amount > 0) _assertAuction(bidder1, start);
            else _assertAuction(Bidder(0, 0), start);
        }

        // Bidder 3 tries to bid after auction is over. It doesn't revert its transfer so it becomes a donation.
        skip(1);
        _dealWETH(address(staker), bidder3.amount);
        vm.prank(_idToAddress(bidder3.id));
        WETH.approve(address(staker), bidder3.amount);
        vm.prank(_idToAddress(bidder3.id));
        vm.expectRevert(NoAuction.selector);
        staker.bid(Addresses.ADDR_BNB, bidder3.amount);
    }

    function testFuzz_payAuctionWinnerBNB(
        User memory user,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations,
        Bidder memory bidder1,
        Bidder memory bidder2,
        Bidder memory bidder3
    ) public {
        console.log("Staker ETH balance is", address(staker).balance);
        testFuzz_auctionOfBNB(user, totalSupplyAmount, tokenFees, donations, bidder1, bidder2, bidder3);

        console.log("Donations are", donations.donationsWETH, donations.donationsETH);
        console.log("Staker balance is", user.stakeAmount);
        console.log("Staker ETH balance is", address(staker).balance);
        if (bidder1.amount + bidder2.amount == 0) {
            vm.expectRevert(NoAuctionLot.selector);
        } else {
            if (user.stakeAmount > 0) {
                vm.expectEmit();
                console.log(_idToAddress(bidder1.id), _idToAddress(bidder2.id));
                console.log(bidder1.amount, bidder2.amount, bidder3.amount);
                emit DividendsPaid(
                    (
                        _idToAddress(bidder1.id) == _idToAddress(bidder2.id)
                            ? bidder1.amount + bidder2.amount
                            : (bidder1.amount >= bidder2.amount ? bidder1.amount : bidder2.amount)
                    ) + bidder3.amount
                );
            }
            vm.expectEmit();
            emit AuctionedTokensSentToWinner(
                bidder1.amount >= bidder2.amount ? _idToAddress(bidder1.id) : _idToAddress(bidder2.id),
                Addresses.ADDR_BNB,
                tokenFees.fees + tokenFees.donations
            );
        }
        console.log("Staker ETH balance is", address(staker).balance);
        staker.payAuctionWinner(Addresses.ADDR_BNB);
        console.log("Staker ETH balance is", address(staker).balance);
    }

    function testFuzz_payAuctionWinnerWETH(
        User memory user,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations,
        uint96 amount
    ) public {
        testFuzz_auctionOfWETHFails(user, totalSupplyAmount, tokenFees, donations, amount);

        skip(SystemConstants.AUCTION_DURATION + 1);

        vm.expectRevert(NoAuctionLot.selector);
        staker.payAuctionWinner(Addresses.ADDR_BNB);
    }

    function testFuzz_start2ndAuctionOfBNBTooEarly(
        User memory user,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations,
        Bidder memory bidder1,
        Bidder memory bidder2,
        Bidder memory bidder3,
        uint256 timeStamp
    ) public {
        uint256 start = testFuzz_auctionOfBNB(user, totalSupplyAmount, tokenFees, donations, bidder1, bidder2, bidder3);

        // 2nd auction too early
        timeStamp = _bound(timeStamp, 0, start + SystemConstants.AUCTION_COOLDOWN - 1);
        vm.warp(timeStamp);
        vm.expectRevert(NewAuctionCannotStartYet.selector);
        staker.collectFeesAndStartAuction(Addresses.ADDR_BNB);
    }
}

contract StakerHandler is Auxiliary {
    address constant COLLATERAL1 = Addresses.ADDR_WETH;
    address constant COLLATERAL2 = Addresses.ADDR_BNB;

    address public user1 = _idToAddress(1);
    address public user2 = _idToAddress(2);
    address public user3 = _idToAddress(3);

    uint256 public currentTime;

    constructor() {
        // vm.writeFile("./InvariantStaker.log", "");
        currentTime = 1694616791;

        staker = new Staker(Addresses.ADDR_WETH);

        address ape = address(new APE());

        vault = address(new Vault(vm.addr(10), address(staker), vm.addr(12), ape));
        staker.initialize(vault);
    }

    modifier advanceTime(uint256 timeSkip) {
        timeSkip = _bound(timeSkip, 0, 10 hours);
        currentTime += timeSkip;
        vm.warp(currentTime);
        _;
    }

    function stake(uint256 timeSkip, uint256 userId, uint80 amount) external advanceTime(timeSkip) {
        address user = _idToAddress(userId);

        // SIR cannot exceed type(uint80).max
        uint80 balanceOfUser = uint80(staker.balanceOf(user));
        amount = uint80(_bound(amount, 0, type(uint80).max - staker.totalSupply() + balanceOfUser));
        // vm.writeLine(
        //     "./InvariantStaker.log",
        //     string.concat("User ", vm.toString(user), " stakes ", vm.toString(amount), " SIR")
        // );

        // Mint SIR
        if (amount > balanceOfUser) _mint(user, amount - balanceOfUser);

        // Stake SIR
        vm.prank(user);
        staker.stake(amount);
    }

    function unstake(uint256 timeSkip, uint256 userId, uint80 amount) external advanceTime(timeSkip) {
        address user = _idToAddress(userId);

        // Cannot unstake more than what is staked
        uint256 stakeBalanceOfUser = staker.totalBalanceOf(user) - staker.balanceOf(user);
        amount = uint80(_bound(amount, 0, stakeBalanceOfUser));
        // vm.writeLine(
        //     "./InvariantStaker.log",
        //     string.concat("User ", vm.toString(user), " UNstakes ", vm.toString(amount), " SIR")
        // );

        // Unstake SIR
        vm.prank(user);
        staker.unstake(amount);
    }

    function claim(uint256 timeSkip, uint256 userId) external advanceTime(timeSkip) {
        address user = _idToAddress(userId);

        // Claim dividends
        vm.prank(user);
        staker.claim();

        // vm.writeLine(
        //     "./InvariantStaker.log",
        //     string.concat("User ", vm.toString(user), " claims ", vm.toString(dividends), " ETH")
        // );
    }

    function bid(
        uint256 timeSkip,
        uint256 userId,
        bool collateralSelect,
        uint96 amount
    ) external advanceTime(timeSkip) {
        address user = _idToAddress(userId);
        address collateral = collateralSelect ? COLLATERAL1 : COLLATERAL2;

        // Bid
        amount = uint96(_bound(amount, 0, ETH_SUPPLY));
        // vm.writeLine(
        //     "./InvariantStaker.log",
        //     string.concat(
        //         "User ",
        //         vm.toString(user),
        //         " bids ",
        //         vm.toString(collateral),
        //         " collateral with ",
        //         vm.toString(amount),
        //         " ETH"
        //     )
        // );
        _dealWETH(user, amount);
        vm.prank(user);
        WETH.approve(address(staker), amount);
        vm.prank(user);
        staker.bid(collateral, amount);
    }

    function collectFeesAndStartAuction(
        uint256 timeSkip,
        TokenFees memory tokenFees,
        bool collateralSelect
    ) external advanceTime(timeSkip) {
        address collateral = collateralSelect ? COLLATERAL1 : COLLATERAL2;
        // vm.writeLine(
        //     "./InvariantStaker.log",
        //     string.concat("Collects fees for ", vm.toString(collateral), " and starts auction")
        // );

        // Set fees in vault
        _setFees(collateral, tokenFees);

        // Collect fees and start auction
        staker.collectFeesAndStartAuction(collateral);
    }

    function payAuctionWinner(uint256 timeSkip, bool collateralSelect) external advanceTime(timeSkip) {
        address collateral = collateralSelect ? COLLATERAL1 : COLLATERAL2;
        // vm.writeLine("./InvariantStaker.log", string.concat("Pays winner of ", vm.toString(collateral), " auction"));

        // Pay auction winner
        staker.payAuctionWinner(collateral);
    }

    function donate(uint256 timeSkip, Donations memory donations) external advanceTime(timeSkip) {
        // Set donations in vault
        _setDonations(donations);

        // vm.writeLine(
        //     "./InvariantStaker.log",
        //     string.concat(
        //         "Donations: ",
        //         vm.toString(donations.donationsETH),
        //         " ETH and ",
        //         vm.toString(donations.donationsWETH),
        //         " WETH"
        //     )
        // );
    }
}

contract StakerInvariantTest is Test {
    StakerHandler stakerHandler;
    Staker staker;

    function setUp() external {
        vm.createSelectFork("mainnet", 18128102);

        stakerHandler = new StakerHandler();
        staker = Staker(stakerHandler.staker());

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = stakerHandler.stake.selector;
        selectors[1] = stakerHandler.unstake.selector;
        selectors[2] = stakerHandler.claim.selector;
        selectors[3] = stakerHandler.bid.selector;
        selectors[4] = stakerHandler.collectFeesAndStartAuction.selector;
        selectors[5] = stakerHandler.payAuctionWinner.selector;
        selectors[6] = stakerHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(stakerHandler), selectors: selectors}));
    }

    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_stakerBalances() public view {
        assertGe(
            address(staker).balance,
            uint256(staker.dividends(stakerHandler.user1())) +
                staker.dividends(stakerHandler.user2()) +
                staker.dividends(stakerHandler.user3()),
            "Staker's balance should be at least the sum of all dividends"
        );
    }
}
