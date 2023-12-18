// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {Vault} from "./Vault.sol";
import {SIR} from "./SIR.sol";

// Libraries
import {VaultStructs} from "./libraries/VaultStructs.sol";

// Smart contracts
import {Ownable} from "openzeppelin/access/Ownable.sol";

contract SystemControl is Ownable {
    event SIRIssuanceStarted(uint40 tsIssuanceStart);
    event EmergencyStop(bool indexed);
    event NewBaseFee(uint16 baseFee);
    event NewLPFee(uint8 lpFee);
    event BetaIsOver();

    error SIRIssuanceIsOn();
    error FeeCannotBeZero();
    error Minting(bool on);
    error BetaPeriodIsOver();
    error ArraysLengthMismatch();
    error ContributorsExceedsMaxIssuance();
    error WrongOrderOfVaults();
    error NewTaxesTooHigh();

    Vault public immutable VAULT;
    SIR public immutable SIR_TOKEN;

    uint256 private _sumTaxesToTreasury;

    bool public betaPeriod = true;

    /** This is the hash of the active vaults. It is used to make sure active vaults's issuances are nulled
        before new issuance parameters are stored. This is more gas efficient that storing all active vaults
        in an array, but it requires that system control keeps track of the active vaults.
        If the vaults were in an unknown order, it maybe be problem because the hash would change.
        So by default the vaults must be ordered in increasing order.

        The default value is the hash of an empty array.
     */
    bytes32 private _hashActiveVaults = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    modifier betaIsOn() {
        if (!betaPeriod) revert BetaPeriodIsOver();
        _;
    }

    constructor(address systemState, address sir) {
        VAULT = Vault(systemState);
        SIR_TOKEN = SIR(sir);
    }

    /*///////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /** @notice As soon as the protocol is redeemed safe and stable,
        @notice ownership will be revoked and SIR will be completely immutable
     */

    function exitBeta() external onlyOwner betaIsOn {
        (, , , bool emergencyStop, ) = VAULT.systemParams();
        if (emergencyStop) revert Minting(false); // Make sure minting is on

        betaPeriod = false;

        emit BetaIsOver();
    }

    /// @notice Issuance may start after the beta period is over
    function startIssuanceOfSIR(uint40 tsIssuanceStart_) external onlyOwner {
        (uint40 tsIssuanceStart, uint16 baseFee, uint8 lpFee, bool emergencyStop, uint16 cumTax) = VAULT.systemParams();

        if (tsIssuanceStart != 0) revert SIRIssuanceIsOn();

        VAULT.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart_, baseFee, lpFee, emergencyStop, cumTax));

        emit SIRIssuanceStarted(tsIssuanceStart_);
    }

    function setBaseFee(uint16 baseFee_) external onlyOwner betaIsOn {
        if (baseFee_ == 0) revert FeeCannotBeZero();

        (uint40 tsIssuanceStart, uint16 baseFee, uint8 lpFee, bool emergencyStop, uint16 cumTax) = VAULT.systemParams();

        VAULT.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, baseFee_, lpFee, emergencyStop, cumTax));

        emit NewBaseFee(baseFee);
    }

    function setLPFee(uint8 lpFee_) external onlyOwner betaIsOn {
        if (lpFee_ == 0) revert FeeCannotBeZero();

        (uint40 tsIssuanceStart, uint16 baseFee, uint8 lpFee, bool emergencyStop, uint16 cumTax) = VAULT.systemParams();

        VAULT.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, baseFee, lpFee_, emergencyStop, cumTax));

        emit NewLPFee(lpFee);
    }

    function haultMinting() external onlyOwner betaIsOn {
        (uint40 tsIssuanceStart, uint16 baseFee, uint8 lpFee, bool emergencyStop, uint16 cumTax) = VAULT.systemParams();

        if (emergencyStop) revert Minting(false);

        VAULT.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, baseFee, lpFee, true, cumTax));

        emit EmergencyStop(true);
    }

    /// @notice We should be allowed to resume the operations of the protocol even if the best is over.
    function resumeMinting() external onlyOwner {
        (uint40 tsIssuanceStart, uint16 baseFee, uint8 lpFee, bool emergencyStop, uint16 cumTax) = VAULT.systemParams();

        if (!emergencyStop) revert Minting(true);

        VAULT.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, baseFee, lpFee, false, cumTax));

        emit EmergencyStop(false);
    }

    function updateVaultsIssuances(
        uint40[] calldata oldVaults,
        uint40[] calldata newVaults,
        uint8[] calldata newTaxes
    ) public onlyOwner {
        uint256 lenNewVaults = newVaults.length;
        if (newTaxes.length != lenNewVaults) revert ArraysLengthMismatch();

        // Check the array of old vaults is correct
        if (_hashActiveVaults != keccak256(abi.encodePacked(oldVaults))) revert WrongOrderOfVaults();

        // Aggregate taxes and squared taxes
        uint16 cumTax;
        uint256 cumSquaredTaxes;
        for (uint256 i = 0; i < lenNewVaults; ++i) {
            cumTax += newTaxes[i];
            cumSquaredTaxes += uint256(newTaxes[i]) ** 2;
            if (i > 0 && newVaults[i] <= newVaults[i - 1]) revert WrongOrderOfVaults();
        }

        // Condition on squares
        if (cumSquaredTaxes > uint256(type(uint8).max) ** 2) revert NewTaxesTooHigh();

        // Update parameters
        VAULT.updateVaults(oldVaults, newVaults, newTaxes, cumTax);

        // Update hash of active vaults
        _hashActiveVaults == keccak256(abi.encodePacked(newVaults));
    }

    function updateContributorsIssuances(
        address[] calldata contributors,
        uint72[] calldata contributorIssuances
    ) external onlyOwner betaIsOn {
        uint256 lenContributors = contributors.length;
        if (contributorIssuances.length != lenContributors) revert ArraysLengthMismatch();

        // Update parameters
        if (SIR_TOKEN.changeContributorsIssuances(contributors, contributorIssuances))
            revert ContributorsExceedsMaxIssuance();
    }

    function widhtdrawTreasuryFeesAndSIR(uint40 vaultId, address to) external onlyOwner {
        VAULT.widhtdrawTreasuryFeesAndSIR(vaultId, to);
    }
}
