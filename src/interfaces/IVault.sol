// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import {SirStructs} from "../libraries/SirStructs.sol";

interface IVault {
    error LengthMismatch();
    error NotAuthorized();
    error TEAMaxSupplyExceeded();
    error UnsafeRecipient();

    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event Burn(
        uint48 indexed vaultId,
        bool isAPE,
        uint144 collateralWithdrawn,
        uint144 collateralFeeToStakers,
        uint144 collateralFeeToLPers
    );
    event Mint(
        uint48 indexed vaultId,
        bool isAPE,
        uint144 collateralIn,
        uint144 collateralFeeToStakers,
        uint144 collateralFeeToLPers
    );
    event FeesToStakers(address indexed collateralToken, uint112 totalFeesToStakers);
    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] vaultIds,
        uint256[] amounts
    );
    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 amount
    );
    event URI(string value, uint256 indexed id);
    event VaultNewTax(uint48 indexed vault, uint8 tax, uint16 cumulativeTax);

    function TIMESTAMP_ISSUANCE_START() external view returns (uint40);

    function balanceOf(address account, uint256 vaultId) external view returns (uint256);

    function balanceOfBatch(
        address[] calldata owners,
        uint256[] calldata vaultIds
    ) external view returns (uint256[] memory balances_);

    function burn(
        bool isAPE,
        SirStructs.VaultParameters calldata vaultParams,
        uint256 amount
    ) external returns (uint144);

    function claimSIR(uint256 vaultId, address lper) external returns (uint80);

    function collateralStates(address token) external view returns (SirStructs.CollateralState memory);

    function cumulativeSIRPerTEA(uint256 vaultId) external view returns (uint176 cumulativeSIRPerTEAx96);

    function getReserves(
        SirStructs.VaultParameters calldata vaultParams
    ) external view returns (SirStructs.Reserves memory);

    function initialize(SirStructs.VaultParameters memory vaultParams) external;

    function isApprovedForAll(address, address) external view returns (bool);

    function mint(
        bool isAPE,
        SirStructs.VaultParameters calldata vaultParams,
        uint144 collateralToDeposit
    ) external payable returns (uint256 amount);

    function numberOfVaults() external view returns (uint48);

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external returns (bytes4);

    function onERC1155Received(address, address, uint256, uint256, bytes memory) external returns (bytes4);

    function paramsById(uint48 vaultId) external view returns (SirStructs.VaultParameters memory);

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata vaultIds,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;

    function safeTransferFrom(address from, address to, uint256 vaultId, uint256 amount, bytes calldata data) external;

    function setApprovalForAll(address operator, bool approved) external;

    function supportsInterface(bytes4 interfaceId) external pure returns (bool);

    function systemParams() external view returns (SirStructs.SystemParameters memory);

    function totalSupply(uint256 vaultId) external view returns (uint256);

    function unclaimedRewards(uint256 vaultId, address lper) external view returns (uint80);

    function updateSystemState(uint16 baseFee, uint16 lpFee, bool mintingStopped) external;

    function updateVaults(
        uint48[] calldata oldVaults,
        uint48[] calldata newVaults,
        uint8[] calldata newTaxes,
        uint16 cumulativeTax
    ) external;

    function uri(uint256 vaultId) external view returns (string memory);

    function vaultStates(
        SirStructs.VaultParameters calldata vaultParams
    ) external view returns (SirStructs.VaultState memory);

    function vaultTax(uint48 vaultId) external view returns (uint8);

    function withdrawFees(address token) external returns (uint112 totalFeesToStakers);

    function withdrawToSaveSystem(address[] calldata tokens, address to) external returns (uint256[] memory amounts);
}
