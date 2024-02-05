// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Libraries
import {SystemConstants} from "./libraries/SystemConstants.sol";
import {VaultStructs} from "./libraries/VaultStructs.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

// Contracts
import {SIR, ERC20} from "./SIR.sol";

/** @dev SIR supply is designed to fit in a 80-bit unsigned integer.
    @dev ETH supply is 120.2M approximately with 18 decimals, which fits in a 88-bit unsigned integer.
    @dev With 96 bits, we can represent 79,2B ETH, which is 659 times more than the current supply. 
 */

contract Staker is SIR {
    error UnclaimedRewardsOverflow();
    error NewAuctionCannotStartYet();
    error TokensAlreadyClaimed();
    error AuctionIsNotOver();

    uint80 public stakeTotal; // Total amount of SIR staked
    uint176 public cumETHPerSIRx80; // Q96.80, cumulative token per unit of SIR
    mapping(address => StakerInfo) public stakersInfo; // Staker info (cumETHPerSIRx80, stake, unclaimedETH)

    mapping(address => AuctionByToken) public auctions;

    struct StakerInfo {
        uint80 stake; // Amount of SIR staked
        uint176 cumETHPerSIRx80;
        uint96 unclaimedETH; // Amount of ETH owed to the staker
    }

    struct AuctionByToken {
        uint96 bestBid;
        address bestBidder;
        uint40 startTime; // Auction start time
        // uint104 auctionId; // Auction ID
        // uint104 prevAuctionId; // Previous auction ID
        bool winnerPaid; // Whether the winner has been paid
    }

    constructor(address vault, address systemControl) SIR(vault, systemControl) {}

    /*////////////////////////////////////////////////////////////////
                            STAKING FUNCTIONS 
    ////////////////////////////////////////////////////////////////*/

    function unstake(uint80 amount) external {
        // Get current unclaimed rewards
        (uint256 rewards_, StakerInfo memory stakerInfo, uint176 cumETHPerSIRx80_) = _rewards(msg.sender);
        if (rewards_ > type(uint96).max) revert UnclaimedRewardsOverflow();

        // Update staker info
        stakersInfo[msg.sender] = StakerInfo(uint80(stakerInfo.stake - amount), cumETHPerSIRx80_, uint96(rewards_));

        // Update total stake
        unchecked {
            stakeTotal -= amount; // Cannot underflow because stakeTotal >= stake >= amount
        }

        // Transfer SIR to the staker
        transfer(msg.sender, amount);
    }

    function stake() external {
        unchecked {
            // Check increase in SIR stake
            uint256 stakeTotalReal = balanceOf[address(this)];
            uint256 deposit = stakeTotalReal - stakeTotal;

            // Get current unclaimed rewards
            (uint256 rewards_, StakerInfo memory stakerInfo, uint176 cumETHPerSIRx80_) = _rewards(msg.sender);
            if (rewards_ > type(uint96).max) revert UnclaimedRewardsOverflow();

            // Update staker info
            stakersInfo[msg.sender] = StakerInfo(
                uint80(stakerInfo.stake + deposit),
                cumETHPerSIRx80_,
                uint96(rewards_)
            );

            // Update total stake
            stakeTotal = uint80(stakeTotalReal);
        }
    }

    function claim() external {
        unchecked {
            (uint256 rewards_, StakerInfo memory stakerInfo, ) = _rewards(msg.sender);
            stakersInfo[msg.sender] = StakerInfo(stakerInfo.stake, cumETHPerSIRx80, 0);

            payable(address(msg.sender)).transfer(rewards_);
        }
    }

    function rewards(address staker) public view returns (uint256 rewards_) {
        (rewards_, , ) = _rewards(staker);
    }

    function _rewards(address staker) private view returns (uint256, StakerInfo memory, uint176) {
        unchecked {
            StakerInfo memory stakerInfo = stakersInfo[staker];
            uint176 cumETHPerSIRx80_ = cumETHPerSIRx80;

            return (
                stakerInfo.unclaimedETH +
                    ((uint256(cumETHPerSIRx80_ - stakerInfo.cumETHPerSIRx80) * stakerInfo.stake) >> 80),
                stakerInfo,
                cumETHPerSIRx80_
            );
        }
    }

    /*////////////////////////////////////////////////////////////////
                        DIVIDEND PAYING FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    // function bid(address token) external {
    //     AuctionByToken memory auction = auctions[token];

    //     if (block.timestamp >= auction.startTime + SystemConstants.AUCTION_DURATION) revert AuctionIsOver();

    //     if (amount <= auction.bestBid) revert BidTooLow();

    //     // Update auction
    //     auctions[token] = AuctionByToken({
    //         bestBid: amount,
    //         bestBidder: msg.sender,
    //         startTime: auction.startTime,
    //         winnerPaid: false
    //     });

    //     // Transfer the bid to the contract
    //     TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
    // }

    // DO NOT START AUCTION IF IT IS WETH, JUST DISTRIBUTE IT!!!
    function collectFeesAndStartAuction(address token) external {
        AuctionByToken memory auction = auctions[token];

        if (block.timestamp < auction.startTime + SystemConstants.AUCTION_COOLDOWN) revert NewAuctionCannotStartYet();

        // Start a new auction
        auctions[token] = AuctionByToken({
            bestBid: 0,
            bestBidder: address(0),
            startTime: uint40(block.timestamp), // This automatically aborts any reentrancy attack
            winnerPaid: false
        });

        /** Pay the previous bidder if he has not been paid yet.
            We considered the bidder paid regardless of the success of the transfer.
         */
        _claimTokens(token, auction);

        // Retrieve fees from the vault. Reverts if no fees are available.
        VAULT.withdrawFees(token);
    }

    function claimTokens(address token) external {
        AuctionByToken memory auction = auctions[token];
        if (block.timestamp < auction.startTime + SystemConstants.AUCTION_DURATION) revert AuctionIsNotOver();

        // Update auction
        auctions[token].winnerPaid = true;

        if (!_claimTokens(token, auction)) revert TokensAlreadyClaimed();
    }

    // UPDATE CUMETHPERSIRX80!!!
    function _claimTokens(address token, AuctionByToken memory auction) private returns (bool success) {
        // Bidder already paid
        if (auction.winnerPaid) return false;

        // Only pay if there is a non-0 bid.
        if (auction.bestBid == 0) return false;

        /** Obtain reward amount
            Low-level call to avoid revert if the ERC20 token has some problems.
         */
        bytes memory data;
        (success, data) = tokens[i].call(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));

        // balanceOf failed and we cannot continue
        if (!success || data.length != 32) return false;

        // Prize is 0, so the claim is successful but without a transfer
        uint256 prize = abi.decode(data, (uint256));
        if (prize == 0) return true;

        /** Pay the winner if prize > 0
            Low-level call to avoid revert if the ERC20 token has some problems.
         */
        (success, data) = token.call(abi.encodeWithSelector(ERC20.transfer.selector, auction.bestBidder, prize));

        /** By the ERC20 standard, the transfer may go through without reverting (success == true),
            but if it returns a boolean that is false, the transfer actually failed.
         */
        if (data.length > 0 && !abi.decode(data, (bool))) return false;
    }
}
