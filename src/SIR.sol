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
        (uint40 tsIssuanceStart, , , ) = _SYSTEM_STATE.systemParams();

        if (tsIssuanceStart == 0) return 0;
        return ISSUANCE * (block.timestamp - tsIssuanceStart);
    }

    function getContributorIssuance(
        address contributor
    ) public view returns (ContributorIssuanceParams memory contributorParams) {
        (uint40 tsIssuanceStart, , , ) = _SYSTEM_STATE.systemParams();

        // If issuance has not started yet
        if (tsIssuanceStart == 0) return contributorParams;

        // Copy the parameters to memory
        contributorParams = _contributorsIssuances[contributor];

        // Last date of unclaimedRewards
        uint40 tsIssuanceEnd = tsIssuanceStart + _THREE_YEARS;

        // If issuance is over and unclaimedRewards have already been updated
        if (contributorParams.tsLastUpdate >= tsIssuanceEnd) return contributorParams;

        // If issuance is over but unclaimedRewards have not been updated
        bool issuanceIsOver = uint40(block.timestamp) >= tsIssuanceEnd;

        // If unclaimedRewards have never been updated
        bool unclaimedRewardsNeverUpdated = tsIssuanceStart > contributorParams.tsLastUpdate;

        // Update contributorParams
        contributorParams.unclaimedRewards +=
            uint104(contributorParams.issuance) *
            uint104(
                (issuanceIsOver ? tsIssuanceEnd : uint40(block.timestamp)) -
                    (unclaimedRewardsNeverUpdated ? tsIssuanceStart : contributorParams.tsLastUpdate)
            );
        if (issuanceIsOver) contributorParams.issuance = 0;
        contributorParams.tsLastUpdate = uint40(block.timestamp);
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

    /**
        TO CHANGE: PERIPHERY IN CHARGE OF UPDATING VAULT ISSUANCE STATE
        SO WE CAN PASS FIRST REQUIRE
        Don't query vault here but just check its issuance has been updated.
        Assume issuances have been updated just before. The periphery would take care of this.
     */
    function LPerMint(uint256 vaultId) external {
        // Get LPer issuance parameters
        uint104 unclaimedRewards = _SYSTEM_STATE._updateLPerIssuanceParams(vaultId, msg.sender);

        // Mint if any unclaimedRewards
        require(unclaimedRewards > 0);
        _mint(msg.sender, unclaimedRewards);
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
