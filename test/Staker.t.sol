// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {AddressesHyperEVM} from "src/libraries/AddressesHyperEVM.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {Staker} from "src/Staker.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {ErrorComputation} from "./ErrorComputation.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {TransferHelper} from "v3-core/libraries/TransferHelper.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {APE} from "src/APE.sol";
import {ABDKMath64x64} from "abdk/ABDKMath64x64.sol";

contract Auxiliary is Test {
    address internal constant STAKING_VAULT = 0x000000000051200beef00Add2e55000000000000;

    struct Bidder {
        uint256 id;
        uint96 amount;
    }

    struct TokenBalances {
        uint256 vaultTotalReserves;
        uint256 vaultTotalFees;
        uint256 stakerDonations;
    }

    struct Donations {
        uint96 stakerDonationsHYPE;
        uint96 stakerDonationsWHYPE;
    }

    uint256 constant SLOT_SUPPLY = 2;
    uint256 constant SLOT_BALANCES = 5;
    uint256 constant SLOT_INITIALIZED = 3;
    uint256 constant SLOT_TOTAL_RESERVES = 10;

    uint96 constant HYPE_SUPPLY = 1e9 * 10 ** 18;

    IWETH9 internal constant WHYPE = IWETH9(AddressesHyperEVM.ADDR_WHYPE);

    Staker public staker;
    address public vault;

    /// @dev Auxiliary function for minting SIR tokens
    function _mint(address account, uint80 amount) internal {
        // Increase supply
        uint256 slot = uint256(vm.load(address(staker), bytes32(uint256(SLOT_SUPPLY))));
        uint80 balanceOfSIR = uint80(slot) + amount;
        slot >>= 80;
        uint96 unclaimedHYPE = uint96(slot);
        vm.store(
            address(staker),
            bytes32(uint256(SLOT_SUPPLY)),
            bytes32(abi.encodePacked(uint80(0), unclaimedHYPE, balanceOfSIR))
        );
        assertEq(staker.supply(), balanceOfSIR, "Wrong supply slot used by vm.store");

        // Increase balance
        slot = uint256(vm.load(address(staker), keccak256(abi.encode(account, bytes32(uint256(SLOT_BALANCES))))));
        balanceOfSIR = uint80(slot) + amount;
        slot >>= 80;
        unclaimedHYPE = uint96(slot);
        vm.store(
            address(staker),
            keccak256(abi.encode(account, bytes32(uint256(SLOT_BALANCES)))),
            bytes32(abi.encodePacked(uint80(0), unclaimedHYPE, balanceOfSIR))
        );
        assertEq(staker.balanceOf(account), balanceOfSIR, "Wrong balance slot used by vm.store");
    }

    function _idToAddress(uint256 id) internal pure returns (address) {
        id = _bound(id, 1, 3);
        return payable(vm.addr(id));
    }

    function _setFees(address token, TokenBalances memory tokenBalances) internal {
        // Bound total reserves and fees
        if (token == AddressesHyperEVM.ADDR_WHYPE) {
            tokenBalances.vaultTotalFees = _bound(tokenBalances.vaultTotalFees, 0, HYPE_SUPPLY);
            if (IERC20(AddressesHyperEVM.ADDR_WHYPE).balanceOf(vault) > HYPE_SUPPLY) {
                tokenBalances.vaultTotalReserves = IERC20(AddressesHyperEVM.ADDR_WHYPE).balanceOf(vault);
            } else {
                tokenBalances.vaultTotalReserves = _bound(
                    tokenBalances.vaultTotalReserves,
                    IERC20(AddressesHyperEVM.ADDR_WHYPE).balanceOf(vault),
                    HYPE_SUPPLY
                );
            }
        } else {
            tokenBalances.vaultTotalFees = _bound(
                tokenBalances.vaultTotalFees,
                0,
                type(uint256).max - IERC20(token).totalSupply()
            );
            tokenBalances.vaultTotalReserves = _bound(
                tokenBalances.vaultTotalReserves,
                0,
                type(uint256).max - IERC20(token).totalSupply() - tokenBalances.vaultTotalFees
            );
            if (IERC20(token).balanceOf(vault) > tokenBalances.vaultTotalReserves + tokenBalances.vaultTotalFees) {
                tokenBalances.vaultTotalReserves = IERC20(token).balanceOf(vault) - tokenBalances.vaultTotalFees;
                tokenBalances.vaultTotalFees = _bound(
                    tokenBalances.vaultTotalFees,
                    0,
                    type(uint256).max - tokenBalances.vaultTotalReserves
                );
            }
        }

        // Set reserves in Vault
        vm.store(
            vault,
            keccak256(abi.encode(token, bytes32(uint256(SLOT_TOTAL_RESERVES)))),
            bytes32(tokenBalances.vaultTotalReserves)
        );

        // Transfer necessary reserves and fees to Vault
        if (token == AddressesHyperEVM.ADDR_WHYPE) {
            _dealWHYPE(
                vault,
                tokenBalances.vaultTotalReserves +
                    tokenBalances.vaultTotalFees -
                    IERC20(AddressesHyperEVM.ADDR_WHYPE).balanceOf(vault)
            );
        } else {
            _dealToken(
                token,
                vault,
                tokenBalances.vaultTotalReserves + tokenBalances.vaultTotalFees - IERC20(token).balanceOf(vault)
            );
        }

        // Check reserves in Vault are correct
        uint256 totalReserves_ = Vault(vault).totalReserves(token);
        assertEq(tokenBalances.vaultTotalReserves, totalReserves_, "Wrong total reserves slot used by vm.store");
        uint256 vaultTotalFees_ = IERC20(token).balanceOf(vault) - totalReserves_;
        assertEq(tokenBalances.vaultTotalFees, vaultTotalFees_, "Wrong total fees to stakers");

        // Donate tokens to Staker contract
        tokenBalances.stakerDonations = _bound(
            tokenBalances.stakerDonations,
            0,
            type(uint256).max - IERC20(token).totalSupply()
        );
        if (token == AddressesHyperEVM.ADDR_WHYPE) _dealWHYPE(address(staker), tokenBalances.stakerDonations);
        else _dealToken(token, address(staker), tokenBalances.stakerDonations);
    }

    function _setDonations(Donations memory donations) internal {
        donations.stakerDonationsWHYPE = uint96(_bound(donations.stakerDonationsWHYPE, 0, HYPE_SUPPLY));
        donations.stakerDonationsHYPE = uint96(_bound(donations.stakerDonationsHYPE, 0, HYPE_SUPPLY));

        // Donated (W)HYPE to Staker contract
        _dealWHYPE(address(staker), donations.stakerDonationsWHYPE);
        _dealHYPE(address(staker), donations.stakerDonationsHYPE);
    }

    function _setFeesInVault(address token, TokenBalances memory tokenBalances) internal {
        // Set reserves in Vault
        tokenBalances.vaultTotalReserves = _bound(
            tokenBalances.vaultTotalReserves,
            0,
            type(uint256).max - tokenBalances.vaultTotalFees
        );
        vm.store(
            vault,
            keccak256(abi.encode(token, bytes32(uint256(SLOT_TOTAL_RESERVES)))),
            bytes32(tokenBalances.vaultTotalReserves)
        );

        // Transfer necessary reserves and fees to Vault
        if (token == AddressesHyperEVM.ADDR_WHYPE) {
            _dealWHYPE(
                vault,
                tokenBalances.vaultTotalReserves +
                    tokenBalances.vaultTotalFees -
                    IERC20(AddressesHyperEVM.ADDR_WHYPE).balanceOf(vault)
            );
        } else {
            _dealToken(
                token,
                vault,
                tokenBalances.vaultTotalReserves + tokenBalances.vaultTotalFees - IERC20(token).balanceOf(vault)
            );
        }

        // Check reserves in Vault are correct
        uint256 totalReserves_ = Vault(vault).totalReserves(token);
        assertEq(tokenBalances.vaultTotalReserves, totalReserves_, "Wrong total reserves slot used by vm.store");
        uint256 vaultTotalFees_ = IERC20(token).balanceOf(vault) - totalReserves_;
        assertEq(tokenBalances.vaultTotalFees, vaultTotalFees_, "Wrong total fees to stakers");
    }

    /// @dev The Foundry deal function is not good for WHYPE because it doesn't update total supply correctly
    function _dealWHYPE(address to, uint256 amount) internal {
        hoax(address(1), amount);
        WHYPE.deposit{value: amount}();
        vm.prank(address(1));
        WHYPE.transfer(address(to), amount);
    }

    function _dealHYPE(address to, uint256 amount) internal {
        vm.deal(address(1), amount);
        vm.prank(address(1));
        payable(address(to)).transfer(amount);
    }

    function _dealToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        deal(token, address(1), amount, true);
        vm.prank(address(1));
        TransferHelper.safeTransfer(token, to, amount);
    }

    function _assertAuction(Bidder memory bidder_, uint256 timeStamp) internal view {
        SirStructs.Auction memory auction = staker.auctions(AddressesHyperEVM.ADDR_kHYPE);
        assertEq(auction.bidder, bidder_.amount == 0 ? address(0) : _idToAddress(bidder_.id), "Wrong bidder");
        assertEq(auction.bid, bidder_.amount, "Wrong bid");
        assertEq(auction.startTime, timeStamp, "Wrong start time");
    }
}

contract StakerTest is Auxiliary {
    using ABDKMath64x64 for int128;

    struct User {
        uint256 id;
        uint80 mintAmount;
        uint80 stakeAmount;
    }

    error NoFeesCollected();
    error NoAuctionLot();
    error AuctionIsNotOver();
    error BidTooLow();
    error NoAuction();
    error NewAuctionCannotStartYet();
    error NotTheAuctionWinner();

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event DividendsPaid(uint96 amountHYPE, uint80 amountStakedSIR);
    event AuctionStarted(address indexed token, uint256 feesToBeAuctioned);
    event BidReceived(address indexed bidder, address indexed token, uint96 previousBid, uint96 newBid);
    event AuctionedTokensSentToWinner(
        address indexed winner,
        address indexed beneficiary,
        address indexed token,
        uint256 reward
    );

    address alice;
    address bob;
    address charlie;

    function setUp() public {
        vm.createSelectFork("hyperevm", 12523857);

        staker = new Staker(AddressesHyperEVM.ADDR_WHYPE);

        APE ape = new APE();

        vault = address(
            new Vault(vm.addr(10), address(staker), vm.addr(12), address(ape), AddressesHyperEVM.ADDR_WHYPE)
        );
        staker.initialize(vault);

        alice = vm.addr(1);
        bob = vm.addr(2);
        charlie = vm.addr(3);
    }

    function test_RevertWhen_InitializeTwice() public {
        vm.expectRevert();
        staker.initialize(address(0));
    }

    function test_initializeWrongCaller() public {
        // Reset _initialized to false
        vm.store(address(staker), bytes32(uint256(SLOT_INITIALIZED)), bytes32(0));

        staker.initialize(address(0));
    }

    function test_RevertWhen_InitializeWrongCaller() public {
        // Reset _initialized to false
        vm.store(address(staker), bytes32(uint256(SLOT_INITIALIZED)), bytes32(0));

        vm.prank(alice);
        vm.expectRevert();
        staker.initialize(address(0));
    }

    function test_initialConditions() public view {
        assertEq(staker.supply(), 0);
        assertEq(staker.totalSupply(), 0);
        assertEq(staker.maxTotalSupply(), 0);

        assertEq(staker.balanceOf(alice), 0);
        (uint80 unlockedStake, uint80 lockedStake) = staker.stakeOf(alice);
        assertEq(unlockedStake, 0);
        assertEq(lockedStake, 0);
        assertEq(staker.balanceOf(bob), 0);
        (unlockedStake, lockedStake) = staker.stakeOf(bob);
        assertEq(unlockedStake, 0);
        assertEq(lockedStake, 0);

        assertEq(staker.name(), "Synthetics Implemented Right");
        assertEq(staker.symbol(), "HyperSIR");
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

    function testFuzz_stake(
        User memory user,
        uint80 totalSupplyOfSIR,
        uint256 delayCheck
    ) public returns (uint80 unlockedStake, uint80 lockedStake) {
        address account = _idToAddress(user.id);

        user.mintAmount = uint80(_bound(user.mintAmount, 0, totalSupplyOfSIR));
        user.stakeAmount = uint80(_bound(user.stakeAmount, 0, user.mintAmount));

        // Mint
        _mint(account, user.mintAmount);
        _mint(address(1), totalSupplyOfSIR - user.mintAmount); // Mint the rest to another account

        // Stake
        vm.expectEmit();
        emit Transfer(account, STAKING_VAULT, user.stakeAmount);
        vm.prank(account);
        staker.stake(user.stakeAmount);

        // Skip some time
        delayCheck = _bound(delayCheck, 0, 15 * 365 days);
        skip(delayCheck);

        assertEq(staker.balanceOf(account), user.mintAmount - user.stakeAmount, "Wrong balance");
        (unlockedStake, lockedStake) = staker.stakeOf(account);
        assertEq(unlockedStake + lockedStake, user.stakeAmount, "Wrong total balance");

        uint256 lockedStake_ = ABDKMath64x64.divu(delayCheck, SystemConstants.HALVING_PERIOD).neg().exp_2().mulu(
            user.stakeAmount
        );
        assertApproxEqAbs(lockedStake, lockedStake_, user.stakeAmount / 1e16, "Wrong locked stake");
        assertApproxEqAbs(
            unlockedStake,
            user.stakeAmount - lockedStake_,
            user.stakeAmount / 1e16,
            "Wrong unlocked stake"
        );

        assertEq(staker.supply(), totalSupplyOfSIR - user.stakeAmount, "Wrong supply");
        assertEq(staker.totalSupply(), totalSupplyOfSIR, "Wrong total supply");
    }

    function test_stakeEdgeCase() public {
        uint80 stakeAmount = type(uint80).max;

        // Mint
        _mint(alice, stakeAmount);

        // Stake
        vm.expectEmit();
        emit Transfer(alice, STAKING_VAULT, stakeAmount);
        vm.prank(alice);
        staker.stake(stakeAmount);

        // Skip time
        uint256 delayCheck = 192 * SystemConstants.HALVING_PERIOD - 1;
        skip(delayCheck); // Maximum value that prb-match can deal with when computing 2^x

        (uint80 unlockedStake, uint80 lockedStake) = staker.stakeOf(alice);
        uint256 lockedStake_ = ABDKMath64x64.divu(delayCheck, SystemConstants.HALVING_PERIOD).neg().exp_2().mulu(
            stakeAmount
        );
        assertApproxEqAbs(lockedStake, lockedStake_, stakeAmount / 1e16, "Wrong locked stake");
        assertApproxEqAbs(unlockedStake, stakeAmount - lockedStake_, stakeAmount / 1e16, "Wrong unlocked stake");

        // Skip 1s
        skip(1 seconds);

        (unlockedStake, lockedStake) = staker.stakeOf(alice);
        assertEq(lockedStake, 0, "Wrong locked stake");
        assertEq(unlockedStake, stakeAmount, "Wrong unlocked stake");
    }

    function testFuzz_stakeTwice(
        User memory user1,
        User memory user2,
        uint80 totalSupplyOfSIR,
        uint256 delayCheck
    ) public {
        totalSupplyOfSIR = uint80(_bound(totalSupplyOfSIR, user2.mintAmount, type(uint80).max));

        address account1 = _idToAddress(user1.id);
        address account2 = _idToAddress(user2.id);

        // 1st staker stakes
        testFuzz_stake(user1, totalSupplyOfSIR - user2.mintAmount, SystemConstants.HALVING_PERIOD);

        // 2nd staker stakes
        user2.stakeAmount = uint80(_bound(user2.stakeAmount, 0, user2.mintAmount));
        _mint(account2, user2.mintAmount);
        vm.expectEmit();
        emit Transfer(account2, STAKING_VAULT, user2.stakeAmount);
        vm.prank(account2);
        staker.stake(user2.stakeAmount);

        // Skip some time
        delayCheck = _bound(delayCheck, 0, 15 * 365 days);
        skip(delayCheck);

        // Verify balances
        if (account1 != account2) {
            assertEq(staker.balanceOf(account2), user2.mintAmount - user2.stakeAmount, "Wrong balance of account2");
            (uint80 unlockedStake, uint80 lockedStake) = staker.stakeOf(account2);
            assertEq(unlockedStake + lockedStake, user2.stakeAmount, "Wrong total balance of account2");
            assertEq(
                staker.supply(),
                totalSupplyOfSIR - user1.stakeAmount - user2.stakeAmount,
                "Wrong supply of account2"
            );
            assertEq(staker.totalSupply(), totalSupplyOfSIR, "Wrong total supply of account2");
        } else {
            assertEq(
                staker.balanceOf(account2),
                user1.mintAmount + user2.mintAmount - user1.stakeAmount - user2.stakeAmount,
                "Wrong balance"
            );
            (uint80 unlockedStake, uint80 lockedStake) = staker.stakeOf(account2);
            assertEq(
                unlockedStake + lockedStake,
                user1.stakeAmount + user2.stakeAmount,
                "Wrong total balance of account2"
            );

            uint256 lockedStake_ = ABDKMath64x64.divu(delayCheck, SystemConstants.HALVING_PERIOD).neg().exp_2().mulu(
                user1.stakeAmount / 2 + user2.stakeAmount
            );
            assertApproxEqAbs(
                lockedStake,
                lockedStake_,
                (user1.stakeAmount / 2 + user2.stakeAmount) / 1e16,
                "Wrong locked stake"
            );
            assertApproxEqAbs(
                unlockedStake,
                user1.stakeAmount + user2.stakeAmount - lockedStake_,
                (user1.stakeAmount / 2 + user2.stakeAmount) / 1e16,
                "Wrong unlocked stake"
            );

            assertEq(
                staker.supply(),
                totalSupplyOfSIR - user1.stakeAmount - user2.stakeAmount,
                "Wrong supply of account2"
            );
            assertEq(staker.totalSupply(), totalSupplyOfSIR, "Wrong total supply of account2");
        }
    }

    error NoDividends();

    function testFuzz_stakeTwiceAndGetDividends(
        User memory user1,
        User memory user2,
        uint80 totalSupplyOfSIR,
        Donations memory donations,
        uint256 delayCheck
    ) public {
        address account1 = _idToAddress(user1.id);
        address account2 = _idToAddress(user2.id);

        // Set up donations
        _setDonations(donations);

        // Stake
        testFuzz_stakeTwice(user1, user2, totalSupplyOfSIR, delayCheck);

        // No dividends before claiming
        assertEq(staker.unclaimedDividends(account1), 0);
        assertEq(staker.unclaimedDividends(account2), 0);
        vm.prank(account1);
        vm.expectRevert(NoDividends.selector);
        staker.claim();
        vm.prank(account2);
        vm.expectRevert(NoDividends.selector);
        staker.claim();

        // This triggers a payment of dividends
        if (
            donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE > 0 &&
            user1.stakeAmount + user2.stakeAmount > 0
        ) {
            vm.expectEmit();
            emit DividendsPaid(
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                user1.stakeAmount + user2.stakeAmount
            );
        } else {
            vm.expectRevert(NoFeesCollected.selector);
        }
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_WHYPE);

        // Donations
        if (
            donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE == 0 ||
            user1.stakeAmount + user2.stakeAmount == 0
        ) {
            assertEq(staker.unclaimedDividends(account1), 0, "Donations of account1 should be 0");
            assertEq(staker.unclaimedDividends(account2), 0, "Donations of account2 should be 0");
        } else if (account1 == account2) {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, user1.stakeAmount + user2.stakeAmount, 1);
            assertLe(
                staker.unclaimedDividends(account1),
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                "Donations too high"
            );
            assertApproxEqAbs(
                staker.unclaimedDividends(account1),
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                maxError,
                "Donations too low"
            );

            // Claim dividends
            vm.prank(account1);
            uint96 dividends_;
            try staker.claim() returns (uint96 dividends__) {
                dividends_ = dividends__;
            } catch {
                dividends_ = 0;
            }
            assertApproxEqAbs(
                dividends_,
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                maxError,
                "Claimed unclaimedDividends are incorrect"
            );
            assertEq(staker.unclaimedDividends(account1), 0, "Donations should be 0 after claim");
            assertApproxEqAbs(
                account1.balance,
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                maxError,
                "Balance is incorrect"
            );
            assertApproxEqAbs(address(staker).balance, 0, maxError, "Balance staker is incorrect");
        } else {
            // Verify balances of account1
            uint256 dividends = (uint256(donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE) *
                user1.stakeAmount) / (user1.stakeAmount + user2.stakeAmount);
            uint256 maxError1 = ErrorComputation.maxErrorBalance(80, user1.stakeAmount, 1);
            uint256 unclaimedDivs1 = staker.unclaimedDividends(account1);
            assertLe(unclaimedDivs1, dividends, "Donations of account1 too high");
            assertApproxEqAbs(unclaimedDivs1, dividends, maxError1, "Donations of account1 too low");

            // Claim dividends of account1
            vm.prank(account1);
            if (unclaimedDivs1 == 0) {
                vm.expectRevert(NoDividends.selector);
                staker.claim();
            } else {
                assertApproxEqAbs(
                    staker.claim(),
                    unclaimedDivs1,
                    maxError1,
                    "Claimed dividends of account1 are incorrect"
                );
            }
            assertEq(staker.unclaimedDividends(account1), 0, "Donations of account1 should be 0 after claim");
            assertApproxEqAbs(account1.balance, unclaimedDivs1, maxError1, "Balance of account1 is incorrect");

            // Verify balances of account2
            dividends =
                (uint256(donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE) * user2.stakeAmount) /
                (user1.stakeAmount + user2.stakeAmount);
            uint256 maxError2 = ErrorComputation.maxErrorBalance(80, user2.stakeAmount, 1);
            uint256 unclaimedDivs2 = staker.unclaimedDividends(account2);
            assertLe(unclaimedDivs2, dividends, "Donations of account2 too high");
            assertApproxEqAbs(unclaimedDivs2, dividends, maxError2, "Donations of account2 too low");

            // Claim dividends of account2
            vm.prank(account2);
            if (unclaimedDivs2 == 0) {
                vm.expectRevert(NoDividends.selector);
                staker.claim();
            } else {
                assertApproxEqAbs(
                    staker.claim(),
                    unclaimedDivs2,
                    maxError2,
                    "Claimed dividends of account2 are incorrect"
                );
            }
            assertEq(staker.unclaimedDividends(account2), 0, "Donations of account2 should be 0 after claim");
            assertApproxEqAbs(account2.balance, unclaimedDivs2, maxError2, "Balance of account2 is incorrect");

            // Verify balances of staker
            assertApproxEqAbs(address(staker).balance, 0, maxError1 + maxError2, "Balance staker is incorrect");
        }
    }

    function testFuzz_stakeExceedsBalance(User memory user, uint80 totalSupplyOfSIR) public {
        address account = _idToAddress(user.id);

        totalSupplyOfSIR = uint80(_bound(totalSupplyOfSIR, 1, type(uint80).max));
        user.mintAmount = uint80(_bound(user.mintAmount, 0, totalSupplyOfSIR - 1));
        user.stakeAmount = uint80(_bound(user.stakeAmount, user.mintAmount + 1, totalSupplyOfSIR));

        _mint(account, user.mintAmount);
        _mint(address(1), totalSupplyOfSIR - user.mintAmount);

        vm.expectRevert();
        vm.prank(account);
        staker.stake(user.stakeAmount);
    }

    function testFuzz_collectFeesAndStartAuctionNoFees(address token) public {
        vm.expectRevert();
        staker.collectFeesAndStartAuction(token);
    }

    function test_collectNoFeesAndStartAuction() public {
        vm.expectRevert(NoFeesCollected.selector);
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_PENDLE);
    }

    function testFuzz_unstake(
        User memory user,
        uint80 totalSupplyOfSIR,
        Donations memory donations,
        uint80 unstakeAmount,
        uint256 delayCheck
    ) public {
        address account = _idToAddress(user.id);

        // Stakes
        (uint80 unlockedStake, uint80 lockedStake) = testFuzz_stake(user, totalSupplyOfSIR, delayCheck);
        unstakeAmount = uint80(_bound(unstakeAmount, 0, unlockedStake));

        // Set up donations
        _setDonations(donations);

        // Trigger a payment of dividends
        if (donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE > 0 && user.stakeAmount > 0) {
            vm.expectEmit();
            emit DividendsPaid(donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE, user.stakeAmount);
        } else {
            vm.expectRevert(NoFeesCollected.selector);
        }
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_WHYPE);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.unclaimedDividends(account), 0);
        } else {
            assertLe(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE
            );
            assertApproxEqAbs(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1),
                "Donations before unstaking too low"
            );
        }

        // Unstakes
        vm.expectEmit();
        emit Transfer(STAKING_VAULT, account, unstakeAmount);
        vm.prank(account);
        staker.unstake(unstakeAmount);

        assertEq(staker.balanceOf(account), user.mintAmount - user.stakeAmount + unstakeAmount, "Wrong balance");
        (unlockedStake, lockedStake) = staker.stakeOf(account);
        assertEq(unlockedStake + lockedStake, user.stakeAmount - unstakeAmount, "Wrong total balance");
        assertEq(staker.supply(), totalSupplyOfSIR - user.stakeAmount + unstakeAmount, "Wrong supply");
        assertEq(staker.totalSupply(), totalSupplyOfSIR, "Wrong total supply");

        // Check dividends still there
        uint256 unclaimedDivs = staker.unclaimedDividends(account);

        if (user.stakeAmount > 0) {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1);
            assertLe(unclaimedDivs, donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE);
            assertApproxEqAbs(
                unclaimedDivs,
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                maxError,
                "Donations after unstaking too low"
            );
        }

        // Claim dividends
        vm.prank(account);
        if (unclaimedDivs == 0) {
            vm.expectRevert(NoDividends.selector);
            staker.claim();
        } else {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1);
            assertApproxEqAbs(
                staker.claim(),
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                maxError,
                "Claimed dividends are incorrect"
            );
        }

        assertEq(staker.unclaimedDividends(account), 0, "Donations should be 0 after claim");
        if (unclaimedDivs > 0) {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1);
            assertApproxEqAbs(
                account.balance,
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                maxError,
                "Balance is incorrect"
            );
        } else {
            assertEq(account.balance, 0, "Balance should be 0 when no dividends claimed");
        }
    }

    function testFuzz_unstakeAndClaim(
        User memory user,
        uint80 totalSupplyOfSIR,
        Donations memory donations,
        uint80 unstakeAmount,
        uint256 delayCheck
    ) public {
        address account = _idToAddress(user.id);

        // Stakes
        (uint80 unlockedStake, uint80 lockedStake) = testFuzz_stake(user, totalSupplyOfSIR, delayCheck);
        unstakeAmount = uint80(_bound(unstakeAmount, 0, unlockedStake));

        // Set up donations
        _setDonations(donations);

        // Trigger a payment of dividends
        uint96 dividends = donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE;
        if (dividends > 0 && user.stakeAmount > 0) {
            vm.expectEmit();
            emit DividendsPaid(dividends, user.stakeAmount);
        } else {
            vm.expectRevert(NoFeesCollected.selector);
        }
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_WHYPE);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.unclaimedDividends(account), 0);
        } else {
            assertLe(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE
            );
            assertApproxEqAbs(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1),
                "Donations before unstaking too low"
            );
        }

        // Unstakes
        vm.expectEmit();
        emit Transfer(STAKING_VAULT, account, unstakeAmount);
        vm.prank(account);

        uint96 dividends_;
        bool testAgain = false;
        try staker.unstakeAndClaim(unstakeAmount) returns (uint96 dividends__) {
            dividends_ = dividends__;
        } catch {
            // If it failed, check again it was due to a NoDividends error
            testAgain = true;
            dividends_ = 0;
        }

        if (testAgain) {
            vm.prank(account);
            vm.expectRevert(NoDividends.selector);
            staker.unstakeAndClaim(unstakeAmount);

            // And unstake
            vm.prank(account);
            vm.expectEmit();
            emit Transfer(STAKING_VAULT, account, unstakeAmount);
            staker.unstake(unstakeAmount);
        }

        assertEq(staker.unclaimedDividends(account), 0);

        assertEq(staker.balanceOf(account), user.mintAmount - user.stakeAmount + unstakeAmount, "Wrong balance");
        (unlockedStake, lockedStake) = staker.stakeOf(account);
        assertEq(unlockedStake + lockedStake, user.stakeAmount - unstakeAmount, "Wrong total balance");
        assertEq(staker.supply(), totalSupplyOfSIR - user.stakeAmount + unstakeAmount, "Wrong supply");
        assertEq(staker.totalSupply(), totalSupplyOfSIR, "Wrong total supply");

        // Check dividends still there
        assertEq(staker.unclaimedDividends(account), 0);
        if (user.stakeAmount == 0) {
            assertEq(dividends_, 0);
        } else {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1);
            assertLe(dividends_, dividends);
            assertApproxEqAbs(
                dividends_,
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                maxError,
                "Donations after unstaking too low"
            );
        }
    }

    function testFuzz_unstakeExceedsUnlockedStake(
        User memory user,
        uint80 totalSupplyOfSIR,
        Donations memory donations,
        uint80 unstakeAmount,
        uint256 delayCheck
    ) public {
        address account = _idToAddress(user.id);

        // Stakes
        user.stakeAmount = uint80(_bound(user.stakeAmount, 0, type(uint80).max - 1));
        (uint80 unlockedStake, ) = testFuzz_stake(user, totalSupplyOfSIR, delayCheck);
        unstakeAmount = uint80(_bound(unstakeAmount, unlockedStake + 1, type(uint80).max));

        // Set up donations
        _setDonations(donations);

        // Trigger a payment of dividends
        vm.assume(donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE > 0 && user.stakeAmount > 0);
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_WHYPE);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.unclaimedDividends(account), 0);
        } else {
            assertLe(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE
            );
            assertApproxEqAbs(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1),
                "Donations before unstaking too low"
            );
        }

        // Unstakes
        vm.expectRevert();
        vm.prank(account);
        staker.unstake(unstakeAmount);
    }

    function testFuzz_unstakeAndClaimExceedsStake(
        User memory user,
        uint80 totalSupplyOfSIR,
        Donations memory donations,
        uint80 unstakeAmount,
        uint256 delayCheck
    ) public {
        address account = _idToAddress(user.id);

        // Stakes
        user.stakeAmount = uint80(_bound(user.stakeAmount, 0, type(uint80).max - 1));
        (uint80 unlockedStake, ) = testFuzz_stake(user, totalSupplyOfSIR, delayCheck);
        unstakeAmount = uint80(_bound(unstakeAmount, unlockedStake + 1, type(uint80).max));

        // Set up donations
        _setDonations(donations);

        // Trigger a payment of dividends
        vm.assume(donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE > 0 && user.stakeAmount > 0);
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_WHYPE);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.unclaimedDividends(account), 0);
        } else {
            assertLe(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE
            );
            assertApproxEqAbs(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1),
                "Donations before unstaking too low"
            );
        }

        // Unstakes
        vm.expectRevert();
        vm.prank(account);
        staker.unstakeAndClaim(unstakeAmount);
    }

    // /////////////////////////////////////////////////////////
    // ///////////// AUCTION // AND // DIVIDENDS /////////////
    // ///////////////////////////////////////////////////////

    function testFuzz_payNoAuctionWinner(address bidder, address token, address beneficiary) public {
        vm.expectRevert(bidder == address(0) ? NoAuctionLot.selector : NotTheAuctionWinner.selector);
        vm.prank(bidder);
        staker.getAuctionLot(token, beneficiary);
    }

    function testFuzz_nonAuctionOfWHYPE(
        TokenBalances memory tokenBalances,
        Donations memory donations,
        User memory user,
        uint80 totalSupplyOfSIR
    ) public {
        // Set up fees
        tokenBalances.stakerDonations = 0; // Since token is WHYPE, tokenBalances.stakerDonations is redundant with donations.stakerDonationsWHYPE
        _setFees(AddressesHyperEVM.ADDR_WHYPE, tokenBalances);

        // Set up donations
        _setDonations(donations);

        // Stake
        testFuzz_stake(user, totalSupplyOfSIR, 0);

        bool noFees = uint256(tokenBalances.vaultTotalFees) +
            donations.stakerDonationsWHYPE +
            donations.stakerDonationsHYPE ==
            0 ||
            user.stakeAmount == 0;
        if (noFees) {
            vm.expectRevert(NoFeesCollected.selector);
        } else {
            if (tokenBalances.vaultTotalFees > 0) {
                // Transfer event if there are WHYPE fees
                vm.expectEmit();
                emit Transfer(vault, address(staker), tokenBalances.vaultTotalFees);
            }
            // DividendsPaid event if there are any WHYPE fees or (W)HYPE donations
            vm.expectEmit();
            emit DividendsPaid(
                uint96(tokenBalances.vaultTotalFees) + donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE,
                user.stakeAmount
            );
        }

        // Pay WHYPE fees and donations
        uint256 fees = staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_WHYPE);
        if (!noFees) assertEq(fees, tokenBalances.vaultTotalFees);
    }

    function testFuzz_nonAuctionOfWHYPE2ndTime(
        TokenBalances memory tokenBalances,
        Donations memory donations,
        User memory user,
        uint80 totalSupplyOfSIR,
        uint40 timeSkip,
        TokenBalances memory tokenBalances2,
        Donations memory donations2
    ) public {
        testFuzz_nonAuctionOfWHYPE(tokenBalances, donations, user, totalSupplyOfSIR);

        // Set up fees
        tokenBalances2.stakerDonations = 0; // Since token is WHYPE, tokenBalances.stakerDonations is redundant with donations.stakerDonationsWHYPE
        _setFees(AddressesHyperEVM.ADDR_WHYPE, tokenBalances2);

        // Set up donations
        _setDonations(donations2);

        // 2nd auction
        skip(timeSkip);
        bool noFees = uint256(tokenBalances2.vaultTotalFees) +
            donations2.stakerDonationsWHYPE +
            donations2.stakerDonationsHYPE ==
            0 ||
            user.stakeAmount == 0;
        if (noFees) {
            vm.expectRevert(NoFeesCollected.selector);
        } else {
            if (tokenBalances2.vaultTotalFees > 0) {
                // Transfer event if there are WHYPE fees
                vm.expectEmit();
                emit Transfer(vault, address(staker), tokenBalances2.vaultTotalFees);
            }
            // DividendsPaid event if there are any WHYPE fees or (W)HYPE donations
            vm.expectEmit();
            emit DividendsPaid(
                uint96(tokenBalances2.vaultTotalFees) +
                    donations2.stakerDonationsWHYPE +
                    donations2.stakerDonationsHYPE,
                user.stakeAmount
            );
        }
        uint256 fees = staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_WHYPE);
        if (!noFees) assertEq(fees, tokenBalances2.vaultTotalFees);
    }

    function testFuzz_auctionWinnerAlreadyPaid(
        TokenBalances memory tokenBalances,
        Donations memory donations,
        User memory user,
        uint80 totalSupplyOfSIR,
        address beneficiary
    ) public {
        testFuzz_nonAuctionOfWHYPE(tokenBalances, donations, user, totalSupplyOfSIR);
        vm.assume(tokenBalances.vaultTotalFees > 0);

        // Reverts because prize has already been paid
        vm.prank(address(0)); // WHYPE does not do auctions
        vm.expectRevert(NoAuctionLot.selector);
        staker.getAuctionLot(AddressesHyperEVM.ADDR_WHYPE, beneficiary);

        vm.expectRevert(NoFeesCollected.selector);
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_WHYPE);
    }

    function testFuzz_startAuctionOfkHYPE(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations
    ) public {
        // User stakes
        testFuzz_stake(user, totalSupplyOfSIR, 0);

        // Set up fees
        _setFees(AddressesHyperEVM.ADDR_kHYPE, tokenBalances);
        vm.assume(tokenBalances.vaultTotalFees + tokenBalances.stakerDonations > 0);

        // Set up donations
        _setDonations(donations);

        // Start auction
        if (user.stakeAmount > 0 && donations.stakerDonationsHYPE + donations.stakerDonationsWHYPE > 0) {
            vm.expectEmit();
            emit DividendsPaid(donations.stakerDonationsHYPE + donations.stakerDonationsWHYPE, user.stakeAmount);
        }
        vm.expectEmit();
        emit Transfer(vault, address(staker), tokenBalances.vaultTotalFees);
        vm.expectEmit();
        emit AuctionStarted(AddressesHyperEVM.ADDR_kHYPE, tokenBalances.vaultTotalFees + tokenBalances.stakerDonations);
        assertEq(
            staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_kHYPE),
            tokenBalances.vaultTotalFees + tokenBalances.stakerDonations
        );
    }

    function testFuzz_auctionOfWHYPEFails(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        uint96 amount
    ) public {
        // User stakes
        testFuzz_stake(user, totalSupplyOfSIR, 0);
        vm.assume(user.stakeAmount > 0);

        // Set up fees
        tokenBalances.stakerDonations = 0; // Since token is WHYPE, tokenBalances.stakerDonations is redundant with donations.stakerDonationsWHYPE
        _setFees(AddressesHyperEVM.ADDR_WHYPE, tokenBalances);
        vm.assume(tokenBalances.vaultTotalFees + donations.stakerDonationsWHYPE + donations.stakerDonationsHYPE > 0);

        // Set up donations
        _setDonations(donations);

        // Start auction?
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_WHYPE);

        // No auction
        WHYPE.approve(address(staker), amount);
        vm.expectRevert(NoAuction.selector);
        staker.bid(AddressesHyperEVM.ADDR_WHYPE, amount);

        SirStructs.Auction memory auction = staker.auctions(AddressesHyperEVM.ADDR_WHYPE);
        assertEq(auction.bidder, address(0), "Bidder should be 0");
        assertEq(auction.bid, 0, "Bid should be 0");
        assertEq(auction.startTime, 0, "Start time should be 0");

        WHYPE.approve(address(staker), amount);
        vm.expectRevert(NoAuction.selector);
        staker.bid(AddressesHyperEVM.ADDR_WHYPE, amount);
    }

    function testFuzz_startAuctionOfkHYPENoFees(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations
    ) public {
        // User stakes
        testFuzz_stake(user, totalSupplyOfSIR, 0);

        // Set up fees - ensure no fees from vault AND no donations to staker
        tokenBalances.vaultTotalFees = 0;
        tokenBalances.stakerDonations = 0;  // This must also be 0 for no auction
        _setFees(AddressesHyperEVM.ADDR_kHYPE, tokenBalances);

        // Set up donations
        _setDonations(donations);

        // Start auction - should revert when no fees at all
        vm.expectRevert(NoFeesCollected.selector);
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_kHYPE);
    }

    function testFuzz_payAuctionWinnerTooSoon(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        address bidder,
        uint96 amount,
        address beneficiary,
        uint256 delay
    ) public {
        testFuzz_startAuctionOfkHYPE(user, totalSupplyOfSIR, tokenBalances, donations);
        vm.assume(tokenBalances.vaultTotalFees + tokenBalances.stakerDonations > 0);

        // Bid
        amount = uint96(_bound(amount, 1, HYPE_SUPPLY));
        _dealWHYPE(bidder, amount);
        vm.prank(bidder);
        WHYPE.approve(address(staker), amount);
        vm.prank(bidder);
        staker.bid(AddressesHyperEVM.ADDR_kHYPE, amount);

        // Attempt to get auction lot
        delay = _bound(delay, 0, SystemConstants.AUCTION_DURATION - 1);
        skip(delay);
        vm.expectRevert(AuctionIsNotOver.selector);
        staker.getAuctionLot(AddressesHyperEVM.ADDR_kHYPE, beneficiary);
    }

    function testFuzz_payAuctionWinnerNoBids(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        address beneficiary,
        uint256 delay
    ) public {
        testFuzz_startAuctionOfkHYPE(user, totalSupplyOfSIR, tokenBalances, donations);
        vm.assume(tokenBalances.vaultTotalFees + tokenBalances.stakerDonations > 0);

        // Attempt to get auction lot
        delay = _bound(delay, SystemConstants.AUCTION_DURATION, type(uint40).max);
        skip(SystemConstants.AUCTION_DURATION);
        vm.prank(address(0));
        vm.expectRevert(NoAuctionLot.selector);
        staker.getAuctionLot(AddressesHyperEVM.ADDR_kHYPE, beneficiary);
    }

    function testFuzz_auctionOfkHYPE(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        Bidder memory bidder1,
        Bidder memory bidder2,
        Bidder memory bidder3
    ) public returns (uint256 start) {
        start = block.timestamp;

        testFuzz_startAuctionOfkHYPE(user, totalSupplyOfSIR, tokenBalances, donations);

        bidder1.amount = uint96(_bound(bidder1.amount, 0, HYPE_SUPPLY));
        bidder2.amount = uint96(_bound(bidder1.amount, 0, HYPE_SUPPLY));
        bidder3.amount = uint96(_bound(bidder1.amount, 0, HYPE_SUPPLY));

        // Bidder 1
        _dealWHYPE(_idToAddress(bidder1.id), bidder1.amount);
        vm.prank(_idToAddress(bidder1.id));
        WHYPE.approve(address(staker), bidder1.amount);
        if (bidder1.amount > 0) {
            vm.expectEmit();
            emit BidReceived(_idToAddress(bidder1.id), AddressesHyperEVM.ADDR_kHYPE, 0, bidder1.amount);
        } else {
            vm.expectRevert(BidTooLow.selector);
        }
        vm.prank(_idToAddress(bidder1.id));
        staker.bid(AddressesHyperEVM.ADDR_kHYPE, bidder1.amount);

        // Assert auction parameters
        if (bidder1.amount > 0) _assertAuction(bidder1, start);
        else _assertAuction(Bidder(0, 0), start);

        // Bidder 2
        skip(SystemConstants.AUCTION_DURATION - 1);
        _dealWHYPE(_idToAddress(bidder2.id), bidder2.amount);
        vm.prank(_idToAddress(bidder2.id));
        WHYPE.approve(address(staker), bidder2.amount);
        if (_idToAddress(bidder1.id) == _idToAddress(bidder2.id)) {
            if (bidder2.amount > 0) {
                // Bidder increases its own bid
                vm.expectEmit();
                emit BidReceived(
                    _idToAddress(bidder2.id),
                    AddressesHyperEVM.ADDR_kHYPE,
                    bidder1.amount,
                    bidder1.amount + bidder2.amount
                );
            } else {
                // Bidder fails to increase its own bid
                vm.expectRevert(BidTooLow.selector);
            }
        } else if (bidder2.amount > (uint256(bidder1.amount) * 105) / 100) {
            // Bidder2 outbids bidder1 (must be more than 5% higher)
            vm.expectEmit();
            emit BidReceived(_idToAddress(bidder2.id), AddressesHyperEVM.ADDR_kHYPE, bidder1.amount, bidder2.amount);
        } else {
            // Bidder2 fails to outbid bidder1 (5% minimum increase not met)
            vm.expectRevert(BidTooLow.selector);
        }
        vm.prank(_idToAddress(bidder2.id));
        staker.bid(AddressesHyperEVM.ADDR_kHYPE, bidder2.amount);

        // Assert auction parameters
        if (_idToAddress(bidder1.id) == _idToAddress(bidder2.id)) {
            if (bidder2.amount > 0) {
                _assertAuction(Bidder(bidder2.id, bidder1.amount + bidder2.amount), start);
            } else {
                if (bidder1.amount > 0) _assertAuction(bidder1, start);
                else _assertAuction(Bidder(0, 0), start);
            }
        } else if (bidder2.amount > (uint256(bidder1.amount) * 105) / 100) {
            _assertAuction(bidder2, start);
        } else {
            if (bidder1.amount > 0) _assertAuction(bidder1, start);
            else _assertAuction(Bidder(0, 0), start);
        }

        // Bidder 3 tries to bid after auction is over. It doesn't revert its transfer so it becomes a donation.
        skip(1);
        _dealWHYPE(address(staker), bidder3.amount);
        vm.prank(_idToAddress(bidder3.id));
        WHYPE.approve(address(staker), bidder3.amount);
        vm.prank(_idToAddress(bidder3.id));
        vm.expectRevert(NoAuction.selector);
        staker.bid(AddressesHyperEVM.ADDR_kHYPE, bidder3.amount);
    }

    function testFuzz_payAuctionWinnerkHYPE(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        Bidder memory bidder1,
        Bidder memory bidder2,
        Bidder memory bidder3,
        address fakeBidder,
        address beneficiary
    ) public {
        testFuzz_auctionOfkHYPE(user, totalSupplyOfSIR, tokenBalances, donations, bidder1, bidder2, bidder3);

        // Find the winner
        address winner = bidder1.amount + bidder2.amount == 0
            ? address(0)
            : (bidder1.amount >= bidder2.amount ? _idToAddress(bidder1.id) : _idToAddress(bidder2.id));

        // Wrong bidder
        vm.assume(fakeBidder != winner);
        vm.prank(fakeBidder);
        vm.expectRevert(NotTheAuctionWinner.selector);
        staker.getAuctionLot(AddressesHyperEVM.ADDR_kHYPE, beneficiary);

        if (bidder1.amount + bidder2.amount == 0) {
            vm.expectRevert(NoAuctionLot.selector);
        } else {
            if (user.stakeAmount > 0) {
                vm.expectEmit();
                emit DividendsPaid(
                    (
                        _idToAddress(bidder1.id) == _idToAddress(bidder2.id)
                            ? bidder1.amount + bidder2.amount
                            : (bidder1.amount >= bidder2.amount ? bidder1.amount : bidder2.amount)
                    ) + bidder3.amount,
                    user.stakeAmount
                );
            }
            winner = bidder1.amount >= bidder2.amount ? _idToAddress(bidder1.id) : _idToAddress(bidder2.id);
            vm.expectEmit();
            emit AuctionedTokensSentToWinner(
                winner,
                beneficiary == address(0) ? winner : beneficiary,
                AddressesHyperEVM.ADDR_kHYPE,
                tokenBalances.vaultTotalFees + tokenBalances.stakerDonations
            );
        }

        // Pay auction winner
        vm.prank(winner);
        staker.getAuctionLot(AddressesHyperEVM.ADDR_kHYPE, beneficiary);

        // Attempt to pay auction winner again
        vm.prank(winner);
        vm.expectRevert(NoAuctionLot.selector);
        staker.getAuctionLot(AddressesHyperEVM.ADDR_kHYPE, beneficiary);
    }

    function testFuzz_cannotPayAuctionOfWHYPE(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        uint96 amount,
        address beneficiary
    ) public {
        testFuzz_auctionOfWHYPEFails(user, totalSupplyOfSIR, tokenBalances, donations, amount);

        skip(SystemConstants.AUCTION_DURATION + 1);

        vm.prank(address(0));
        vm.expectRevert(NoAuctionLot.selector);
        staker.getAuctionLot(AddressesHyperEVM.ADDR_WHYPE, beneficiary);

        vm.prank(address(0));
        vm.expectRevert(NoAuctionLot.selector);
        staker.getAuctionLot(AddressesHyperEVM.ADDR_kHYPE, beneficiary);
    }

    function testFuzz_start2ndAuctionOfkHYPETooEarly(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        Bidder memory bidder1,
        Bidder memory bidder2,
        Bidder memory bidder3,
        uint256 timeStamp
    ) public {
        uint256 start = testFuzz_auctionOfkHYPE(
            user,
            totalSupplyOfSIR,
            tokenBalances,
            donations,
            bidder1,
            bidder2,
            bidder3
        );

        // 2nd auction too early
        timeStamp = _bound(timeStamp, 0, start + SystemConstants.AUCTION_COOLDOWN - 1);
        vm.warp(timeStamp);
        console.log("vaultTotalFees", tokenBalances.vaultTotalFees);
        console.log("stakerDonations", tokenBalances.stakerDonations);
        // Check if there are ANY fees (vault fees OR staker donations)
        if (tokenBalances.vaultTotalFees == 0 && tokenBalances.stakerDonations == 0) {
            vm.expectRevert(bytes("ST"));
        } else {
            vm.expectRevert(NewAuctionCannotStartYet.selector);
        }
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_kHYPE);
    }

    function testFuzz_2ndAuctionOfkHYPE(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        Bidder memory bidder1,
        Bidder memory bidder2,
        Bidder memory bidder3,
        TokenBalances memory tokenBalances2
    ) public {
        // Bound the first auction values to avoid massive numbers that break bounding logic
        tokenBalances.vaultTotalReserves = _bound(tokenBalances.vaultTotalReserves, 1000, 1e20);
        tokenBalances.vaultTotalFees = _bound(tokenBalances.vaultTotalFees, 1000, 1e20);
        tokenBalances.stakerDonations = _bound(tokenBalances.stakerDonations, 1000, 1e20);

        testFuzz_auctionOfkHYPE(user, totalSupplyOfSIR, tokenBalances, donations, bidder1, bidder2, bidder3);
        vm.assume(bidder1.amount + bidder2.amount > 0);

        // Bound the second auction values to reasonable amounts
        tokenBalances2.vaultTotalFees = _bound(tokenBalances2.vaultTotalFees, 1000, 1e18);
        tokenBalances2.stakerDonations = _bound(tokenBalances2.stakerDonations, 1000, 1e18);

        // Set up fees for 2nd auction
        _setFees(AddressesHyperEVM.ADDR_kHYPE, tokenBalances2);

        // Skip time
        skip(SystemConstants.AUCTION_COOLDOWN);

        // Start 2nd auction - this will collect fees from vault and start the auction
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_kHYPE);

        // Verify there's a balance for the auction and the auction started
        assertGt(
            IERC20(AddressesHyperEVM.ADDR_kHYPE).balanceOf(address(staker)),
            0,
            "Should have kHYPE for auction"
        );

        // Verify auction is active
        SirStructs.Auction memory auction = staker.auctions(AddressesHyperEVM.ADDR_kHYPE);
        assertGt(auction.startTime, 0, "Auction should have started");
    }

    // /////////////////////////////////////////////////////////
    // ///////////// NATIVE HYPE BIDDING TESTS ///////////////
    // ///////////////////////////////////////////////////////

    function test_nativeHYPEBidding() public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesHyperEVM.ADDR_kHYPE, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_kHYPE);

        // Test native HYPE bidding
        uint96 bidAmount = 10e18;
        vm.deal(alice, bidAmount);

        vm.expectEmit();
        emit BidReceived(alice, AddressesHyperEVM.ADDR_kHYPE, 0, bidAmount);

        vm.prank(alice);
        staker.bid{value: bidAmount}(AddressesHyperEVM.ADDR_kHYPE, 0); // amount param ignored

        // Verify bid was recorded correctly
        SirStructs.Auction memory auction = staker.auctions(AddressesHyperEVM.ADDR_kHYPE);
        assertEq(auction.bidder, alice, "Wrong bidder");
        assertEq(auction.bid, bidAmount, "Wrong bid amount");

        // Verify WHYPE was wrapped
        assertEq(WHYPE.balanceOf(address(staker)), bidAmount, "WHYPE not wrapped correctly");
    }

    function testFuzz_nativeHYPEBiddingIgnoresAmountParam(uint96 amountParam, uint96 msgValue) public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesHyperEVM.ADDR_kHYPE, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_kHYPE);

        // Bound msg.value to reasonable amount
        msgValue = uint96(_bound(msgValue, 1e15, HYPE_SUPPLY));
        vm.deal(alice, msgValue);

        // Bid with native HYPE - amount param should be ignored
        vm.prank(alice);
        staker.bid{value: msgValue}(AddressesHyperEVM.ADDR_kHYPE, amountParam);

        // Verify only msg.value was used, not amountParam
        SirStructs.Auction memory auction = staker.auctions(AddressesHyperEVM.ADDR_kHYPE);
        assertEq(auction.bid, msgValue, "Should use msg.value, not amount param");
        assertEq(WHYPE.balanceOf(address(staker)), msgValue, "Wrong WHYPE balance");
    }

    function test_mixedNativeAndWHYPEBidding() public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesHyperEVM.ADDR_kHYPE, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_kHYPE);

        // First bid with native HYPE
        uint96 nativeBid = 10e18;
        vm.deal(alice, nativeBid);
        vm.prank(alice);
        staker.bid{value: nativeBid}(AddressesHyperEVM.ADDR_kHYPE, 0);

        // Second bid with WHYPE (must be 5% higher)
        uint96 whypeBid = 11e18; // More than 5% higher
        _dealWHYPE(bob, whypeBid);
        vm.prank(bob);
        WHYPE.approve(address(staker), whypeBid);

        vm.expectEmit();
        emit BidReceived(bob, AddressesHyperEVM.ADDR_kHYPE, nativeBid, whypeBid);

        vm.prank(bob);
        staker.bid(AddressesHyperEVM.ADDR_kHYPE, whypeBid);

        // Verify alice got refunded in WHYPE
        assertEq(WHYPE.balanceOf(alice), nativeBid, "Alice should receive WHYPE refund");

        // Third bid with native HYPE again (must be 5% higher than bob's bid)
        uint96 secondNativeBid = 12e18; // More than 5% higher than 11e18
        vm.deal(charlie, secondNativeBid);

        vm.expectEmit();
        emit BidReceived(charlie, AddressesHyperEVM.ADDR_kHYPE, whypeBid, secondNativeBid);

        vm.prank(charlie);
        staker.bid{value: secondNativeBid}(AddressesHyperEVM.ADDR_kHYPE, 999e18); // amount ignored

        // Verify bob got refunded in WHYPE
        assertEq(WHYPE.balanceOf(bob), whypeBid, "Bob should receive WHYPE refund");

        // Verify final auction state
        SirStructs.Auction memory auction = staker.auctions(AddressesHyperEVM.ADDR_kHYPE);
        assertEq(auction.bidder, charlie, "Charlie should be the winner");
        assertEq(auction.bid, secondNativeBid, "Wrong final bid amount");
    }

    function test_nativeHYPEBidIncrease() public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesHyperEVM.ADDR_kHYPE, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_kHYPE);

        // First bid with native HYPE
        uint96 firstBid = 10e18;
        vm.deal(alice, firstBid);
        vm.prank(alice);
        staker.bid{value: firstBid}(AddressesHyperEVM.ADDR_kHYPE, 0);

        // Same bidder increases bid with more native HYPE
        uint96 increaseBid = 5e18;
        vm.deal(alice, increaseBid);

        vm.expectEmit();
        emit BidReceived(alice, AddressesHyperEVM.ADDR_kHYPE, firstBid, firstBid + increaseBid);

        vm.prank(alice);
        staker.bid{value: increaseBid}(AddressesHyperEVM.ADDR_kHYPE, 0);

        // Verify bid was increased correctly
        SirStructs.Auction memory auction = staker.auctions(AddressesHyperEVM.ADDR_kHYPE);
        assertEq(auction.bidder, alice, "Wrong bidder");
        assertEq(auction.bid, firstBid + increaseBid, "Wrong bid amount");
        assertEq(WHYPE.balanceOf(address(staker)), firstBid + increaseBid, "Wrong WHYPE balance");
    }

    function testFuzz_nativeHYPEBidTooLow(uint96 firstBid, uint96 secondBid) public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesHyperEVM.ADDR_kHYPE, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_kHYPE);

        // First bid
        firstBid = uint96(_bound(firstBid, 1e15, 1000e18));
        vm.deal(alice, firstBid);
        vm.prank(alice);
        staker.bid{value: firstBid}(AddressesHyperEVM.ADDR_kHYPE, 0);

        // Second bid that's too low (not 5% higher)
        secondBid = uint96(_bound(secondBid, 1, (firstBid * 105) / 100 - 1));
        vm.deal(bob, secondBid);

        vm.prank(bob);
        vm.expectRevert(BidTooLow.selector);
        staker.bid{value: secondBid}(AddressesHyperEVM.ADDR_kHYPE, 0);

        // Verify first bidder is still the winner
        SirStructs.Auction memory auction = staker.auctions(AddressesHyperEVM.ADDR_kHYPE);
        assertEq(auction.bidder, alice, "Alice should still be the winner");
        assertEq(auction.bid, firstBid, "Bid should not have changed");
    }

    function test_nativeHYPEBidZeroValue() public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesHyperEVM.ADDR_kHYPE, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_kHYPE);

        // Try to bid with 0 msg.value - should fall back to WHYPE transfer
        // Since alice has no WHYPE and no approval, this should revert with transfer error
        vm.prank(alice);
        vm.expectRevert();
        staker.bid{value: 0}(AddressesHyperEVM.ADDR_kHYPE, 10e18);
    }

    function test_nativeHYPEAndWHYPERefunds() public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesHyperEVM.ADDR_kHYPE, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesHyperEVM.ADDR_kHYPE);

        // Alice bids with native HYPE
        uint96 aliceBid = 10e18;
        vm.deal(alice, aliceBid);
        vm.prank(alice);
        staker.bid{value: aliceBid}(AddressesHyperEVM.ADDR_kHYPE, 0);

        // Bob outbids with WHYPE
        uint96 bobBid = 11e18;
        _dealWHYPE(bob, bobBid);
        vm.prank(bob);
        WHYPE.approve(address(staker), bobBid);
        vm.prank(bob);
        staker.bid(AddressesHyperEVM.ADDR_kHYPE, bobBid);

        // Alice should receive WHYPE refund (not native HYPE)
        assertEq(alice.balance, 0, "Alice should not receive ETH refund");
        assertEq(WHYPE.balanceOf(alice), aliceBid, "Alice should receive WHYPE refund");

        // Charlie outbids with native HYPE
        uint96 charlieBid = 12e18;
        vm.deal(charlie, charlieBid);
        vm.prank(charlie);
        staker.bid{value: charlieBid}(AddressesHyperEVM.ADDR_kHYPE, 0);

        // Bob should receive WHYPE refund (bob gets back the same amount he bid)
        assertEq(WHYPE.balanceOf(bob), bobBid, "Bob should receive full WHYPE refund");
    }
}

contract StakerHandler is Auxiliary {
    address constant COLLATERAL1 = AddressesHyperEVM.ADDR_WHYPE;
    address constant COLLATERAL2 = AddressesHyperEVM.ADDR_kHYPE;

    address public user1 = _idToAddress(1);
    address public user2 = _idToAddress(2);
    address public user3 = _idToAddress(3);

    uint256 public currentTime;

    constructor() {
        // vm.writeFile("./InvariantStaker.log", "");
        currentTime = 1694616791;

        staker = new Staker(AddressesHyperEVM.ADDR_WHYPE);

        address ape = address(new APE());

        vault = address(new Vault(vm.addr(10), address(staker), vm.addr(12), ape, AddressesHyperEVM.ADDR_WHYPE));
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
        (uint80 unlockedStake, uint80 lockedStake) = staker.stakeOf(user);
        amount = uint80(_bound(amount, 0, unlockedStake + lockedStake));
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
        //     string.concat("User ", vm.toString(user), " claims ", vm.toString(dividends), " HYPE")
        // );
    }

    function bid(
        uint256 timeSkip,
        uint256 userId,
        bool collateralSelect,
        uint96 amount,
        bool useNativeHYPE
    ) external advanceTime(timeSkip) {
        address user = _idToAddress(userId);
        address collateral = collateralSelect ? COLLATERAL1 : COLLATERAL2;

        // Bid
        amount = uint96(_bound(amount, 0, HYPE_SUPPLY));
        // vm.writeLine(
        //     "./InvariantStaker.log",
        //     string.concat(
        //         "User ",
        //         vm.toString(user),
        //         " bids ",
        //         vm.toString(collateral),
        //         " collateral with ",
        //         vm.toString(amount),
        //         useNativeHYPE ? " native HYPE" : " WHYPE"
        //     )
        // );

        if (useNativeHYPE) {
            // Bid with native HYPE
            vm.deal(user, amount);
            vm.prank(user);
            staker.bid{value: amount}(collateral, 0); // amount param ignored when using native
        } else {
            // Bid with WHYPE
            _dealWHYPE(user, amount);
            vm.prank(user);
            WHYPE.approve(address(staker), amount);
            vm.prank(user);
            staker.bid(collateral, amount);
        }
    }

    function collectFeesAndStartAuction(
        uint256 timeSkip,
        TokenBalances memory tokenBalances,
        bool collateralSelect
    ) external advanceTime(timeSkip) {
        address collateral = collateralSelect ? COLLATERAL1 : COLLATERAL2;
        // vm.writeLine(
        //     "./InvariantStaker.log",
        //     string.concat("Collects fees for ", vm.toString(collateral), " and starts auction")
        // );

        // Set fees in vault
        _setFees(collateral, tokenBalances);

        // Collect fees and start auction
        staker.collectFeesAndStartAuction(collateral);
    }

    function getAuctionLot(uint256 timeSkip, bool collateralSelect) external advanceTime(timeSkip) {
        address collateral = collateralSelect ? COLLATERAL1 : COLLATERAL2;
        // vm.writeLine("./InvariantStaker.log", string.concat("Pays winner of ", vm.toString(collateral), " auction"));

        // Pay auction winner
        SirStructs.Auction memory auction = staker.auctions(collateral);
        vm.prank(auction.bidder);
        staker.getAuctionLot(collateral, address(0));
    }

    function donate(uint256 timeSkip, Donations memory donations) external advanceTime(timeSkip) {
        // Set donations in vault
        _setDonations(donations);

        // vm.writeLine(
        //     "./InvariantStaker.log",
        //     string.concat(
        //         "Donations: ",
        //         vm.toString(donations.stakerDonationsHYPE),
        //         " HYPE and ",
        //         vm.toString(donations.stakerDonationsWHYPE),
        //         " WHYPE"
        //     )
        // );
    }
}

contract StakerInvariantTest is Test {
    StakerHandler stakerHandler;
    Staker staker;

    function setUp() external {
        vm.createSelectFork("hyperevm", 12523857);

        stakerHandler = new StakerHandler();
        staker = Staker(stakerHandler.staker());

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = stakerHandler.stake.selector;
        selectors[1] = stakerHandler.unstake.selector;
        selectors[2] = stakerHandler.claim.selector;
        selectors[3] = stakerHandler.bid.selector;
        selectors[4] = stakerHandler.collectFeesAndStartAuction.selector;
        selectors[5] = stakerHandler.getAuctionLot.selector;
        selectors[6] = stakerHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(stakerHandler), selectors: selectors}));
    }

    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_stakerBalances() public view {
        assertGe(
            address(staker).balance,
            uint256(staker.unclaimedDividends(stakerHandler.user1())) +
                staker.unclaimedDividends(stakerHandler.user2()) +
                staker.unclaimedDividends(stakerHandler.user3()),
            "Staker's balance should be at least the sum of all dividends"
        );
    }
}
