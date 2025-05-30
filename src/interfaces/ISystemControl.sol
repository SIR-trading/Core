// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface ISystemControl {
    error ArraysLengthMismatch();
    error FeeCannotBeZero();
    error NewTaxesTooHigh();
    error OwnableInvalidOwner(address owner);
    error OwnableUnauthorizedAccount(address account);
    error ShutdownTooEarly();
    error WrongStatus();
    error WrongVaultsOrOrder();

    event FundsWithdrawn(address indexed to, address indexed token, uint256 amount);
    event NewBaseFee(uint16 baseFee);
    event NewLPFee(uint16 lpFee);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SystemStatusChanged(uint8 indexed oldStatus, uint8 indexed newStatus);
    event TreasuryFeesWithdrawn(uint48 indexed vaultId, address indexed collateralToken, uint256 amount);

    function acceptOwnership() external;
    function exitBeta() external;
    function hashActiveVaults() external view returns (bytes32);
    function haultMinting() external;
    function initialize(address vault_, address payable sir_) external;
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function renounceOwnership() external;
    function resumeMinting() external;
    function saveFunds(address[] memory tokens, address to) external;
    function setBaseFee(uint16 baseFee_) external;
    function setLPFee(uint16 lpFee_) external;
    function shutdownSystem() external;
    function sir() external view returns (address);
    function systemStatus() external view returns (uint8);
    function timestampStatusChanged() external view returns (uint40);
    function transferOwnership(address newOwner) external;
    function updateVaultsIssuances(
        uint48[] memory oldVaults,
        uint48[] memory newVaults,
        uint8[] memory newTaxes
    ) external;
    function vault() external view returns (address);
}
