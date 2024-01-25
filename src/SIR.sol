// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {SystemState} from "./SystemState.sol";
import {SystemControlAccess} from "./SystemControlAccess.sol";
import {SystemConstants} from "./libraries/SystemConstants.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

// Contracts
contract SIR is ERC20, SystemControlAccess {
    error ContributorsExceedsMaxIssuance();

    struct ContributorIssuanceParams {
        uint72 issuance; // [SIR/s]
        uint40 tsLastUpdate; // timestamp of the last mint. 0 => use systemParams.tsIssuanceStart instead
        uint104 unclaimedRewards; // SIR owed to the contributor
    }

    SystemState private immutable _VAULT;

    uint72 public issuanceContributors; // issuanceContributors <= ISSUANCE - ISSUANCE_FIRST_3_YEARS

    address[] public contributors;
    mapping(address => ContributorIssuanceParams) internal _contributorsIssuances;

    constructor(
        address systemState,
        address systemControl
    ) ERC20("Synthetics Implemented Right", "SIR", SystemConstants.SIR_DECIMALS) SystemControlAccess(systemControl) {
        _VAULT = SystemState(systemState);
    }

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Not all tokens may be in circulation. This function outputs the total supply if ALL tokens where in circulation.
    function maxTotalSupply() external view returns (uint256) {
        (uint40 tsIssuanceStart, , , , ) = _VAULT.systemParams();

        if (tsIssuanceStart == 0) return 0;
        return SystemConstants.ISSUANCE * (block.timestamp - tsIssuanceStart);
    }

    function getContributorIssuance(
        address contributor
    ) public view returns (ContributorIssuanceParams memory contributorParams) {
        unchecked {
            (uint40 tsIssuanceStart, , , , ) = _VAULT.systemParams();

            // Update timestamp
            contributorParams.tsLastUpdate = uint40(block.timestamp);

            // If issuance has not started yet
            if (tsIssuanceStart == 0) return contributorParams;

            // Copy the parameters to memory
            contributorParams = _contributorsIssuances[contributor];

            // Last date of unclaimedRewards
            uint40 tsIssuanceEnd = tsIssuanceStart + SystemConstants.THREE_YEARS;

            // If issuance is over and unclaimedRewards have already been updated
            if (contributorParams.tsLastUpdate >= tsIssuanceEnd) return contributorParams;

            // If issuance is over but unclaimedRewards have not been updated
            bool issuanceIsOver = uint40(block.timestamp) >= tsIssuanceEnd;

            // If unclaimedRewards have never been updated
            bool unclaimedRewardsNeverUpdated = tsIssuanceStart > contributorParams.tsLastUpdate;

            // Update contributorParams
            contributorParams.unclaimedRewards += uint104(
                uint256(
                    (issuanceIsOver ? tsIssuanceEnd : uint40(block.timestamp)) -
                        (unclaimedRewardsNeverUpdated ? tsIssuanceStart : contributorParams.tsLastUpdate)
                ) * contributorParams.issuance
            );
            if (issuanceIsOver) contributorParams.issuance = 0;
        }
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function contributorMint() external returns (uint104) {
        // Get contributor issuance parameters
        ContributorIssuanceParams memory contributorParams = getContributorIssuance(msg.sender);

        // Mint if there are any unclaimed rewards
        require(contributorParams.unclaimedRewards > 0);
        _mint(msg.sender, contributorParams.unclaimedRewards);

        // Reset unclaimedRewards
        contributorParams.unclaimedRewards = 0;

        // Update state
        _contributorsIssuances[msg.sender] = contributorParams;

        return contributorParams.unclaimedRewards;
    }

    function lPerMint(uint256 vaultId) external returns (uint104 rewards) {
        // Get LPer issuance parameters
        rewards = _VAULT.claimSIR(vaultId, msg.sender);

        // Mint if there are any unclaimed rewards
        require(rewards > 0);
        _mint(msg.sender, rewards);
    }

    /** @notice Mint the SIR earnt by the protocol owned liquidity
     */
    function treasuryMint(uint256 vaultId, address to) external returns (uint104 rewards) {
        require(msg.sender == address(_VAULT));

        // Get LPer issuance parameters
        rewards = _VAULT.claimSIR(vaultId, address(_VAULT));

        // Mint if there are any unclaimed rewards but do not revert
        if (rewards > 0) _mint(to, rewards);
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @notice Change the issuance of some contributors
        @dev This function is only callable by the SystemControl contract
        @param contributors_ The addresses of the contributors
        @param contributorIssuances_ The new issuance of each contributor
     */
    function changeContributorsIssuances(
        address[] calldata contributors_,
        uint72[] calldata contributorIssuances_
    ) external onlySystemControl {
        uint256 issuanceIncrease;
        uint256 issuanceDecrease;
        uint256 lenContributors = contributors_.length;
        for (uint256 i = 0; i < lenContributors; i++) {
            // Get contributor issuance parameters
            ContributorIssuanceParams memory contributorParams = getContributorIssuance(contributors_[i]);

            // Updated aggregated issuance
            unchecked {
                issuanceIncrease += contributorIssuances_[i]; // Cannot overflow unless we have at least 2^(256-72) contributors...
                issuanceDecrease += contributorParams.issuance;
            }

            // Update issuance
            contributorParams.issuance = contributorIssuances_[i];

            // Update state
            _contributorsIssuances[contributors_[i]] = contributorParams;
        }
        uint256 issuanceContributors_ = issuanceContributors + issuanceIncrease - issuanceDecrease;

        if (issuanceContributors_ > SystemConstants.ISSUANCE - SystemConstants.ISSUANCE_FIRST_3_YEARS)
            revert ContributorsExceedsMaxIssuance();

        issuanceContributors = uint72(issuanceContributors_);
    }
}
