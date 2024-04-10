// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {Vault} from "./Vault.sol";
import {SystemConstants} from "./libraries/SystemConstants.sol";
import {ERC20Staker} from "./ERC20Staker.sol";

// Contracts
contract SIR is ERC20Staker {
    mapping(address => uint40) internal tsLastMint;

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
                uint256 allocation = _getContributorAllocation(contributor);

                // No allocation, no rewards
                if (allocation == 0) return 0;

                // Calculate the contributor's issuance
                issuance = (allocation * (SystemConstants.ISSUANCE - SystemConstants.ISSUANCE_FIRST_3_YEARS)) / 10000;

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

    /** @dev TO CHANGE BEFORE DEPLOYMENT.
        @dev These are just example addresses. The real addresses and their issuances need to be hardcoded before deployment.
        @dev Function returns an integer with max value of 10000.
        @dev The sum of all contributors' allocations must be less than or equal to 10000.
     */
    function _getContributorAllocation(address contributor) private pure returns (uint256) {
        if (contributor == 0x7EE4a8493Da53686dDF4FD2F359a7D00610CE370) return 100;
        else if (contributor == 0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5) return 1000;

        return 0;
    }
}
