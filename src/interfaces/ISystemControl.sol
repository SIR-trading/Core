// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

interface ISystemControl {
    type SystemStatus is uint8;

    error ArraysLengthMismatch();
    error FeeCannotBeZero();
    error NewTaxesTooHigh();
    error ShutdownTooEarly();
    error WrongVaultsOrOrder();
    error WrongStatus();

    event FundsWithdrawn(address indexed to, address indexed token, uint256 amount);
    event NewBaseFee(uint16 baseFee);
    event NewLPFee(uint16 lpFee);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SystemStatusChanged(SystemStatus indexed oldStatus, SystemStatus indexed newStatus);
    event TreasuryFeesWithdrawn(uint48 indexed vaultId, address indexed collateralToken, uint256 amount);

    function SHUTDOWN_WITHDRAWAL_DELAY() external view returns (uint40);

    function exitBeta() external;

    function hashActiveVaults() external view returns (bytes32);

    function haultMinting() external;

    function initialize(address vault_) external;

    function owner() external view returns (address);

    function renounceOwnership() external;

    function resumeMinting() external;

    function saveFunds(address[] calldata tokens, address to) external;

    function setBaseFee(uint16 baseFee_) external;

    function setLPFee(uint16 lpFee_) external;

    function shutdownSystem() external;

    function systemStatus() external view returns (SystemStatus);

    function transferOwnership(address newOwner) external;

    function tsStatusChanged() external view returns (uint40);

    function updateVaultsIssuances(
        uint48[] calldata oldVaults,
        uint48[] calldata newVaults,
        uint8[] calldata newTaxes
    ) external;

    function vault() external view returns (address);
}
