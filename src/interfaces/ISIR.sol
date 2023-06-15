// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import "@uniswap/v2-core/contracts/interfaces/IERC20.sol";

interface ISIR is IERC20 {
    function ISSUANCE_RATE() external view returns (uint72);

    function tsStart() external view returns (uint40);

    function contributorsReceivingSIR(uint256) external view returns (address);

    function poolsReceivingSIR(uint256) external view returns (address);

    function maxSupply() external view returns (uint256);

    function getContributorsIssuanceParams(address) external view returns (uint72 issuance, uint128 rewards);

    function LPerDebt(address pool, address LPer) external view returns (uint128 rewards);

    function getPoolsIssuanceParams(address)
        external
        view
        returns (
            uint16 taxToDAO,
            uint72 issuance,
            bytes16 cumSIRperMAAM
        );

    //////////////////////////////////////////////////////

    function startSIR() external;

    function setContributorsIssuances(
        address[] calldata contributorsReceivingSIR_,
        uint72[] calldata contributorsIssuances
    ) external;

    function setPoolsIssuances(address[] calldata poolsReceivingSIR_, uint24[] calldata taxesToDAO) external;

    function contributorMint() external;

    function updateIssuance(
        address LPer,
        bytes16 lastNonZeroBalance,
        bytes16 latestBalance,
        bytes16 latestSupplyMAAM
    ) external;

    function haultLPersIssuances(bytes16 nonRebasingSupplyMAAM) external;

    function LPerMint(address pool) external;
}
