// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {Vault} from "./Vault.sol";
import {SystemConstants} from "./libraries/SystemConstants.sol";
import {Contributors} from "./libraries/Contributors.sol";
import {Staker} from "./Staker.sol";

// Contracts
contract SIR is Staker {
    event RewardsClaimed(address indexed contributor, uint256 indexed vaultId, uint80 rewards);

    mapping(address => uint40) internal timestampLastMint;

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

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

    function contributorMint() external returns (uint80 rewards) {
        // Get contributor's unclaimed rewards
        rewards = contributorUnclaimedSIR(msg.sender);

        // Mint if there are any unclaimed rewards
        require(rewards > 0);
        _mint(msg.sender, rewards);

        // Update time stamp
        timestampLastMint[msg.sender] = uint40(block.timestamp);
    }

    function lPerMint(uint256 vaultId) external returns (uint80 rewards) {
        // Get LPer issuance parameters
        rewards = vault.claimSIR(vaultId, msg.sender);

        // Mint if there are any unclaimed rewards
        require(rewards > 0);
        _mint(msg.sender, rewards);

        emit RewardsClaimed(msg.sender, vaultId, rewards);
    }
}
