// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {SystemState} from "./SystemState.sol";
import {SIR} from "./SIR.sol";

// Smart contracts
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";

contract SystemControl is ERC1155TokenReceiver, Ownable {
    event IssuanceStart(uint40 tsIssuanceStart);
    event EmergencyStop(bool indexed);
    event NewBaseFee(uint16 baseFee);
    event NewLPFee(uint8 lpFee);
    event BetaIsOver();

    error CannotCallWhenBetaIsOver();
    error ArraysLengthMismatch();
    error ContributorsIssuanceExceedsMaxIssuance();
    error WrongOldVaultsOrder();
    error WrongNewVaultsOrder();
    error NewTaxesTooHigh();

    SystemState public immutable SYSTEM_STATE;
    SIR public immutable SIR_TOKEN;

    uint256 private _sumTaxesToDAO;

    bool public betaPeriod = true;

    /** This is the hash of the active vaults. It is used to make sure active vaults's issuances are nulled
        before new issuance parameters are stored. This is more gas efficient that storing all active vaults
        in an arry, but it requires that system control keeps track of the active vaults.
        If the vaults were in an unknown order, it maybe be problem because the hash would change.
        So by default the vaults must be ordered in increasing order.

        The default value is the hash of an empty array.
     */
    bytes32 private _hashActiveVaults = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    modifier betaIsOn() {
        if (!betaPeriod) revert CannotCallWhenBetaIsOver();
        _;
    }

    constructor(address systemState, address sir) {
        SYSTEM_STATE = SystemState(systemState);
        SIR_TOKEN = SIR(sir);
    }

    /*///////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /** @notice As soon as the protocol is redeemed safe and stable,
        @notice ownership will be revoked and SIR will be completely immutable
     */

    function exitBeta() external onlyOwner betaIsOn {
        betaPeriod = false;
        emit BetaIsOver();
    }

    /// @notice Issuance may start after the beta period is over
    function startIssuanceOfSIR(uint40 tsStart) external onlyOwner {
        SYSTEM_STATE.updateSystemState(tsStart, 0, 0, false, false, new uint40[](0), new uint40[](0), new uint16[](0));
        emit IssuanceStart(tsStart);
    }

    function setBaseFee(uint16 baseFee) external onlyOwner betaIsOn {
        SYSTEM_STATE.updateSystemState(0, baseFee, 0, false, false, new uint40[](0), new uint40[](0), new uint16[](0));
        emit NewBaseFee(baseFee);
    }

    function setLPFee(uint8 lpFee) external onlyOwner betaIsOn {
        SYSTEM_STATE.updateSystemState(0, 0, lpFee, false, false, new uint40[](0), new uint40[](0), new uint16[](0));
        emit NewLPFee(lpFee);
    }

    function haultMinting() external onlyOwner betaIsOn {
        SYSTEM_STATE.updateSystemState(0, 0, 0, true, false, new uint40[](0), new uint40[](0), new uint16[](0));
        emit EmergencyStop(true);
    }

    /// @notice We should be allowed to resume the operations of the protocol even if the best is over.
    function resumeMinting() external onlyOwner {
        SYSTEM_STATE.updateSystemState(0, 0, 0, false, true, new uint40[](0), new uint40[](0), new uint16[](0));
        emit EmergencyStop(false);
    }

    function updateVaultsIssuances(
        uint40[] calldata oldVaults,
        uint40[] calldata newVaults,
        uint16[] calldata newTaxes
    ) public onlyOwner {
        uint256 lenNewVaults = newVaults.length;
        if (newTaxes.length != lenNewVaults) revert ArraysLengthMismatch();

        // Check the array of old vaults is correct
        if (_hashActiveVaults != keccak256(abi.encodePacked(oldVaults))) revert WrongOldVaultsOrder();

        // Aggregate taxes and squared taxes
        uint256 aggSquaredTaxesToDAO;
        for (uint256 i = 0; i < lenNewVaults; ++i) {
            aggSquaredTaxesToDAO += uint256(newTaxes[i]) ** 2;
            if (i > 0 && newVaults[i] <= newVaults[i - 1]) revert WrongNewVaultsOrder();
        }

        // Condition on squares
        if (aggSquaredTaxesToDAO > uint256(type(uint16).max) ** 2) revert NewTaxesTooHigh();

        // Update parameters
        SYSTEM_STATE.updateSystemState(0, 0, 0, false, false, oldVaults, newVaults, newTaxes);

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
            revert ContributorsIssuanceExceedsMaxIssuance();
    }

    // function withdrawDAOFees(address vault) external onlyOwner returns (bool) {
    //     daoFees = state.daoFees;
    //     state.daoFees = 0; // No re-entrancy attack
    //     TransferHelper.safeTransfer(COLLATERAL_TOKEN, msg.sender, daoFees);
    // }
}
