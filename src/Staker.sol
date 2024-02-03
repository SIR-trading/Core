// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {SIR} from "./SIR.sol";
import {VaultStructs} from "./libraries/VaultStructs.sol";

/** @dev SIR supply is designed to fit in a 80-bit unsigned integer.
    @dev ETH supply is 120.2M approximately with 18 decimals, which fits in a 88-bit unsigned integer.
    @dev With 96 bits, we can represent 79,2B ETH, which is 659 times more than the current supply. 
 */

contract Staker is SIR {
    error UnclaimedRewardsOverflow();

    uint80 public stakeTotal; // Total amount of SIR staked
    uint176 public cumETHPerSIRx80; // Q96.80, cumulative token per unit of SIR
    mapping(address => StakerInfo) public stakersInfo; // Staker info (cumETHPerSIRx80, stake, unclaimedETH)

    struct StakerInfo {
        uint80 stake; // Amount of SIR staked
        uint176 cumETHPerSIRx80;
        uint96 unclaimedETH; // Amount of ETH owed to the staker
    }

    constructor(address systemState, address systemControl) SIR(systemState, systemControl) {}

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
        stakeTotal = uint80(stakeTotalReal);

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

    // mapping(address staker)
}
