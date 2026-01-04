// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {AddressesMegaETHTest} from "src/libraries/AddressesMegaETHTest.sol";
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
        uint96 stakerDonationsETH;
        uint96 stakerDonationsWETH;
    }

    uint256 constant SLOT_SUPPLY = 2;
    uint256 constant SLOT_BALANCES = 5;
    uint256 constant SLOT_INITIALIZED = 3;
    uint256 constant SLOT_TOTAL_RESERVES = 12; // +1 due to OracleChange struct in Vault

    uint96 constant ETH_SUPPLY = 1e9 * 10 ** 18;

    IWETH9 internal constant WETH = IWETH9(AddressesMegaETHTest.ADDR_WETH);

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
        // Use higher private key indices (100-102) to avoid collision with deployed contracts on forked networks
        id = _bound(id, 100, 102);
        return payable(vm.addr(id));
    }

    function _setFees(address token, TokenBalances memory tokenBalances) internal {
        // Bound total reserves and fees
        if (token == AddressesMegaETHTest.ADDR_WETH) {
            tokenBalances.vaultTotalFees = _bound(tokenBalances.vaultTotalFees, 0, ETH_SUPPLY);
            if (IERC20(AddressesMegaETHTest.ADDR_WETH).balanceOf(vault) > ETH_SUPPLY) {
                tokenBalances.vaultTotalReserves = IERC20(AddressesMegaETHTest.ADDR_WETH).balanceOf(vault);
            } else {
                tokenBalances.vaultTotalReserves = _bound(
                    tokenBalances.vaultTotalReserves,
                    IERC20(AddressesMegaETHTest.ADDR_WETH).balanceOf(vault),
                    ETH_SUPPLY
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
        if (token == AddressesMegaETHTest.ADDR_WETH) {
            _dealWETH(
                vault,
                tokenBalances.vaultTotalReserves +
                    tokenBalances.vaultTotalFees -
                    IERC20(AddressesMegaETHTest.ADDR_WETH).balanceOf(vault)
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
        if (token == AddressesMegaETHTest.ADDR_WETH) _dealWETH(address(staker), tokenBalances.stakerDonations);
        else _dealToken(token, address(staker), tokenBalances.stakerDonations);
    }

    function _setDonations(Donations memory donations) internal {
        donations.stakerDonationsWETH = uint96(_bound(donations.stakerDonationsWETH, 0, ETH_SUPPLY));
        donations.stakerDonationsETH = uint96(_bound(donations.stakerDonationsETH, 0, ETH_SUPPLY));

        // Donated (W)ETH to Staker contract
        _dealWETH(address(staker), donations.stakerDonationsWETH);
        _dealETH(address(staker), donations.stakerDonationsETH);
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
        if (token == AddressesMegaETHTest.ADDR_WETH) {
            _dealWETH(
                vault,
                tokenBalances.vaultTotalReserves +
                    tokenBalances.vaultTotalFees -
                    IERC20(AddressesMegaETHTest.ADDR_WETH).balanceOf(vault)
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
        deal(token, address(1), amount, true);
        vm.prank(address(1));
        TransferHelper.safeTransfer(token, to, amount);
    }

    function _assertAuction(Bidder memory bidder_, uint256 timeStamp) internal view {
        SirStructs.Auction memory auction = staker.auctions(AddressesMegaETHTest.ADDR_USDC);
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
    event DividendsPaid(uint96 amountETH, uint80 amountStakedSIR);
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
        vm.createSelectFork("megatest_alchemy", 5655720);

        staker = new Staker(AddressesMegaETHTest.ADDR_WETH);

        APE ape = new APE();

        vault = address(
            new Vault(vm.addr(10), address(staker), vm.addr(12), address(ape), AddressesMegaETHTest.ADDR_WETH)
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
        assertEq(staker.symbol(), "MegaSIR");
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
            donations.stakerDonationsWETH + donations.stakerDonationsETH > 0 &&
            user1.stakeAmount + user2.stakeAmount > 0
        ) {
            vm.expectEmit();
            emit DividendsPaid(
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
                user1.stakeAmount + user2.stakeAmount
            );
        } else {
            vm.expectRevert(NoFeesCollected.selector);
        }
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_WETH);

        // Donations
        if (
            donations.stakerDonationsWETH + donations.stakerDonationsETH == 0 ||
            user1.stakeAmount + user2.stakeAmount == 0
        ) {
            assertEq(staker.unclaimedDividends(account1), 0, "Donations of account1 should be 0");
            assertEq(staker.unclaimedDividends(account2), 0, "Donations of account2 should be 0");
        } else if (account1 == account2) {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, user1.stakeAmount + user2.stakeAmount, 1);
            assertLe(
                staker.unclaimedDividends(account1),
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
                "Donations too high"
            );
            assertApproxEqAbs(
                staker.unclaimedDividends(account1),
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
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
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
                maxError,
                "Claimed unclaimedDividends are incorrect"
            );
            assertEq(staker.unclaimedDividends(account1), 0, "Donations should be 0 after claim");
            assertApproxEqAbs(
                account1.balance,
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
                maxError,
                "Balance is incorrect"
            );
            assertApproxEqAbs(address(staker).balance, 0, maxError, "Balance staker is incorrect");
        } else {
            // Verify balances of account1
            uint256 dividends = (uint256(donations.stakerDonationsWETH + donations.stakerDonationsETH) *
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
                (uint256(donations.stakerDonationsWETH + donations.stakerDonationsETH) * user2.stakeAmount) /
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
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC);
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
        if (donations.stakerDonationsWETH + donations.stakerDonationsETH > 0 && user.stakeAmount > 0) {
            vm.expectEmit();
            emit DividendsPaid(donations.stakerDonationsWETH + donations.stakerDonationsETH, user.stakeAmount);
        } else {
            vm.expectRevert(NoFeesCollected.selector);
        }
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_WETH);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.unclaimedDividends(account), 0);
        } else {
            assertLe(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWETH + donations.stakerDonationsETH
            );
            assertApproxEqAbs(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
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
            assertLe(unclaimedDivs, donations.stakerDonationsWETH + donations.stakerDonationsETH);
            assertApproxEqAbs(
                unclaimedDivs,
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
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
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
                maxError,
                "Claimed dividends are incorrect"
            );
        }

        assertEq(staker.unclaimedDividends(account), 0, "Donations should be 0 after claim");
        if (unclaimedDivs > 0) {
            uint256 maxError = ErrorComputation.maxErrorBalance(80, user.stakeAmount, 1);
            assertApproxEqAbs(
                account.balance,
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
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
        uint96 dividends = donations.stakerDonationsWETH + donations.stakerDonationsETH;
        if (dividends > 0 && user.stakeAmount > 0) {
            vm.expectEmit();
            emit DividendsPaid(dividends, user.stakeAmount);
        } else {
            vm.expectRevert(NoFeesCollected.selector);
        }
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_WETH);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.unclaimedDividends(account), 0);
        } else {
            assertLe(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWETH + donations.stakerDonationsETH
            );
            assertApproxEqAbs(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
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
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
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
        vm.assume(donations.stakerDonationsWETH + donations.stakerDonationsETH > 0 && user.stakeAmount > 0);
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_WETH);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.unclaimedDividends(account), 0);
        } else {
            assertLe(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWETH + donations.stakerDonationsETH
            );
            assertApproxEqAbs(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
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
        vm.assume(donations.stakerDonationsWETH + donations.stakerDonationsETH > 0 && user.stakeAmount > 0);
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_WETH);

        // Check dividends
        if (user.stakeAmount == 0) {
            assertEq(staker.unclaimedDividends(account), 0);
        } else {
            assertLe(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWETH + donations.stakerDonationsETH
            );
            assertApproxEqAbs(
                staker.unclaimedDividends(account),
                donations.stakerDonationsWETH + donations.stakerDonationsETH,
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

    function testFuzz_nonAuctionOfWETH(
        TokenBalances memory tokenBalances,
        Donations memory donations,
        User memory user,
        uint80 totalSupplyOfSIR
    ) public {
        // Set up fees
        tokenBalances.stakerDonations = 0; // Since token is WETH, tokenBalances.stakerDonations is redundant with donations.stakerDonationsWETH
        _setFees(AddressesMegaETHTest.ADDR_WETH, tokenBalances);

        // Set up donations
        _setDonations(donations);

        // Stake
        testFuzz_stake(user, totalSupplyOfSIR, 0);

        bool noFees = uint256(tokenBalances.vaultTotalFees) +
            donations.stakerDonationsWETH +
            donations.stakerDonationsETH ==
            0 ||
            user.stakeAmount == 0;
        if (noFees) {
            vm.expectRevert(NoFeesCollected.selector);
        } else {
            if (tokenBalances.vaultTotalFees > 0) {
                // Transfer event if there are WETH fees
                vm.expectEmit();
                emit Transfer(vault, address(staker), tokenBalances.vaultTotalFees);
            }
            // DividendsPaid event if there are any WETH fees or (W)ETH donations
            vm.expectEmit();
            emit DividendsPaid(
                uint96(tokenBalances.vaultTotalFees) + donations.stakerDonationsWETH + donations.stakerDonationsETH,
                user.stakeAmount
            );
        }

        // Pay WETH fees and donations
        uint256 fees = staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_WETH);
        if (!noFees) assertEq(fees, tokenBalances.vaultTotalFees);
    }

    function testFuzz_nonAuctionOfWETH2ndTime(
        TokenBalances memory tokenBalances,
        Donations memory donations,
        User memory user,
        uint80 totalSupplyOfSIR,
        uint40 timeSkip,
        TokenBalances memory tokenBalances2,
        Donations memory donations2
    ) public {
        testFuzz_nonAuctionOfWETH(tokenBalances, donations, user, totalSupplyOfSIR);

        // Set up fees
        tokenBalances2.stakerDonations = 0; // Since token is WETH, tokenBalances.stakerDonations is redundant with donations.stakerDonationsWETH
        _setFees(AddressesMegaETHTest.ADDR_WETH, tokenBalances2);

        // Set up donations
        _setDonations(donations2);

        // 2nd auction
        skip(timeSkip);
        bool noFees = uint256(tokenBalances2.vaultTotalFees) +
            donations2.stakerDonationsWETH +
            donations2.stakerDonationsETH ==
            0 ||
            user.stakeAmount == 0;
        if (noFees) {
            vm.expectRevert(NoFeesCollected.selector);
        } else {
            if (tokenBalances2.vaultTotalFees > 0) {
                // Transfer event if there are WETH fees
                vm.expectEmit();
                emit Transfer(vault, address(staker), tokenBalances2.vaultTotalFees);
            }
            // DividendsPaid event if there are any WETH fees or (W)ETH donations
            vm.expectEmit();
            emit DividendsPaid(
                uint96(tokenBalances2.vaultTotalFees) +
                    donations2.stakerDonationsWETH +
                    donations2.stakerDonationsETH,
                user.stakeAmount
            );
        }
        uint256 fees = staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_WETH);
        if (!noFees) assertEq(fees, tokenBalances2.vaultTotalFees);
    }

    function testFuzz_auctionWinnerAlreadyPaid(
        TokenBalances memory tokenBalances,
        Donations memory donations,
        User memory user,
        uint80 totalSupplyOfSIR,
        address beneficiary
    ) public {
        testFuzz_nonAuctionOfWETH(tokenBalances, donations, user, totalSupplyOfSIR);
        vm.assume(tokenBalances.vaultTotalFees > 0);

        // Reverts because prize has already been paid
        vm.prank(address(0)); // WETH does not do auctions
        vm.expectRevert(NoAuctionLot.selector);
        staker.getAuctionLot(AddressesMegaETHTest.ADDR_WETH, beneficiary);

        vm.expectRevert(NoFeesCollected.selector);
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_WETH);
    }

    function testFuzz_startAuctionOfUSDC(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations
    ) public {
        // User stakes
        testFuzz_stake(user, totalSupplyOfSIR, 0);

        // Set up fees
        _setFees(AddressesMegaETHTest.ADDR_USDC, tokenBalances);
        vm.assume(tokenBalances.vaultTotalFees + tokenBalances.stakerDonations > 0);

        // Set up donations
        _setDonations(donations);

        // Start auction
        if (user.stakeAmount > 0 && donations.stakerDonationsETH + donations.stakerDonationsWETH > 0) {
            vm.expectEmit();
            emit DividendsPaid(donations.stakerDonationsETH + donations.stakerDonationsWETH, user.stakeAmount);
        }
        vm.expectEmit();
        emit Transfer(vault, address(staker), tokenBalances.vaultTotalFees);
        vm.expectEmit();
        emit AuctionStarted(AddressesMegaETHTest.ADDR_USDC, tokenBalances.vaultTotalFees + tokenBalances.stakerDonations);
        assertEq(
            staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC),
            tokenBalances.vaultTotalFees + tokenBalances.stakerDonations
        );
    }

    function testFuzz_auctionOfWETHFails(
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
        tokenBalances.stakerDonations = 0; // Since token is WETH, tokenBalances.stakerDonations is redundant with donations.stakerDonationsWETH
        _setFees(AddressesMegaETHTest.ADDR_WETH, tokenBalances);
        vm.assume(tokenBalances.vaultTotalFees + donations.stakerDonationsWETH + donations.stakerDonationsETH > 0);

        // Set up donations
        _setDonations(donations);

        // Start auction?
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_WETH);

        // No auction
        WETH.approve(address(staker), amount);
        vm.expectRevert(NoAuction.selector);
        staker.bid(AddressesMegaETHTest.ADDR_WETH, amount);

        SirStructs.Auction memory auction = staker.auctions(AddressesMegaETHTest.ADDR_WETH);
        assertEq(auction.bidder, address(0), "Bidder should be 0");
        assertEq(auction.bid, 0, "Bid should be 0");
        assertEq(auction.startTime, 0, "Start time should be 0");

        WETH.approve(address(staker), amount);
        vm.expectRevert(NoAuction.selector);
        staker.bid(AddressesMegaETHTest.ADDR_WETH, amount);
    }

    function testFuzz_startAuctionOfUSDCNoFees(
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
        _setFees(AddressesMegaETHTest.ADDR_USDC, tokenBalances);

        // Set up donations
        _setDonations(donations);

        // Start auction - should revert when no fees at all
        vm.expectRevert(NoFeesCollected.selector);
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC);
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
        testFuzz_startAuctionOfUSDC(user, totalSupplyOfSIR, tokenBalances, donations);
        vm.assume(tokenBalances.vaultTotalFees + tokenBalances.stakerDonations > 0);

        // Bid
        amount = uint96(_bound(amount, 1, ETH_SUPPLY));
        _dealWETH(bidder, amount);
        vm.prank(bidder);
        WETH.approve(address(staker), amount);
        vm.prank(bidder);
        staker.bid(AddressesMegaETHTest.ADDR_USDC, amount);

        // Attempt to get auction lot
        delay = _bound(delay, 0, SystemConstants.AUCTION_DURATION - 1);
        skip(delay);
        vm.expectRevert(AuctionIsNotOver.selector);
        staker.getAuctionLot(AddressesMegaETHTest.ADDR_USDC, beneficiary);
    }

    function testFuzz_payAuctionWinnerNoBids(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        address beneficiary,
        uint256 delay
    ) public {
        testFuzz_startAuctionOfUSDC(user, totalSupplyOfSIR, tokenBalances, donations);
        vm.assume(tokenBalances.vaultTotalFees + tokenBalances.stakerDonations > 0);

        // Attempt to get auction lot
        delay = _bound(delay, SystemConstants.AUCTION_DURATION, type(uint40).max);
        skip(SystemConstants.AUCTION_DURATION);
        vm.prank(address(0));
        vm.expectRevert(NoAuctionLot.selector);
        staker.getAuctionLot(AddressesMegaETHTest.ADDR_USDC, beneficiary);
    }

    function testFuzz_auctionOfUSDC(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        Bidder memory bidder1,
        Bidder memory bidder2,
        Bidder memory bidder3
    ) public returns (uint256 start) {
        start = block.timestamp;

        testFuzz_startAuctionOfUSDC(user, totalSupplyOfSIR, tokenBalances, donations);

        bidder1.amount = uint96(_bound(bidder1.amount, 0, ETH_SUPPLY));
        bidder2.amount = uint96(_bound(bidder1.amount, 0, ETH_SUPPLY));
        bidder3.amount = uint96(_bound(bidder1.amount, 0, ETH_SUPPLY));

        // Bidder 1
        _dealWETH(_idToAddress(bidder1.id), bidder1.amount);
        vm.prank(_idToAddress(bidder1.id));
        WETH.approve(address(staker), bidder1.amount);
        if (bidder1.amount > 0) {
            vm.expectEmit();
            emit BidReceived(_idToAddress(bidder1.id), AddressesMegaETHTest.ADDR_USDC, 0, bidder1.amount);
        } else {
            vm.expectRevert(BidTooLow.selector);
        }
        vm.prank(_idToAddress(bidder1.id));
        staker.bid(AddressesMegaETHTest.ADDR_USDC, bidder1.amount);

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
                vm.expectEmit();
                emit BidReceived(
                    _idToAddress(bidder2.id),
                    AddressesMegaETHTest.ADDR_USDC,
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
            emit BidReceived(_idToAddress(bidder2.id), AddressesMegaETHTest.ADDR_USDC, bidder1.amount, bidder2.amount);
        } else {
            // Bidder2 fails to outbid bidder1 (5% minimum increase not met)
            vm.expectRevert(BidTooLow.selector);
        }
        vm.prank(_idToAddress(bidder2.id));
        staker.bid(AddressesMegaETHTest.ADDR_USDC, bidder2.amount);

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
        _dealWETH(address(staker), bidder3.amount);
        vm.prank(_idToAddress(bidder3.id));
        WETH.approve(address(staker), bidder3.amount);
        vm.prank(_idToAddress(bidder3.id));
        vm.expectRevert(NoAuction.selector);
        staker.bid(AddressesMegaETHTest.ADDR_USDC, bidder3.amount);
    }

    function testFuzz_payAuctionWinnerUSDC(
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
        testFuzz_auctionOfUSDC(user, totalSupplyOfSIR, tokenBalances, donations, bidder1, bidder2, bidder3);

        // Find the winner
        address winner = bidder1.amount + bidder2.amount == 0
            ? address(0)
            : (bidder1.amount >= bidder2.amount ? _idToAddress(bidder1.id) : _idToAddress(bidder2.id));

        // Wrong bidder
        vm.assume(fakeBidder != winner);
        vm.prank(fakeBidder);
        vm.expectRevert(NotTheAuctionWinner.selector);
        staker.getAuctionLot(AddressesMegaETHTest.ADDR_USDC, beneficiary);

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
                AddressesMegaETHTest.ADDR_USDC,
                tokenBalances.vaultTotalFees + tokenBalances.stakerDonations
            );
        }

        // Pay auction winner
        vm.prank(winner);
        staker.getAuctionLot(AddressesMegaETHTest.ADDR_USDC, beneficiary);

        // Attempt to pay auction winner again
        vm.prank(winner);
        vm.expectRevert(NoAuctionLot.selector);
        staker.getAuctionLot(AddressesMegaETHTest.ADDR_USDC, beneficiary);
    }

    function testFuzz_cannotPayAuctionOfWETH(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        uint96 amount,
        address beneficiary
    ) public {
        testFuzz_auctionOfWETHFails(user, totalSupplyOfSIR, tokenBalances, donations, amount);

        skip(SystemConstants.AUCTION_DURATION + 1);

        vm.prank(address(0));
        vm.expectRevert(NoAuctionLot.selector);
        staker.getAuctionLot(AddressesMegaETHTest.ADDR_WETH, beneficiary);

        vm.prank(address(0));
        vm.expectRevert(NoAuctionLot.selector);
        staker.getAuctionLot(AddressesMegaETHTest.ADDR_USDC, beneficiary);
    }

    function testFuzz_start2ndAuctionOfUSDCTooEarly(
        User memory user,
        uint80 totalSupplyOfSIR,
        TokenBalances memory tokenBalances,
        Donations memory donations,
        Bidder memory bidder1,
        Bidder memory bidder2,
        Bidder memory bidder3,
        uint256 timeStamp
    ) public {
        uint256 start = testFuzz_auctionOfUSDC(
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
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC);
    }

    function testFuzz_2ndAuctionOfUSDC(
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

        testFuzz_auctionOfUSDC(user, totalSupplyOfSIR, tokenBalances, donations, bidder1, bidder2, bidder3);
        vm.assume(bidder1.amount + bidder2.amount > 0);

        // Bound the second auction values to reasonable amounts
        tokenBalances2.vaultTotalFees = _bound(tokenBalances2.vaultTotalFees, 1000, 1e18);
        tokenBalances2.stakerDonations = _bound(tokenBalances2.stakerDonations, 1000, 1e18);

        // Set up fees for 2nd auction
        _setFees(AddressesMegaETHTest.ADDR_USDC, tokenBalances2);

        // Skip time
        skip(SystemConstants.AUCTION_COOLDOWN);

        // Start 2nd auction - this will collect fees from vault and start the auction
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC);

        // Verify there's a balance for the auction and the auction started
        assertGt(
            IERC20(AddressesMegaETHTest.ADDR_USDC).balanceOf(address(staker)),
            0,
            "Should have USDC for auction"
        );

        // Verify auction is active
        SirStructs.Auction memory auction = staker.auctions(AddressesMegaETHTest.ADDR_USDC);
        assertGt(auction.startTime, 0, "Auction should have started");
    }

    // /////////////////////////////////////////////////////////
    // ///////////// NATIVE ETH BIDDING TESTS ///////////////
    // ///////////////////////////////////////////////////////

    function test_nativeETHBidding() public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesMegaETHTest.ADDR_USDC, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC);

        // Test native ETH bidding
        uint96 bidAmount = 10e18;
        vm.deal(alice, bidAmount);

        vm.expectEmit();
        emit BidReceived(alice, AddressesMegaETHTest.ADDR_USDC, 0, bidAmount);

        vm.prank(alice);
        staker.bid{value: bidAmount}(AddressesMegaETHTest.ADDR_USDC, 0); // amount param ignored

        // Verify bid was recorded correctly
        SirStructs.Auction memory auction = staker.auctions(AddressesMegaETHTest.ADDR_USDC);
        assertEq(auction.bidder, alice, "Wrong bidder");
        assertEq(auction.bid, bidAmount, "Wrong bid amount");

        // Verify WETH was wrapped
        assertEq(WETH.balanceOf(address(staker)), bidAmount, "WETH not wrapped correctly");
    }

    function testFuzz_nativeETHBiddingIgnoresAmountParam(uint96 amountParam, uint96 msgValue) public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesMegaETHTest.ADDR_USDC, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC);

        // Bound msg.value to reasonable amount
        msgValue = uint96(_bound(msgValue, 1e15, ETH_SUPPLY));
        vm.deal(alice, msgValue);

        // Bid with native ETH - amount param should be ignored
        vm.prank(alice);
        staker.bid{value: msgValue}(AddressesMegaETHTest.ADDR_USDC, amountParam);

        // Verify only msg.value was used, not amountParam
        SirStructs.Auction memory auction = staker.auctions(AddressesMegaETHTest.ADDR_USDC);
        assertEq(auction.bid, msgValue, "Should use msg.value, not amount param");
        assertEq(WETH.balanceOf(address(staker)), msgValue, "Wrong WETH balance");
    }

    function test_mixedNativeAndWETHBidding() public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesMegaETHTest.ADDR_USDC, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC);

        // First bid with native ETH
        uint96 nativeBid = 10e18;
        vm.deal(alice, nativeBid);
        vm.prank(alice);
        staker.bid{value: nativeBid}(AddressesMegaETHTest.ADDR_USDC, 0);

        // Second bid with WETH (must be 5% higher)
        uint96 wethBid = 11e18; // More than 5% higher
        _dealWETH(bob, wethBid);
        vm.prank(bob);
        WETH.approve(address(staker), wethBid);

        vm.expectEmit();
        emit BidReceived(bob, AddressesMegaETHTest.ADDR_USDC, nativeBid, wethBid);

        vm.prank(bob);
        staker.bid(AddressesMegaETHTest.ADDR_USDC, wethBid);

        // Verify alice got refunded in WETH
        assertEq(WETH.balanceOf(alice), nativeBid, "Alice should receive WETH refund");

        // Third bid with native ETH again (must be 5% higher than bob's bid)
        uint96 secondNativeBid = 12e18; // More than 5% higher than 11e18
        vm.deal(charlie, secondNativeBid);

        vm.expectEmit();
        emit BidReceived(charlie, AddressesMegaETHTest.ADDR_USDC, wethBid, secondNativeBid);

        vm.prank(charlie);
        staker.bid{value: secondNativeBid}(AddressesMegaETHTest.ADDR_USDC, 999e18); // amount ignored

        // Verify bob got refunded in WETH
        assertEq(WETH.balanceOf(bob), wethBid, "Bob should receive WETH refund");

        // Verify final auction state
        SirStructs.Auction memory auction = staker.auctions(AddressesMegaETHTest.ADDR_USDC);
        assertEq(auction.bidder, charlie, "Charlie should be the winner");
        assertEq(auction.bid, secondNativeBid, "Wrong final bid amount");
    }

    function test_nativeETHBidIncrease() public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesMegaETHTest.ADDR_USDC, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC);

        // First bid with native ETH
        uint96 firstBid = 10e18;
        vm.deal(alice, firstBid);
        vm.prank(alice);
        staker.bid{value: firstBid}(AddressesMegaETHTest.ADDR_USDC, 0);

        // Same bidder increases bid with more native ETH
        uint96 increaseBid = 5e18;
        vm.deal(alice, increaseBid);

        vm.expectEmit();
        emit BidReceived(alice, AddressesMegaETHTest.ADDR_USDC, firstBid, firstBid + increaseBid);

        vm.prank(alice);
        staker.bid{value: increaseBid}(AddressesMegaETHTest.ADDR_USDC, 0);

        // Verify bid was increased correctly
        SirStructs.Auction memory auction = staker.auctions(AddressesMegaETHTest.ADDR_USDC);
        assertEq(auction.bidder, alice, "Wrong bidder");
        assertEq(auction.bid, firstBid + increaseBid, "Wrong bid amount");
        assertEq(WETH.balanceOf(address(staker)), firstBid + increaseBid, "Wrong WETH balance");
    }

    function testFuzz_nativeETHBidTooLow(uint96 firstBid, uint96 secondBid) public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesMegaETHTest.ADDR_USDC, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC);

        // First bid
        firstBid = uint96(_bound(firstBid, 1e15, 1000e18));
        vm.deal(alice, firstBid);
        vm.prank(alice);
        staker.bid{value: firstBid}(AddressesMegaETHTest.ADDR_USDC, 0);

        // Second bid that's too low (not 5% higher)
        secondBid = uint96(_bound(secondBid, 1, (firstBid * 105) / 100 - 1));
        vm.deal(bob, secondBid);

        vm.prank(bob);
        vm.expectRevert(BidTooLow.selector);
        staker.bid{value: secondBid}(AddressesMegaETHTest.ADDR_USDC, 0);

        // Verify first bidder is still the winner
        SirStructs.Auction memory auction = staker.auctions(AddressesMegaETHTest.ADDR_USDC);
        assertEq(auction.bidder, alice, "Alice should still be the winner");
        assertEq(auction.bid, firstBid, "Bid should not have changed");
    }

    function test_nativeETHBidZeroValue() public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesMegaETHTest.ADDR_USDC, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC);

        // Try to bid with 0 msg.value - should fall back to WETH transfer
        // Since alice has no WETH and no approval, this should revert with transfer error
        vm.prank(alice);
        vm.expectRevert();
        staker.bid{value: 0}(AddressesMegaETHTest.ADDR_USDC, 10e18);
    }

    function test_nativeETHAndWETHRefunds() public {
        // Start an auction
        User memory user = User(1, 1000e18, 500e18);
        testFuzz_stake(user, 1000e18, 0);

        TokenBalances memory tokenBalances;
        tokenBalances.vaultTotalFees = 100e18;
        tokenBalances.stakerDonations = 50e18;
        _setFees(AddressesMegaETHTest.ADDR_USDC, tokenBalances);

        Donations memory donations;
        staker.collectFeesAndStartAuction(AddressesMegaETHTest.ADDR_USDC);

        // Alice bids with native ETH
        uint96 aliceBid = 10e18;
        vm.deal(alice, aliceBid);
        vm.prank(alice);
        staker.bid{value: aliceBid}(AddressesMegaETHTest.ADDR_USDC, 0);

        // Bob outbids with WETH
        uint96 bobBid = 11e18;
        _dealWETH(bob, bobBid);
        vm.prank(bob);
        WETH.approve(address(staker), bobBid);
        vm.prank(bob);
        staker.bid(AddressesMegaETHTest.ADDR_USDC, bobBid);

        // Alice should receive WETH refund (not native ETH)
        assertEq(alice.balance, 0, "Alice should not receive ETH refund");
        assertEq(WETH.balanceOf(alice), aliceBid, "Alice should receive WETH refund");

        // Charlie outbids with native ETH
        uint96 charlieBid = 12e18;
        vm.deal(charlie, charlieBid);
        vm.prank(charlie);
        staker.bid{value: charlieBid}(AddressesMegaETHTest.ADDR_USDC, 0);

        // Bob should receive WETH refund (bob gets back the same amount he bid)
        assertEq(WETH.balanceOf(bob), bobBid, "Bob should receive full WETH refund");
    }
}

contract StakerHandler is Auxiliary {
    address constant COLLATERAL1 = AddressesMegaETHTest.ADDR_WETH;
    address constant COLLATERAL2 = AddressesMegaETHTest.ADDR_USDC;

    address public user1 = _idToAddress(100);
    address public user2 = _idToAddress(101);
    address public user3 = _idToAddress(102);

    uint256 public currentTime;

    constructor() {
        // vm.writeFile("./InvariantStaker.log", "");
        currentTime = 1694616791;

        staker = new Staker(AddressesMegaETHTest.ADDR_WETH);

        address ape = address(new APE());

        vault = address(new Vault(vm.addr(10), address(staker), vm.addr(12), ape, AddressesMegaETHTest.ADDR_WETH));
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
        //     string.concat("User ", vm.toString(user), " claims ", vm.toString(dividends), " ETH")
        // );
    }

    function bid(
        uint256 timeSkip,
        uint256 userId,
        bool collateralSelect,
        uint96 amount,
        bool useNativeETH
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
        //         useNativeETH ? " native ETH" : " WETH"
        //     )
        // );

        if (useNativeETH) {
            // Bid with native ETH
            vm.deal(user, amount);
            vm.prank(user);
            staker.bid{value: amount}(collateral, 0); // amount param ignored when using native
        } else {
            // Bid with WETH
            _dealWETH(user, amount);
            vm.prank(user);
            WETH.approve(address(staker), amount);
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
        //         vm.toString(donations.stakerDonationsETH),
        //         " ETH and ",
        //         vm.toString(donations.stakerDonationsWETH),
        //         " WETH"
        //     )
        // );
    }
}

contract StakerInvariantTest is Test {
    StakerHandler stakerHandler;
    Staker staker;

    function setUp() external {
        vm.createSelectFork("megatest_alchemy", 5655720);

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
