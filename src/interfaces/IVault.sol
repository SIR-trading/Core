// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IVault {
    struct FeeStructure {
        uint16 fee;
        uint16 feeNew;
        uint40 timestampUpdate;
    }

    struct Reserves {
        uint144 reserveApes;
        uint144 reserveLPers;
        int64 tickPriceX42;
    }

    struct SystemParameters {
        FeeStructure baseFee;
        FeeStructure lpFee;
        bool mintingStopped;
        uint16 cumulativeTax;
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

    error AmountTooLow();
    error DeadlineExceeded();
    error InsufficientCollateralReceivedFromUniswap();
    error LengthMismatch();
    error LeverageTierOutOfRange();
    error Locked();
    error NotAWETHVault();
    error NotAuthorized();
    error StringsInsufficientHexLength(uint256 value, uint256 length);
    error TEAMaxSupplyExceeded();
    error UnsafeRecipient();
    error VaultAlreadyInitialized();
    error VaultDoesNotExist();

    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event ReservesChanged(uint48 indexed vaultId, bool isAPE, bool isMint, uint144 reserveLPers, uint144 reserveApes);
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
    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId,
        address ape
    );
    event VaultNewTax(uint48 indexed vault, uint8 tax, uint16 cumulativeTax);

    function APE_IMPLEMENTATION() external view returns (address);
    function ORACLE() external view returns (address);
    function SIR() external view returns (address);
    function SYSTEM_CONTROL() external view returns (address);
    function TIMESTAMP_ISSUANCE_START() external view returns (uint40);
    function balanceOf(address account, uint256 vaultId) external view returns (uint256);
    function balanceOfBatch(
        address[] memory owners,
        uint256[] memory vaultIds
    ) external view returns (uint256[] memory balances_);
    function burn(
        bool isAPE,
        VaultParameters memory vaultParams,
        uint256 amount,
        uint40 deadline
    ) external returns (uint144);
    function claimSIR(uint256 vaultId, address lper) external returns (uint80);
    function cumulativeSIRPerTEA(uint256 vaultId) external view returns (uint176 cumulativeSIRPerTEAx96);
    function getReserves(VaultParameters memory vaultParams) external view returns (Reserves memory);
    function initialize(VaultParameters memory vaultParams) external;
    function isApprovedForAll(address, address) external view returns (bool);
    function mint(
        bool isAPE,
        VaultParameters memory vaultParams,
        uint256 amountToDeposit,
        uint144 collateralToDepositMin,
        uint40 deadline
    ) external payable returns (uint256 amount);
    function numberOfVaults() external view returns (uint48);
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
    function systemParams() external view returns (SystemParameters memory systemParams_);
    function totalReserves(address collateral) external view returns (uint256);
    function totalSupply(uint256 vaultId) external view returns (uint256);
    function unclaimedRewards(uint256 vaultId, address lper) external view returns (uint80);
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes memory data) external;
    function updateSystemState(uint16 baseFee, uint16 lpFee, bool mintingStopped) external;
    function updateVaults(
        uint48[] memory oldVaults,
        uint48[] memory newVaults,
        uint8[] memory newTaxes,
        uint16 cumulativeTax
    ) external;
    function uri(uint256 vaultId) external view returns (string memory);
    function vaultStates(VaultParameters memory vaultParams) external view returns (VaultState memory);
    function vaultTax(uint48 vaultId) external view returns (uint8);
    function withdrawFees(address token) external returns (uint256 totalFeesToStakers);
    function withdrawToSaveSystem(address[] memory tokens, address to) external returns (uint256[] memory amounts);
}
