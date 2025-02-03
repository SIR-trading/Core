// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {SystemConstants} from "./libraries/SystemConstants.sol";
import {Contributors} from "./libraries/Contributors.sol";
import {Staker} from "./Staker.sol";
import {SystemControlAccess} from "./SystemControlAccess.sol";

import "forge-std/console.sol";

/** @notice The SIR ERC-20 token is managed partially here and by the Staker contract.
    @notice In particular this contract handles the external functions for minting SIR by contributors,
    @notice who have a fixed allocation for the first 3 years, and LPers. 
 */
contract SIR is Staker, SystemControlAccess {
    event RewardsClaimed(address indexed contributor, uint256 indexed vaultId, uint80 rewards);

    mapping(address => uint40) internal timestampLastMint;

    bool private _mintingAllowed = true;

    constructor(address weth, address systemControl) Staker(weth) SystemControlAccess(systemControl) {}

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @param contributor whose unclaimed SIR rewards are to be checked
        @return unclaimed SIR rewards of a contributor
     */
    function contributorUnclaimedSIR(address contributor) public view returns (uint80) {
        unchecked {
            // Get the contributor's allocation
            uint256 allocation = Contributors.getAllocation(contributor);

            // No allocation, no rewards
            if (allocation == 0) return 0;

            // First issuance date
            uint40 timestampIssuanceStart = vault.TIMESTAMP_ISSUANCE_START();

            // Last issuance date
            uint256 timestampIssuanceEnd = timestampIssuanceStart + SystemConstants.THREE_YEARS;

            // Get last mint time stamp
            uint256 timestampLastMint_ = timestampLastMint[contributor];

            // Contributor has already claimed all rewards
            if (timestampLastMint_ >= timestampIssuanceEnd) return 0;

            // If timestampLastMint[contributor] had never been set
            if (timestampLastMint_ == 0) timestampLastMint_ = timestampIssuanceStart;

            // Calculate the contributor's issuance
            uint256 issuance = (allocation * (SystemConstants.ISSUANCE - SystemConstants.LP_ISSUANCE_FIRST_3_YEARS)) /
                type(uint56).max;

            // Update unclaimed rewards
            uint256 timestampNow = block.timestamp >= timestampIssuanceEnd ? timestampIssuanceEnd : block.timestamp;

            // Return unclaimed rewards
            return uint80(issuance * (timestampNow - timestampLastMint_));
        }
    }

    function ISSUANCE_RATE() external pure returns (uint72) {
        return SystemConstants.ISSUANCE;
    }

    function LP_ISSUANCE_FIRST_3_YEARS() external pure returns (uint72) {
        return SystemConstants.LP_ISSUANCE_FIRST_3_YEARS;
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @return rewards in SIR received by a contributor
     */
    function contributorMint() public returns (uint80 rewards) {
        require(_mintingAllowed);

        // Get contributor's unclaimed rewards
        rewards = contributorUnclaimedSIR(msg.sender);

        // Mint if there are any unclaimed rewards
        require(rewards > 0);
        _mint(msg.sender, rewards);

        // Update time stamp
        timestampLastMint[msg.sender] = uint40(block.timestamp);
    }

    /** @param vaultId of the vault for which the LPer wants to claim SIR
        @return rewards in SIR received by an LPer
     */
    function lPerMint(uint256 vaultId) public returns (uint80 rewards) {
        require(_mintingAllowed);

        // Get LPer issuance parameters
        rewards = vault.claimSIR(vaultId, msg.sender);

        // Mint if there are any unclaimed rewards
        require(rewards > 0);
        _mint(msg.sender, rewards);

        emit RewardsClaimed(msg.sender, vaultId, rewards);
    }

    /** @notice Auxiliary function for minting SIR rewards and staking them immediately in one call
     */
    function contributorMintAndStake() external returns (uint80 rewards) {
        // Get unclaimed rewards
        rewards = contributorMint();

        // Stake them immediately
        stake(rewards);
    }

    /** @notice Auxiliary function for minting SIR rewards and staking them immediately in one call
     */
    function lPerMintAndStake(uint256 vaultId) external returns (uint80 rewards) {
        // Get unclaimed rewards
        rewards = lPerMint(vaultId);

        // Stake them immediately
        stake(rewards);
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function allowMinting(bool mintingOfSIRHalted_) external onlySystemControl {
        _mintingAllowed = mintingOfSIRHalted_;
    }
}
