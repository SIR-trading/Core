// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {SystemConstants} from "./libraries/SystemConstants.sol";
import {Contributors} from "./Contributors.sol";
import {Staker} from "./Staker.sol";
import {SystemControlAccess} from "./SystemControlAccess.sol";

/**
 * @notice The SIR ERC-20 token is managed between this contractand the Staker contract.
 * In particular this contract handles the external functions for minting SIR by contributors,
 * who have a fixed allocation for the first 3 years, and LPers.
 */
contract SIR is Staker, SystemControlAccess {
    event RewardsClaimed(address indexed contributor, uint256 indexed vaultId, uint80 rewards);

    Contributors private immutable _CONTRIBUTORS;

    mapping(address => uint40) internal timestampLastMint;

    bool private _mintingAllowed = true;

    constructor(
        address contributors,
        address weth,
        address systemControl
    ) Staker(weth) SystemControlAccess(systemControl) {
        _CONTRIBUTORS = Contributors(contributors);
    }

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns unclaimed SIR rewards of a contributor.
     * @param contributor Address of the contributor to check.
     * @return unclaimed Amount of unclaimed SIR rewards.
     */
    function contributorUnclaimedSIR(address contributor) public view returns (uint80) {
        unchecked {
            // Get the contributor's allocation
            uint256 allocation = _CONTRIBUTORS.getAllocation(contributor);

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

    /**
     * @notice Returns the amount of SIR issued every second [SIR/s].
     */
    function ISSUANCE_RATE() external pure returns (uint72) {
        return SystemConstants.ISSUANCE;
    }

    /**
     * @notice Returns the amount of SIR issued every second [SIR/s] only to LPers for the first 3 years.
     */
    function LP_ISSUANCE_FIRST_3_YEARS() external pure returns (uint72) {
        return SystemConstants.LP_ISSUANCE_FIRST_3_YEARS;
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Contributor can mint SIR rewards.
     * @dev Contributors are those that contributed pre mainnet and got an allocation for it.
     * @return rewards Amount of SIR received by the contributor.
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

    /**
     * @notice Mint SIR rewards for an LPer.
     * @param vaultId The vault ID of the vault to claim SIR from.
     * @return rewards Amount of SIR rewards received.
     */
    function lperMint(uint256 vaultId) public returns (uint80 rewards) {
        require(_mintingAllowed);

        // Get LPer issuance parameters
        rewards = vault.claimSIR(vaultId, msg.sender);

        // Mint if there are any unclaimed rewards
        require(rewards > 0);
        _mint(msg.sender, rewards);

        emit RewardsClaimed(msg.sender, vaultId, rewards);
    }

    /**
     * @notice Contributor can mint SIR rewards and stake them in one call.
     * @dev Auxiliary function that saves the user from calling contributorMint() and stake() separately.
     */
    function contributorMintAndStake() external returns (uint80 rewards) {
        // Get unclaimed rewards
        rewards = contributorMint();

        // Stake them immediately
        stake(rewards);
    }

    /**
     * @notice LPer can mint SIR rewards and stake them in one call.
     * @dev Auxiliary function that saves the LPer from calling lperMint() and stake() separately.
     */
    function lperMintAndStake(uint256 vaultId) external returns (uint80 rewards) {
        // Get unclaimed rewards
        rewards = lperMint(vaultId);

        // Stake them immediately
        stake(rewards);
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @dev This function can only be called by the SystemControl contract.
     */
    function allowMinting(bool mintingOfSIRHalted_) external onlySystemControl {
        _mintingAllowed = mintingOfSIRHalted_;
    }
}
