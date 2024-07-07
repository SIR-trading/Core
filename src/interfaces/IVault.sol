// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

interface IVault {
    struct CollateralState {
        uint112 totalFeesToStakers;
        uint144 total;
    }

    struct Reserves {
        uint144 reserveApes;
        uint144 reserveLPers;
        int64 tickPriceX42;
    }

    struct SystemParameters {
        uint16 baseFee;
        uint16 lpFee;
        bool mintingStopped;
        uint16 cumTax;
    }

    struct TokenParameters {
        string name;
        string symbol;
        uint8 decimals;
    }

    struct VaultParameters {
        address debtToken;
        address collateralToken;
        int8 leverageTier;
    }

    struct VaultState {
        uint144 reserve;
        int64 tickPriceSatX42;
        uint48 vaultId;
    }

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
    event VaultNewTax(uint48 indexed vault, uint8 tax, uint16 cumTax);

    function TS_ISSUANCE_START() external view returns (uint40);

    function balanceOf(address account, uint256 vaultId) external view returns (uint256);

    function balanceOfBatch(
        address[] memory owners,
        uint256[] memory vaultIds
    ) external view returns (uint256[] memory balances_);

    function burn(bool isAPE, VaultParameters memory vaultParams, uint256 amount) external returns (uint144);

    function claimSIR(uint256 vaultId, address lper) external returns (uint80);

    function collateralStates(address token) external view returns (CollateralState memory);

    function cumulativeSIRPerTEA(uint256 vaultId) external view returns (uint176 cumSIRPerTEAx96);

    function getReserves(VaultParameters memory vaultParams) external view returns (Reserves memory);

    function initialize(VaultParameters memory vaultParams) external;

    function isApprovedForAll(address, address) external view returns (bool);

    function latestTokenParams() external view returns (TokenParameters memory, VaultParameters memory);

    function mint(bool isAPE, VaultParameters memory vaultParams) external returns (uint256 amount);

    function numberOfVaults() external view returns (uint48);

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external returns (bytes4);

    function onERC1155Received(address, address, uint256, uint256, bytes memory) external returns (bytes4);

    function paramsById(uint48 vaultId) external view returns (VaultParameters memory);

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory vaultIds,
        uint256[] memory amounts,
        bytes memory data
    ) external;

    function safeTransferFrom(address from, address to, uint256 vaultId, uint256 amount, bytes memory data) external;

    function setApprovalForAll(address operator, bool approved) external;

    function supportsInterface(bytes4 interfaceId) external pure returns (bool);

    function systemParams() external view returns (SystemParameters memory);

    function totalSupply(uint256 vaultId) external view returns (uint256);

    function unclaimedRewards(uint256 vaultId, address lper) external view returns (uint80);

    function updateSystemState(uint16 baseFee, uint16 lpFee, bool mintingStopped) external;

    function updateVaults(
        uint48[] memory oldVaults,
        uint48[] memory newVaults,
        uint8[] memory newTaxes,
        uint16 cumTax
    ) external;

    function uri(uint256 vaultId) external view returns (string memory);

    function vaultStates(VaultParameters memory vaultParams) external view returns (VaultState memory);

    function vaultTax(uint48 vaultId) external view returns (uint8);

    function withdrawFees(address token) external returns (uint112 totalFeesToStakers);

    function withdrawToSaveSystem(address[] memory tokens, address to) external returns (uint256[] memory amounts);
}
