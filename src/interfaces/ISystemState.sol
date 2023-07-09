// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Smart contracts
import "./ISIR.sol";
import "./IFees.sol";

interface ISystemState is IFees, ISIR {
    function SYSTEM_CONTROL() external returns (address);

    function onlyWithdrawals() external view returns (bool);

    function updateSystemParameters(uint40 tsIssuanceStart_, uint16 basisFee_, bool onlyWithdrawals_) external;

    function setVaultsIssuances() external;

    function setContributorsIssuances() external;

    function changeVaultsIssuances(
        address[] calldata prevVaults,
        bytes16[] memory latestSuppliesMAAM,
        address[] calldata nextVaults,
        uint16[] calldata taxesToDAO,
        uint256 sumTaxes
    ) external returns (bytes32);

    function recalibrateVaultsIssuances(address[] calldata vaults, bytes16[] memory latestSuppliesMAAM, uint256 sumTaxes)
        external;

    function changeContributorsIssuances(
        address[] calldata prevContributors,
        address[] calldata nextContributors,
        uint72[] calldata issuances,
        bool allowAnyTotalIssuance
    ) external returns (bytes32);
}
