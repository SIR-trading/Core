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

    uint96 constant ETH_SUPPLY = 120e6 * 10 ** 18;

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

    function testFuzz_stake(User memory user1, uint80 totalSupplyAmount) public {
        address account = _idToAddress(user1.id);

        user1.mintAmount = uint80(_bound(user1.mintAmount, 0, totalSupplyAmount));
        user1.stakeAmount = uint80(_bound(user1.stakeAmount, 0, user1.mintAmount));

        _mint(account, user1.mintAmount);
        _mint(address(1), totalSupplyAmount - user1.mintAmount);

        vm.expectEmit();
        emit Staked(account, user1.stakeAmount);

        vm.prank(account);
        staker.stake(user1.stakeAmount);

        assertEq(staker.balanceOf(account), user1.mintAmount - user1.stakeAmount, "Wrong balance");
        assertEq(staker.totalBalanceOf(account), user1.mintAmount, "Wrong total balance");
        assertEq(staker.supply(), totalSupplyAmount - user1.stakeAmount, "Wrong supply");
        assertEq(staker.totalSupply(), totalSupplyAmount, "Wrong total supply");
    }

    function testFuzz_stakeTwice(User memory user1, User memory user2, uint80 totalSupplyAmount) public {
        totalSupplyAmount = uint80(_bound(totalSupplyAmount, user2.mintAmount, type(uint80).max));
        user2.stakeAmount = uint80(_bound(user2.stakeAmount, 0, user2.mintAmount));

        address account1 = _idToAddress(user1.id);
        address account2 = _idToAddress(user2.id);

        // 1st staker stakes
        testFuzz_stake(user1, totalSupplyAmount - user2.mintAmount);

        // 2nd staker stakes
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
        if (donations.donationsWETH + donations.donationsETH > 0) {
            vm.expectEmit();
            emit DividendsPaid(donations.donationsWETH + donations.donationsETH);
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

    function testFuzz_stakeExceedsBalance(User memory user1, uint80 totalSupplyAmount) public {
        address account = _idToAddress(user1.id);

        totalSupplyAmount = uint80(_bound(totalSupplyAmount, 1, type(uint80).max));
        user1.mintAmount = uint80(_bound(user1.mintAmount, 0, totalSupplyAmount - 1));
        user1.stakeAmount = uint80(_bound(user1.stakeAmount, user1.mintAmount + 1, totalSupplyAmount));

        _mint(account, user1.mintAmount);
        _mint(address(1), totalSupplyAmount - user1.mintAmount);

        vm.expectRevert();
        vm.prank(account);
        staker.stake(user1.stakeAmount);
    }

    event Unstaked(address indexed staker, uint256 amount);

    function testFuzz_collectFeesAndStartAuctionNoFees(address token) public {
        vm.expectRevert(NoFees.selector);
        staker.collectFeesAndStartAuction(token);
    }

    function testFuzz_unstake(
        User memory user1,
        uint80 totalSupplyAmount,
        Donations memory donations,
        uint80 unstakeAmount
    ) public {
        address account = _idToAddress(user1.id);

        // Stakes
        testFuzz_stake(user1, totalSupplyAmount);
        unstakeAmount = uint80(_bound(unstakeAmount, 0, user1.stakeAmount));

        // Set up donations
        _setDonations(donations);

        // Trigger a payment of dividends
        staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);

        // Check dividends
        if (user1.stakeAmount == 0) {
            assertEq(staker.dividends(account), 0);
        } else {
            assertLe(staker.dividends(account), donations.donationsWETH + donations.donationsETH);
            assertApproxEqAbs(
                staker.dividends(account),
                donations.donationsWETH + donations.donationsETH,
                ErrorComputation.maxErrorBalance(80, user1.stakeAmount, 1),
                "Donations before unstaking too low"
            );
        }

        vm.expectEmit();
        emit Unstaked(account, unstakeAmount);

        // Unstakes
        vm.prank(account);
        staker.unstake(unstakeAmount);
        console.log("Donations are", staker.dividends(account));

        assertEq(staker.balanceOf(account), user1.mintAmount - user1.stakeAmount + unstakeAmount, "Wrong balance");
        assertEq(staker.totalBalanceOf(account), user1.mintAmount, "Wrong total balance");
        assertEq(staker.supply(), totalSupplyAmount - user1.stakeAmount + unstakeAmount, "Wrong supply");
        assertEq(staker.totalSupply(), totalSupplyAmount, "Wrong total supply");

        // Check dividends still there
        if (user1.stakeAmount == 0) {
            assertEq(staker.dividends(account), 0);
        } else {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, user1.stakeAmount, 1);
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

    function testFuzz_unstakeExceedsStake(
        User memory user1,
        uint80 totalSupplyAmount,
        Donations memory donations,
        uint80 unstakeAmount
    ) public {
        address account = _idToAddress(user1.id);

        // Stakes
        testFuzz_stake(user1, totalSupplyAmount);
        unstakeAmount = uint80(_bound(unstakeAmount, user1.stakeAmount + 1, type(uint80).max));

        // Set up donations
        _setDonations(donations);

        // Trigger a payment of dividends
        staker.collectFeesAndStartAuction(Addresses.ADDR_WETH);

        // Check dividends
        if (user1.stakeAmount == 0) {
            assertEq(staker.dividends(account), 0);
        } else {
            assertLe(staker.dividends(account), donations.donationsWETH + donations.donationsETH);
            assertApproxEqAbs(
                staker.dividends(account),
                donations.donationsWETH + donations.donationsETH,
                ErrorComputation.maxErrorBalance(80, user1.stakeAmount, 1),
                "Donations before unstaking too low"
            );
        }

        // Unstakes
        vm.prank(account);
        vm.expectRevert();
        vm.prank(account);
        staker.unstake(unstakeAmount);
    }

    function _incrementFeesVariableInVault(address token, uint112 collectedFees, uint144 total) private {
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

    /// @dev The Foundry deal function is not good for WETH because it doesn't update total supply correctly
    function _dealWETH(address to, uint256 amount) private {
        vm.deal(to, amount);
        vm.prank(to);
        WETH.deposit{value: amount}();
    }

    error NoLot();

    function testFuzz_payAuctionWinnerNoAuction(address token) public {
        vm.expectRevert(NoLot.selector);
        staker.payAuctionWinner(token);
    }

    error NoFees();

    function testFuzz_nonAuctionOfWETH(
        TokenFees memory tokenFees,
        Donations memory donations,
        User memory user1,
        uint80 totalSupplyAmount
    ) public {
        // Set up fees
        tokenFees.donations = 0; // Since token is WETH, tokenFees.donations is redundant with donations.donationsWETH
        _setFees(Addresses.ADDR_WETH, tokenFees);

        // Set up donations
        _setDonations(donations);

        // Stake
        testFuzz_stake(user1, totalSupplyAmount);

        bool noFees = uint256(tokenFees.fees) + donations.donationsWETH + donations.donationsETH == 0 ||
            user1.stakeAmount == 0;
        if (noFees) {
            vm.expectRevert(NoFees.selector);
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

    function testFuzz_payAuctionWinnerTooLate(
        TokenFees memory tokenFees,
        Donations memory donations,
        User memory user1,
        uint80 totalSupplyAmount
    ) public {
        testFuzz_nonAuctionOfWETH(tokenFees, donations, user1, totalSupplyAmount);
        vm.assume(tokenFees.fees > 0);

        // Reverts because prize has already been paid
        vm.expectRevert(NoLot.selector);
        staker.payAuctionWinner(Addresses.ADDR_WETH);
    }

    event AuctionStarted(address indexed token);

    struct TokenFees {
        uint112 fees;
        uint144 total;
        uint256 donations;
    }

    struct Donations {
        uint96 donationsETH;
        uint96 donationsWETH;
    }

    function _setFees(address token, TokenFees memory tokenFees) private {
        // Add fees in vault
        if (token == Addresses.ADDR_WETH) tokenFees.total = uint144(_bound(tokenFees.total, 0, ETH_SUPPLY));
        tokenFees.fees = uint112(_bound(tokenFees.fees, 0, tokenFees.total));
        _incrementFeesVariableInVault(token, tokenFees.fees, tokenFees.total);
        if (token == Addresses.ADDR_WETH) _dealWETH(vault, tokenFees.total);
        else deal(token, vault, tokenFees.total);

        // Donated tokens to Staker contract
        tokenFees.donations = _bound(tokenFees.donations, 0, type(uint256).max - tokenFees.total);
        if (token == Addresses.ADDR_WETH) _dealWETH(address(staker), tokenFees.donations);
        else deal(token, address(staker), tokenFees.donations);
    }

    function _setDonations(Donations memory donations) private {
        donations.donationsWETH = uint96(_bound(donations.donationsWETH, 0, ETH_SUPPLY));
        donations.donationsETH = uint96(_bound(donations.donationsETH, 0, ETH_SUPPLY));

        // Donated (W)ETH to Staker contract
        _dealWETH(address(staker), donations.donationsWETH);
        vm.deal(address(staker), donations.donationsETH);
    }

    struct User {
        uint256 id;
        uint80 mintAmount;
        uint80 stakeAmount;
    }

    function testFuzz_startAuctionOfBNB(
        User memory user1,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations
    ) public {
        // User stakes
        testFuzz_stake(user1, totalSupplyAmount);

        // Set up fees
        _setFees(Addresses.ADDR_BNB, tokenFees);

        // Set up donations
        _setDonations(donations);

        // Start auction
        if (tokenFees.fees > 0) {
            vm.expectEmit();
            emit AuctionStarted(Addresses.ADDR_BNB);
            vm.expectEmit();
            emit Transfer(vault, address(staker), tokenFees.fees);
            if (user1.stakeAmount > 0 && donations.donationsETH + donations.donationsWETH > 0) {
                vm.expectEmit();
                emit DividendsPaid(donations.donationsETH + donations.donationsWETH);
            }
        } else {
            vm.expectRevert(NoFees.selector);
        }

        assertEq(staker.collectFeesAndStartAuction(Addresses.ADDR_BNB), tokenFees.fees);
    }

    function testFuzz_payAuctionWinnerTooSoon(
        User memory user1,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations
    ) public {
        testFuzz_startAuctionOfBNB(user1, totalSupplyAmount, tokenFees, donations);
        vm.assume(tokenFees.fees > 0);

        skip(SystemConstants.AUCTION_DURATION - 1);
        vm.expectRevert(NoLot.selector);
        staker.payAuctionWinner(Addresses.ADDR_BNB);
    }

    function testFuzz_payAuctionWinnerNoBids(
        User memory user1,
        uint80 totalSupplyAmount,
        TokenFees memory tokenFees,
        Donations memory donations
    ) public {
        testFuzz_startAuctionOfBNB(user1, totalSupplyAmount, tokenFees, donations);
        vm.assume(tokenFees.fees > 0);

        skip(SystemConstants.AUCTION_DURATION);
        vm.expectRevert(NoLot.selector);
        staker.payAuctionWinner(Addresses.ADDR_BNB);
    }

    struct Bidder {
        uint256 id;
        uint96 amount;
    }

    event BidReceived(address indexed bidder, address indexed token, uint96 previousBid, uint96 newBid);
    error BidTooLow();
    error NoAuction();

    function _assertAuction(Bidder memory bidder_, uint256 timeStamp) private {
        (address bidder, uint96 bid, uint40 startTime, bool winnerPaid) = staker.auctions(Addresses.ADDR_BNB);
        assertEq(bidder, bidder_.amount == 0 ? address(0) : _idToAddress(bidder_.id), "Wrong bidder");
        assertEq(bid, bidder_.amount, "Wrong bid");
        assertEq(startTime, timeStamp, "Wrong start time");
        assertTrue(!winnerPaid, "Winner should not have been paid yet");
    }

    // function testFuzz_auctionOfBNB(
    //     uint112 feesBNB,
    //     uint144 totalBNB,
    //     uint256 donationsBNB,
    //     Bidder memory bidder1,
    //     Bidder memory bidder2,
    //     Bidder memory bidder3
    // ) public returns (uint256 start, uint112 feesNew, uint256 donationsNew) {
    //     start = block.timestamp;

    //     (feesNew, donationsNew) = testFuzz_startAuctionOfBNB(feesBNB, totalBNB, donationsBNB);
    //     vm.assume(feesNew > 0);

    //     bidder1.amount = uint96(_bound(bidder1.amount, 0, ETH_SUPPLY));
    //     bidder2.amount = uint96(_bound(bidder1.amount, 0, ETH_SUPPLY));
    //     bidder3.amount = uint96(_bound(bidder1.amount, 0, ETH_SUPPLY));

    //     // Bidder 1
    //     if (bidder1.amount > 0) {
    //         _dealWETH(address(staker), bidder1.amount);
    //         console.log("bidder1 amount is", bidder1.amount);
    //         vm.expectEmit();
    //         emit BidReceived(_idToAddress(bidder1.id), Addresses.ADDR_BNB, 0, bidder1.amount);
    //     } else {
    //         vm.expectRevert(BidTooLow.selector);
    //     }
    //     vm.prank(_idToAddress(bidder1.id));
    //     staker.bid(Addresses.ADDR_BNB);
    //     if (bidder1.amount > 0) _assertAuction(bidder1, start);
    //     else _assertAuction(Bidder(0, 0), start);

    //     // Bidder 2
    //     skip(SystemConstants.AUCTION_DURATION - 1);
    //     _dealWETH(address(staker), bidder2.amount);
    //     if (_idToAddress(bidder1.id) == _idToAddress(bidder2.id)) {
    //         if (bidder2.amount > 0) {
    //             // Bidder increases its own bid
    //             console.log("bidder1 increments bid by", bidder2.amount);
    //             vm.expectEmit();
    //             emit BidReceived(
    //                 _idToAddress(bidder2.id),
    //                 Addresses.ADDR_BNB,
    //                 bidder1.amount,
    //                 bidder1.amount + bidder2.amount
    //             );
    //         } else {
    //             // Bidder fails to increase its own bid
    //             vm.expectRevert(BidTooLow.selector);
    //         }
    //     } else if (bidder2.amount > bidder1.amount) {
    //         // Bidder2 outbids bidder1
    //         console.log("bidder2 amount is", bidder2.amount);
    //         vm.expectEmit();
    //         emit BidReceived(_idToAddress(bidder2.id), Addresses.ADDR_BNB, bidder1.amount, bidder2.amount);
    //     } else {
    //         // Bidder2 fails to outbid bidder1
    //         vm.expectRevert(BidTooLow.selector);
    //     }
    //     vm.prank(_idToAddress(bidder2.id));
    //     staker.bid(Addresses.ADDR_BNB);
    //     if (_idToAddress(bidder1.id) == _idToAddress(bidder2.id)) {
    //         if (bidder2.amount > 0) {
    //             _assertAuction(Bidder(bidder2.id, bidder1.amount + bidder2.amount), start);
    //         } else {
    //             if (bidder1.amount > 0) _assertAuction(bidder1, start);
    //             else _assertAuction(Bidder(0, 0), start);
    //         }
    //     } else if (bidder2.amount > bidder1.amount) {
    //         _assertAuction(bidder2, start);
    //     } else {
    //         if (bidder1.amount > 0) _assertAuction(bidder1, start);
    //         else _assertAuction(Bidder(0, 0), start);
    //     }

    //     // Bidder 3 tries to bid after auction is over
    //     skip(1);
    //     _dealWETH(address(staker), bidder3.amount);
    //     vm.prank(_idToAddress(bidder3.id));
    //     vm.expectRevert(NoAuction.selector);
    //     staker.bid(Addresses.ADDR_BNB);
    // }

    // event AuctionedTokensSentToWinner(address indexed winner, address indexed token, uint256 reward);

    // function testFuzz_payAuctionWinnerBNB(
    //     uint112 fees,
    //     uint144 total,
    //     uint256 donations,
    //     Bidder memory bidder1,
    //     Bidder memory bidder2,
    //     Bidder memory bidder3
    // ) public {
    //     (, fees, donations) = testFuzz_auctionOfBNB(fees, total, donations, bidder1, bidder2, bidder3);
    //     console.log("BNB fees are", fees);
    //     console.log("WETH donations are", donations);
    //     // vm.assume(fees > 0);

    //     if (fees == 0 || bidder1.amount + bidder2.amount == 0) {
    //         vm.expectRevert(NoLot.selector);
    //     } else {
    //         vm.expectEmit();
    //         emit AuctionedTokensSentToWinner(
    //             bidder1.amount >= bidder2.amount ? _idToAddress(bidder1.id) : _idToAddress(bidder2.id),
    //             Addresses.ADDR_BNB,
    //             fees
    //         );
    //         vm.expectEmit();
    //         emit DividendsPaid(
    //             (
    //                 _idToAddress(bidder1.id) == _idToAddress(bidder2.id)
    //                     ? bidder1.amount + bidder2.amount
    //                     : (bidder1.amount >= bidder2.amount ? bidder1.amount : bidder2.amount)
    //             ) + donations
    //         );
    //     }
    //     staker.payAuctionWinner(Addresses.ADDR_BNB);
    // }

    // error NewAuctionCannotStartYet();

    // // APPLY THIS TEST AFTER THE AUCTION TEST
    // function testFuzz_startAuctionOfBNBTooEarly(
    //     uint112 fees,
    //     uint144 total,
    //     uint256 donations,
    //     uint40 timeStamp,
    //     Bidder memory bidder1,
    //     Bidder memory bidder2,
    //     Bidder memory bidder3
    // ) public {
    //     (uint256 start, , ) = testFuzz_auctionOfBNB(fees, total, donations, bidder1, bidder2, bidder3);

    //     // 2nd auction too early
    //     timeStamp = uint40(_bound(timeStamp, 0, start + SystemConstants.AUCTION_COOLDOWN - 1));
    //     vm.warp(timeStamp);
    //     vm.expectRevert(NewAuctionCannotStartYet.selector);
    //     staker.collectFeesAndStartAuction(Addresses.ADDR_BNB);
    // }

    // // SOME DONATIONS IN SOME FUNCTIONS ARE NOT WELL SPECIFIED
    // function testFuzz_start2ndAuctionOfBNB(
    //     uint112 feesBNB,
    //     uint144 totalBNB,
    //     uint256 donationsBNB,
    //     uint40 timeStamp,
    //     Bidder memory bidder1,
    //     Bidder memory bidder2,
    //     Bidder memory bidder3,
    //     uint96 donationsWETH,
    //     uint96 donationsETH,
    //     uint112 feesBNB2,
    //     uint144 totalBNB2,
    //     uint256 donationsBNB2
    // ) public {
    //     uint256 start;
    //     (start, feesBNB, ) = testFuzz_auctionOfBNB(feesBNB, totalBNB, donationsBNB, bidder1, bidder2, bidder3);
    //     vm.assume(feesBNB > 0);

    //     // (W)ETH donations
    //     donationsWETH = uint96(_bound(donationsWETH, 0, ETH_SUPPLY));
    //     donationsETH = uint96(_bound(donationsETH, 0, ETH_SUPPLY));
    //     _incrementFeesVariableInVault(Addresses.ADDR_WETH, fees, total);
    //     _dealWETH(vault, total);

    //     // Some1 donated tokens to Staker contract
    //     _dealWETH(address(staker), donationsWETH);
    //     vm.deal(address(staker), donationsETH);

    //     // 2nd auction too early
    //     timeStamp = uint40(_bound(timeStamp, start + SystemConstants.AUCTION_COOLDOWN, type(uint40).max));
    //     vm.warp(timeStamp);
    //     totalBNB2 = uint144(_bound(totalBNB2, 0, uint256(type(uint144).max) - totalBNB + feesBNB));
    //     testFuzz_startAuctionOfBNB(feesBNB2, totalBNB2, donationsBNB2);

    //     // CHECK WHAT HAPPENS WHEN ALL BIDS ARE 0!!
    // }

    // function testFuzz_nonAuctionOfWETH2ndTime(
    //     uint112 fees,
    //     uint144 total,
    //     uint96 donationsWETH,
    //     uint96 donationsETH,
    //     uint112 fees2,
    //     uint144 total2,
    //     uint96 donationsWETH2,
    //     uint96 donationsETH2
    // ) public {
    // fees = testFuzz_nonAuctionOfWETH(fees, total, donationsWETH, donationsETH);

    // // 2nd auction
    // total2 = uint144(_bound(total2, 0, uint256(type(uint144).max) - total + fees));
    // testFuzz_nonAuctionOfWETH(fees2, total2, donationsWETH2, donationsETH2);
    // }

    // TESTS ON payAuctionWinner
}

// INVARIANT TEST WITH MULTIPLE TOKENS BEING BID
