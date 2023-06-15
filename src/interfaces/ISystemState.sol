// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Smart contracts
import "./ISIR.sol";
import "./IFees.sol";

interface ISystemState is IFees, ISIR {
    function SYSTEM_CONTROL() external returns (address);

    function onlyWithdrawals() external view returns (bool);

    function updateSystemParameters(
        uint40 tsIssuanceStart_,
        uint16 basisFee_,
        bool onlyWithdrawals_
    ) external;

    function setPoolsIssuances() external;

    function setContributorsIssuances() external;

    function changePoolsIssuances(
        address[] calldata prevPools,
        bytes16[] memory latestSuppliesMAAM,
        address[] calldata nextPools,
        uint16[] calldata taxesToDAO,
        uint256 sumTaxes
    ) external returns (bytes32);

    function recalibratePoolsIssuances(
        address[] calldata pools,
        bytes16[] memory latestSuppliesMAAM,
        uint256 sumTaxes
    ) external;

    function changeContributorsIssuances(
        address[] calldata prevContributors,
        address[] calldata nextContributors,
        uint72[] calldata issuances,
        bool allowAnyTotalIssuance
    ) external returns (bytes32);
}
