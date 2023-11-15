// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {SystemState} from "./SystemState.sol";
import {SystemCommons} from "./SystemCommons.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

// Contracts
contract SIR is ERC20, SystemCommons {
    struct ContributorIssuanceParams {
        uint72 issuance; // [SIR/s]
        uint40 tsLastUpdate; // timestamp of the last mint. 0 => use systemParams.tsIssuanceStart instead
        uint104 unclaimedRewards; // SIR owed to the contributor
    }

    SystemState private immutable _SYSTEM_STATE;

    uint72 public aggIssuanceContributors; // aggIssuanceContributors <= ISSUANCE - AGG_ISSUANCE_VAULTS

    address[] public contributors;
    mapping(address => ContributorIssuanceParams) internal _contributorsIssuances;

    constructor(
        address systemState,
        address systemControl
    ) ERC20("Synthetics Implemented Right", "SIR", 18) SystemCommons(systemControl) {
        _SYSTEM_STATE = SystemState(systemState);
    }

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Not all tokens may be in circulation. This function outputs the total supply if ALL tokens where in circulation.
    function maxTotalSupply() external view returns (uint256) {
        (uint40 tsIssuanceStart, , , , ) = _SYSTEM_STATE.systemParams();

        if (tsIssuanceStart == 0) return 0;
        return ISSUANCE * (block.timestamp - tsIssuanceStart);
    }

    function getContributorIssuance(
        address contributor
    ) public view returns (ContributorIssuanceParams memory contributorParams) {
        unchecked {
            (uint40 tsIssuanceStart, , , , ) = _SYSTEM_STATE.systemParams();

            // Update timestamp
            contributorParams.tsLastUpdate = uint40(block.timestamp);

            // If issuance has not started yet
            if (tsIssuanceStart == 0) return contributorParams;

            // Copy the parameters to memory
            contributorParams = _contributorsIssuances[contributor];

            // Last date of unclaimedRewards
            uint40 tsIssuanceEnd = tsIssuanceStart + THREE_YEARS;

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

    function contributorMint() external {
        // Get contributor issuance parameters
        ContributorIssuanceParams memory contributorParams = getContributorIssuance(msg.sender);

        // Mint if any unclaimedRewards
        require(contributorParams.unclaimedRewards > 0);
        _mint(msg.sender, contributorParams.unclaimedRewards);

        // Reset unclaimedRewards
        contributorParams.unclaimedRewards = 0;

        // Update state
        _contributorsIssuances[msg.sender] = contributorParams;
    }

    function lPerMint(uint256 vaultId) external {
        // Get LPer issuance parameters
        uint104 unclaimedRewards = _SYSTEM_STATE.unclaimedRewards(vaultId, msg.sender);

        // Mint if any unclaimedRewards
        require(unclaimedRewards > 0);
        _mint(msg.sender, unclaimedRewards);
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function changeContributorsIssuances(
        address[] calldata contributors_,
        uint72[] calldata contributorIssuances_
    ) external onlySystemControl returns (bool) {
        uint256 aggIssuanceToAdd;
        uint256 aggIssuanceToRemove;
        uint256 lenContributors = contributors_.length;
        for (uint256 i = 0; i < lenContributors; i++) {
            // Get contributor issuance parameters
            ContributorIssuanceParams memory contributorParams = getContributorIssuance(contributors_[i]);

            // Updated aggregated issuance
            unchecked {
                aggIssuanceToAdd += contributorIssuances_[i]; // Cannot overflow unless we have at least 2^(256-72) contributors...
                aggIssuanceToRemove += contributorParams.issuance;
            }

            // Update issuance
            contributorParams.issuance = contributorIssuances_[i];

            // Update state
            _contributorsIssuances[contributors_[i]] = contributorParams;
        }
        uint256 aggIssuanceContributors_ = aggIssuanceContributors + aggIssuanceToAdd - aggIssuanceToRemove;

        aggIssuanceContributors = uint72(aggIssuanceContributors_);
        if (aggIssuanceContributors_ > ISSUANCE - AGG_ISSUANCE_VAULTS) return false;
        return true;
    }

    // function changeContributorsIssuances(
    //     address[] calldata prevContributors,
    //     address[] calldata nextContributors,
    //     uint72[] calldata issuances,
    //     bool allowAnyTotalIssuance
    // ) external onlySystemControl returns (bytes32) {
    //     // Stop issuance of previous contributors
    //     for (uint256 i = 0; i < prevContributors.length; i++) {
    //         ContributorIssuanceParams memory contributorParams = getContributorIssuance(prevContributors[i]);
    //         contributorParams.issuance = 0;
    //         _contributorsIssuances[prevContributors[i]] = contributorParams;
    //     }

    //     // Set next issuances
    //     uint72 issuanceAllContributors = 0;
    //     for (uint256 i = 0; i < nextContributors.length; i++) {
    //         _contributorsIssuances[nextContributors[i]].issuance = issuances[i];
    //         _contributorsIssuances[nextContributors[i]].tsLastUpdate = uint40(block.timestamp);

    //         issuanceAllContributors += issuances[i]; // Check total issuance does not change
    //     }

    //     if (allowAnyTotalIssuance) {
    //         // Recalibrate vaults' issuances
    //         systemParams.issuanceTotalVaults = ISSUANCE - issuanceAllContributors;
    //     } else {
    //         require(
    //             ISSUANCE == issuanceAllContributors + systemParams.issuanceTotalVaults,
    //             "Total issuance must not change"
    //         );
    //     }

    //     return keccak256(abi.encodePacked(nextContributors));
    // }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/
}
