// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {Vault} from "./Vault.sol";

// Libraries
import {SirStructs} from "./libraries/SirStructs.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";

// Smart contracts
import {Ownable} from "openzeppelin/access/Ownable.sol";

contract SystemControl is Ownable {
    /** Flow chart of the system 4 possible states:
        +---------------+      +---------------+       +---------------+      +---------------+
        |  Unstoppable  | <--- | TrainingWheels| <---> |   Emergency   | ---> |    Shutdown   |
        +---------------+      +---------------+       +---------------+      +---------------+
     */
    enum SystemStatus {
        Unstoppable, // System is running normally, trustless and permissionless. SIR issuance is started.
        TrainingWheels, // Betta period before Unstoppable status, deposits can be frozen by switching to Emergency status
        Emergency, // Deposits are frozen, and system can be Shutdown if it does not revert to TrainingWheels before SHUTDOWN_WITHDRAWAL_DELAY seconds
        Shutdown // No deposits, SystemControl can withdraw all funds. Once here it cannot change status.
    }

    event SystemStatusChanged(SystemStatus indexed oldStatus, SystemStatus indexed newStatus);
    event NewBaseFee(uint16 baseFee);
    event NewLPFee(uint16 lpFee);
    event TreasuryFeesWithdrawn(uint48 indexed vaultId, address indexed collateralToken, uint256 amount);
    event FundsWithdrawn(address indexed to, address indexed token, uint256 amount);

    error FeeCannotBeZero();
    error WrongStatus();
    error ShutdownTooEarly();
    error ArraysLengthMismatch();
    error WrongVaultsOrOrder();
    error NewTaxesTooHigh();

    Vault public vault;
    bool private _initialized = false;

    SystemStatus public systemStatus = SystemStatus.TrainingWheels;
    uint40 public timestampStatusChanged; // Timestamp when the status last changed

    /** This is the hash of the active vaults. It is used to make sure active vaults's issuances are nulled
        before new issuance parameters are stored. This is more gas efficient that storing all active vaults
        in an array, but it requires that system control keeps track of the active vaults.
        If the vaults were in an unknown order, it maybe be problem because the hash would change.
        So by default the vaults must be ordered in increasing order.

        The starting value is the hash of an empty array.
     */
    bytes32 public hashActiveVaults = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    constructor() Ownable(msg.sender) {}

    function initialize(address vault_) external {
        require(!_initialized && msg.sender == owner());

        vault = Vault(vault_);

        _initialized = true;
    }

    /*///////////////////////////////////////////////////////////////
                        STATE TRANSITIONING FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /** @notice THIS ACTION IS IRREVERSIBLE
        @notice As soon as the protocol is redeemed safe and stable, ownership will be revoked and SIR will be completely immutable
     */
    function exitBeta() external onlyOwner {
        if (systemStatus != SystemStatus.TrainingWheels) revert WrongStatus();

        // Change status
        systemStatus = SystemStatus.Unstoppable;
        timestampStatusChanged = uint40(block.timestamp);

        emit SystemStatusChanged(SystemStatus.TrainingWheels, SystemStatus.Unstoppable);
    }

    function haultMinting() external onlyOwner {
        if (systemStatus != SystemStatus.TrainingWheels) revert WrongStatus();

        // Change status
        systemStatus = SystemStatus.Emergency;
        timestampStatusChanged = uint40(block.timestamp);

        // Hault minting
        vault.updateSystemState(0, 0, true);

        emit SystemStatusChanged(SystemStatus.TrainingWheels, SystemStatus.Emergency);
    }

    function resumeMinting() external onlyOwner {
        if (systemStatus != SystemStatus.Emergency) revert WrongStatus();

        // Change status
        systemStatus = SystemStatus.TrainingWheels;
        timestampStatusChanged = uint40(block.timestamp);

        // Restore fees
        vault.updateSystemState(0, 0, false);

        emit SystemStatusChanged(SystemStatus.Emergency, SystemStatus.TrainingWheels);
    }

    /** @notice THIS ACTION IS IRREVERSIBLE
        @notice Shutdown the system and allow the owner to withdraw all funds
        @notice This function can only be called after SHUTDOWN_WITHDRAWAL_DELAY seconds have passed since the system entered Emergency status.
     */
    function shutdownSystem() external onlyOwner {
        if (systemStatus != SystemStatus.Emergency) revert WrongStatus();

        // Only allow the shutdown of the system after enough time has been given to LPers and apes to withdraw their funds
        if (block.timestamp - timestampStatusChanged < SystemConstants.SHUTDOWN_WITHDRAWAL_DELAY)
            revert ShutdownTooEarly();

        // Change status
        systemStatus = SystemStatus.Shutdown;
        timestampStatusChanged = uint40(block.timestamp);

        emit SystemStatusChanged(SystemStatus.Emergency, SystemStatus.Shutdown);
    }

    /*///////////////////////////////////////////////////////////////
                    PARAMETER CONFIGURATION FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /** @notice Fees can only be set when the system is in TrainingWheels status
     */
    function setBaseFee(uint16 baseFee_) external onlyOwner {
        if (systemStatus != SystemStatus.TrainingWheels) revert WrongStatus();
        if (baseFee_ == 0) revert FeeCannotBeZero();

        vault.updateSystemState(baseFee_, 0, false);

        emit NewBaseFee(baseFee_);
    }

    function setLPFee(uint16 lpFee_) external onlyOwner {
        if (systemStatus != SystemStatus.TrainingWheels) revert WrongStatus();
        if (lpFee_ == 0) revert FeeCannotBeZero();

        vault.updateSystemState(0, lpFee_, false);

        emit NewLPFee(lpFee_);
    }

    /** @notice It will not fail even if the newVaults do not exist.
        @notice The implicit limit on the # of newVaults is 65025,
        @notice which comes from the act that the sum of squared taxes must be smaller than (2^8-1)^2.
     */
    function updateVaultsIssuances(
        uint48[] calldata oldVaults,
        uint48[] calldata newVaults,
        uint8[] calldata newTaxes
    ) public onlyOwner {
        uint256 lenNewVaults = newVaults.length;
        if (newTaxes.length != lenNewVaults) revert ArraysLengthMismatch();

        // Check the array of old vaults is correct
        if (hashActiveVaults != keccak256(abi.encodePacked(oldVaults))) revert WrongVaultsOrOrder();

        // Aggregate taxes and squared taxes
        uint16 cumulativeTax;
        uint256 cumulativeSquaredTaxes;
        for (uint256 i = 0; i < lenNewVaults; ++i) {
            if (newTaxes[i] == 0) revert FeeCannotBeZero();
            cumulativeTax += newTaxes[i];
            cumulativeSquaredTaxes += uint256(newTaxes[i]) ** 2;
            if (i > 0 && newVaults[i] <= newVaults[i - 1]) revert WrongVaultsOrOrder();
        }

        // Condition on squares
        if (cumulativeSquaredTaxes > uint256(type(uint8).max) ** 2) revert NewTaxesTooHigh();

        // Update parameters
        vault.updateVaults(oldVaults, newVaults, newTaxes, cumulativeTax);

        // Update hash of active vaults
        hashActiveVaults = keccak256(abi.encodePacked(newVaults));
    }

    /*///////////////////////////////////////////////////////////////
                        WITHDRAWAL FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Save the remaining funds that have not been withdrawn from the vaults
    function saveFunds(address[] calldata tokens, address to) external onlyOwner {
        require(to != address(0));

        if (systemStatus != SystemStatus.Shutdown) revert WrongStatus();

        uint256[] memory amounts = vault.withdrawToSaveSystem(tokens, to);

        for (uint256 i = 0; i < tokens.length; ++i) {
            emit FundsWithdrawn(to, tokens[i], amounts[i]);
        }
    }
}
