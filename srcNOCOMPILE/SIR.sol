// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {SystemCommons} from "./SystemCommons.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

// Contracts
contract SIR is ERC20, SystemCommons {
    struct ContributorIssuanceParams {
        uint72 issuance; // [SIR/s]
        uint40 tsLastUpdate; // timestamp of the last mint. 0 => use systemParams.tsIssuanceStart instead
        uint104 rewards; // SIR owed to the contributor
    }

    address private immutable _SYSTEM_STATE;

    mapping(address => ContributorIssuanceParams) internal _contributorsIssuances;

    constructor(address systemState, address systemControl) SystemCommons(systemControl) {
        _SYSTEM_STATE = systemState;
    }

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function maxTotalSupply() external view returns (uint256) {
        if (systemParams.tsIssuanceStart == 0) return 0;

        return ISSUANCE * (block.timestamp - systemParams.tsIssuanceStart);
    }

    function getContributorIssuance(
        address contributor
    ) public view returns (ContributorIssuanceParams memory contributorParams) {
        // If issuance has not started yet
        if (systemParams.tsIssuanceStart == 0) return contributorParams;

        contributorParams = _contributorsIssuances[contributor];

        // Last date of rewards
        uint40 tsIssuanceEnd = systemParams.tsIssuanceStart + _THREE_YEARS;

        // If issuance is over and rewards have already been updated
        if (contributorParams.tsLastUpdate >= tsIssuanceEnd) return contributorParams;

        // If issuance is over but rewards have not been updated
        bool issuanceIsOver = uint40(block.timestamp) >= tsIssuanceEnd;

        // If rewards have never been updated
        bool rewardsNeverUpdated = systemParams.tsIssuanceStart > contributorParams.tsLastUpdate;

        // Update contributorParams
        contributorParams.rewards +=
            uint104(contributorParams.issuance) *
            uint104(
                (issuanceIsOver ? tsIssuanceEnd : uint40(block.timestamp)) -
                    (rewardsNeverUpdated ? systemParams.tsIssuanceStart : contributorParams.tsLastUpdate)
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

        // Mint if any rewards
        require(contributorParams.rewards > 0);
        _mint(msg.sender, contributorParams.rewards);

        // Update state
        contributorParams.rewards = 0;
        _contributorsIssuances[msg.sender] = contributorParams;
    }

    /**
        TO CHANGE: PERIPHERY IN CHARGE OF UPDATING VAULT ISSUANCE STATE
        SO WE CAN PASS FIRST REQUIRE
        Don't query vault here but just check its issuance has been updated.
        Assume issuances have been updated just before. The periphery would take care of this.
     */
    function LPerMint(uint256 vaultId) external {
        // Check issuance data is up to date
        require(_vaultIssuanceStates[vaultId].vaultIssuance.tsLastUpdate == uint40(block.timestamp));

        // Get LPer issuance parameters
        LPerIssuanceParams memory lperIssuance = _vaultIssuanceStates[vaultId].lpersIssuances[msg.sender];

        // Mint if any rewards
        require(lperIssuance.rewards > 0);
        _mint(msg.sender, lperIssuance.rewards);

        // Update state
        lperIssuance.rewards = 0;
        _vaultIssuanceStates[vaultId].lpersIssuances[msg.sender] = lperIssuance;
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
}
