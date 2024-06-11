// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {Vault} from "./Vault.sol";
import {SystemConstants} from "./libraries/SystemConstants.sol";
import {Contributors} from "./libraries/Contributors.sol";
import {Staker} from "./Staker.sol";

// Contracts
contract SIR is Staker {
    mapping(address => uint40) internal tsLastMint;

    constructor(address weth) Staker(weth) {}

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function contributorUnclaimedSIR(address contributor) public view returns (uint80) {
        unchecked {
            // First issuance date
            (uint40 tsIssuanceStart, , , , ) = vault.systemParams();

            // Last issuance date
            uint256 tsIssuanceEnd = tsIssuanceStart + SystemConstants.THREE_YEARS;

            // Get last mint time stamp
            uint256 tsLastMint_ = tsLastMint[contributor];

            // If issuance has not been stored
            uint256 issuance;
            if (tsLastMint_ == 0) {
                // Get the contributor's allocation
                uint256 allocation = Contributors.getAllocation(contributor);

                // No allocation, no rewards
                if (allocation == 0) return 0;

                // Calculate the contributor's issuance
                issuance =
                    (allocation * (SystemConstants.ISSUANCE - SystemConstants.LP_ISSUANCE_FIRST_3_YEARS)) /
                    type(uint56).max;

                // Update issuance time stamp
                tsLastMint_ = tsIssuanceStart;
            } else if (tsLastMint_ >= tsIssuanceEnd) {
                // Contributor has already claimed all rewards
                return 0;
            }

            // Update unclaimed rewards
            uint256 tsNow = block.timestamp >= tsIssuanceEnd ? tsIssuanceEnd : block.timestamp;

            // Return unclaimed rewards
            return uint80(issuance * (tsNow - tsLastMint_));
        }
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
        tsLastMint[msg.sender] = uint40(block.timestamp);
    }

    function lPerMint(uint256 vaultId) external returns (uint80 rewards) {
        // Get LPer issuance parameters
        rewards = vault.claimSIR(vaultId, msg.sender);

        // Mint if there are any unclaimed rewards
        require(rewards > 0);
        _mint(msg.sender, rewards);
    }

    /*//////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/
}
