// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {VaultStructs} from "./libraries/VaultStructs.sol";
import {VaultExternal} from "./libraries/VaultExternal.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {Fees} from "./libraries/Fees.sol";
import {SystemConstants} from "./libraries/SystemConstants.sol";

// Contracts
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {SystemState} from "./SystemState.sol";

import "forge-std/Test.sol";

/** @notice Modified from Solmate
 */
contract TEA is SystemState, ERC1155TokenReceiver {
    error TEAMaxSupplyExceeded();
    error NotAuthorized();
    error LengthMismatch();
    error UnsafeRecipient();

    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 amount
    );

    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] vaultIds,
        uint256[] amounts
    );

    struct TotalSupplyAndBalanceVault {
        uint128 totalSupply;
        uint128 balanceVault;
    }

    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event URI(string value, uint256 indexed id);

    mapping(address => mapping(uint256 => uint256)) internal balances;
    /** Because of the protocol owned liquidity (POL) is updated on every mint/burn of TEA/APE, we packed both values,
        totalSupply and POL balance, into a single uint256 to save gas on SLOADs.
        Fortunately, the max supply of TEA fits in 128 bits, so we can use the other 128 bits for POL.
     */
    mapping(uint256 vaultId => TotalSupplyAndBalanceVault) internal totalSupplyAndBalanceVault;

    VaultStructs.VaultParameters[] public _paramsById; // Never used in Vault.sol. Just for users to access vault parameters by vault ID.
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(address systemControl, address sir) SystemState(systemControl, sir) {}

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function paramsById(uint48 vaultId) external view returns (VaultStructs.VaultParameters memory) {
        return _paramsById[vaultId];
    }

    function numberOfVaults() external view returns (uint48) {
        return uint48(_paramsById.length - 1);
    }

    function totalSupply(uint256 vaultId) external view returns (uint256) {
        return totalSupplyAndBalanceVault[vaultId].totalSupply;
    }

    function supplyExcludeVault(uint256 vaultId) internal view override returns (uint256) {
        TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];
        return totalSupplyAndBalanceVault_.totalSupply - totalSupplyAndBalanceVault_.balanceVault;
    }

    function uri(uint256 vaultId) external view returns (string memory) {
        uint256 totalSupply_ = totalSupplyAndBalanceVault[vaultId].totalSupply;
        return VaultExternal.teaURI(_paramsById, vaultId, totalSupply_);
    }

    function balanceOf(address account, uint256 vaultId) public view override returns (uint256) {
        return account == address(this) ? totalSupplyAndBalanceVault[vaultId].balanceVault : balances[account][vaultId];
    }

    function balanceOfBatch(
        address[] calldata owners,
        uint256[] calldata vaultIds
    ) external view returns (uint256[] memory balances_) {
        if (owners.length != vaultIds.length) revert LengthMismatch();

        balances_ = new uint256[](owners.length);

        // Unchecked because the only math done is incrementing
        // the array index counter which cannot possibly overflow.
        unchecked {
            for (uint256 i = 0; i < owners.length; ++i) {
                balances_[i] = balanceOf(owners[i], vaultIds[i]);
            }
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165 Interface ID for ERC165
            interfaceId == 0xd9b67a26 || // ERC165 Interface ID for ERC1155
            interfaceId == 0x0e89341c; // ERC165 Interface ID for ERC1155MetadataURI
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;

        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function safeTransferFrom(address from, address to, uint256 vaultId, uint256 amount, bytes calldata data) external {
        assert(from != address(this));
        if (msg.sender != from && !isApprovedForAll[from][msg.sender]) revert NotAuthorized();

        // Update SIR issuances
        LPersBalances memory lpersBalances = LPersBalances(from, balances[from][vaultId], to, balanceOf(to, vaultId));
        updateLPerIssuanceParams(
            false,
            vaultId,
            _systemParams,
            vaultIssuanceParams[vaultId],
            supplyExcludeVault(vaultId),
            lpersBalances
        );

        lpersBalances.balance0 -= amount;

        if (from != to) {
            balances[from][vaultId] = lpersBalances.balance0; // POL can never be transfered out
            unchecked {
                _setBalance(to, vaultId, lpersBalances.balance1 + amount);
            }
        }

        emit TransferSingle(msg.sender, from, to, vaultId, amount);

        if (
            to.code.length == 0
                ? to == address(0)
                : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, vaultId, amount, data) !=
                    ERC1155TokenReceiver.onERC1155Received.selector
        ) revert UnsafeRecipient();
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata vaultIds,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        assert(from != address(this));
        if (vaultIds.length != amounts.length) revert LengthMismatch();
        if (msg.sender != from && !isApprovedForAll[from][msg.sender]) revert NotAuthorized();

        LPersBalances memory lpersBalances;
        for (uint256 i = 0; i < vaultIds.length; ) {
            uint256 vaultId = vaultIds[i];
            uint256 amount = amounts[i];

            // Update SIR issuances
            lpersBalances = LPersBalances(from, balances[from][vaultId], to, balanceOf(to, vaultId));
            updateLPerIssuanceParams(
                false,
                vaultId,
                _systemParams,
                vaultIssuanceParams[vaultId],
                supplyExcludeVault(vaultId),
                lpersBalances
            );

            lpersBalances.balance0 -= amount;

            if (from != to) {
                balances[from][vaultId] = lpersBalances.balance0;
                unchecked {
                    _setBalance(to, vaultId, lpersBalances.balance1 + amount);
                }
            }

            unchecked {
                // An array can't have a total length
                // larger than the max uint256 value.
                ++i;
            }
        }

        emit TransferBatch(msg.sender, from, to, vaultIds, amounts);

        if (
            to.code.length == 0
                ? to == address(0)
                : ERC1155TokenReceiver(to).onERC1155BatchReceived(msg.sender, from, vaultIds, amounts, data) !=
                    ERC1155TokenReceiver.onERC1155BatchReceived.selector
        ) revert UnsafeRecipient();
    }

    /**
        @dev To avoid extra SLOADs, we also mint POL when minting TEA.
        @dev It modifies reserves
     */
    function mint(
        address collateral,
        address to,
        uint48 vaultId,
        VaultStructs.SystemParameters memory systemParams_,
        VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_,
        VaultStructs.Reserves memory reserves,
        uint144 collateralDeposited
    ) internal returns (VaultStructs.Fees memory fees, uint256 amount) {
        unchecked {
            // Loads supply and balance of TEA
            TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];
            uint256 balanceOfTo = balances[to][vaultId];

            // Update SIR issuance if it is not POL
            LPersBalances memory lpersBalances = LPersBalances(to, balanceOfTo, address(this), 0);
            updateLPerIssuanceParams(
                false,
                vaultId,
                systemParams_,
                vaultIssuanceParams_,
                totalSupplyAndBalanceVault_.totalSupply - totalSupplyAndBalanceVault_.balanceVault,
                lpersBalances
            );

            // Substract fees and distribute them across SIR stakers, LPers and protocol
            fees = _distributeFees(
                collateral,
                vaultId,
                totalSupplyAndBalanceVault_,
                systemParams_.lpFee,
                vaultIssuanceParams_.tax,
                reserves,
                collateralDeposited
            );

            // Mint TEA
            amount = totalSupplyAndBalanceVault_.totalSupply == 0 // By design reserveLPers can never be 0 unless it is the first mint ever
                ? _amountFirstMint(collateral, fees.collateralInOrWithdrawn + reserves.reserveLPers)
                : FullMath.mulDiv(
                    totalSupplyAndBalanceVault_.totalSupply,
                    fees.collateralInOrWithdrawn,
                    reserves.reserveLPers
                );

            // Check that total supply does not overflow
            if (amount > SystemConstants.TEA_MAX_SUPPLY - totalSupplyAndBalanceVault_.totalSupply) {
                revert TEAMaxSupplyExceeded();
            }

            // Update balance and total supply
            balances[to][vaultId] = balanceOfTo + amount;
            totalSupplyAndBalanceVault_.totalSupply += uint128(amount);

            // Update reserves
            reserves.reserveLPers += fees.collateralInOrWithdrawn;

            // Store total supply
            totalSupplyAndBalanceVault[vaultId] = totalSupplyAndBalanceVault_;

            if (
                to.code.length == 0
                    ? to == address(0)
                    : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, address(0), vaultId, amount, "") !=
                        ERC1155TokenReceiver.onERC1155Received.selector
            ) revert UnsafeRecipient();

            // Emit transfer event
            emit TransferSingle(msg.sender, address(0), to, vaultId, amount);
        }
    }

    function mintToProtocol(
        address collateral,
        uint48 vaultId,
        VaultStructs.Reserves memory reserves,
        uint144 collateralFeeToProtocol
    ) internal {
        unchecked {
            // Loads supply and balance of TEA
            TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];

            // Mint TEA
            uint256 amountToProtocol = totalSupplyAndBalanceVault_.totalSupply == 0 // By design reserveLPers can never be 0 unless it is the first mint ever
                ? _amountFirstMint(collateral, collateralFeeToProtocol + reserves.reserveLPers)
                : FullMath.mulDiv(
                    totalSupplyAndBalanceVault_.totalSupply,
                    collateralFeeToProtocol,
                    reserves.reserveLPers
                );

            // Check that total supply does not overflow
            if (amountToProtocol > SystemConstants.TEA_MAX_SUPPLY - totalSupplyAndBalanceVault_.totalSupply) {
                revert TEAMaxSupplyExceeded();
            }

            // Update balance and total supply
            totalSupplyAndBalanceVault_.balanceVault += uint128(amountToProtocol);
            totalSupplyAndBalanceVault_.totalSupply += uint128(amountToProtocol);

            // Update reserves
            reserves.reserveLPers += collateralFeeToProtocol;

            // Store total supply and vault balance
            totalSupplyAndBalanceVault[vaultId] = totalSupplyAndBalanceVault_;

            // Emit transfer event
            emit TransferSingle(msg.sender, address(0), address(this), vaultId, amountToProtocol);
        }
    }

    function burn(
        address collateral,
        address from,
        uint48 vaultId,
        VaultStructs.SystemParameters memory systemParams_,
        VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_,
        VaultStructs.Reserves memory reserves,
        uint256 amount
    ) internal returns (VaultStructs.Fees memory fees) {
        unchecked {
            // Loads supply and balance of TEA
            TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];
            uint256 balanceOfFrom = balances[from][vaultId];

            // Update SIR issuance
            LPersBalances memory lpersBalances = LPersBalances(from, balanceOfFrom, address(this), 0);
            updateLPerIssuanceParams(
                false,
                vaultId,
                systemParams_,
                vaultIssuanceParams_,
                totalSupplyAndBalanceVault_.totalSupply - totalSupplyAndBalanceVault_.balanceVault,
                lpersBalances
            );

            // Burn TEA
            uint144 collateralOut = uint144(
                FullMath.mulDiv(reserves.reserveLPers, amount, totalSupplyAndBalanceVault_.totalSupply)
            ); // Compute amount of collateral

            // Check we are not burning more than the balance
            require(amount <= balanceOfFrom);

            // Update balance and total supply
            balances[from][vaultId] = balanceOfFrom - amount;
            totalSupplyAndBalanceVault_.totalSupply -= uint128(amount);

            // Update reserves
            reserves.reserveLPers -= collateralOut;

            // Substract fees and distribute them across SIR stakers, LPers and POL
            fees = _distributeFees(
                collateral,
                vaultId,
                totalSupplyAndBalanceVault_,
                systemParams_.lpFee,
                vaultIssuanceParams_.tax,
                reserves,
                collateralOut
            );

            // Update total supply and vault balance
            totalSupplyAndBalanceVault[vaultId] = totalSupplyAndBalanceVault_;

            // Emit transfer event
            emit TransferSingle(msg.sender, from, address(0), vaultId, amount);
        }
    }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @notice Make sure that even if the entire supply of the collateral token was deposited into the vault,
        the amount of TEA minted is less than the maximum supply of TEA.
     */
    function _amountFirstMint(address collateral, uint144 collateralIn) private view returns (uint256 amount) {
        uint256 collateralTotalSupply = IERC20(collateral).totalSupply();
        amount = collateralTotalSupply > SystemConstants.TEA_MAX_SUPPLY
            ? FullMath.mulDiv(SystemConstants.TEA_MAX_SUPPLY, collateralIn, collateralTotalSupply)
            : collateralIn;
    }

    function _setBalance(address account, uint256 vaultId, uint256 balance) private {
        if (account == address(this)) totalSupplyAndBalanceVault[vaultId].balanceVault = uint128(balance);
        else balances[account][vaultId] = balance;
    }

    function _distributeFees(
        address collateral,
        uint48 vaultId,
        TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_,
        uint16 lpFee,
        uint8 tax,
        VaultStructs.Reserves memory reserves,
        uint144 collateralDepositedOrOut
    ) private returns (VaultStructs.Fees memory fees) {
        unchecked {
            // Substract fees
            fees = Fees.hiddenFeeTEA(collateralDepositedOrOut, lpFee, tax);

            // Pay some fees to LPers by increasing the LP reserve so that each share (TEA unit) is worth more
            reserves.reserveLPers += fees.collateralFeeToGentlemen;

            // Mint some TEA as protocol owned liquidity (POL)
            uint256 amountToProtocol = totalSupplyAndBalanceVault_.totalSupply == 0 // By design reserveLPers can never be 0 unless it is the first mint ever
                ? _amountFirstMint(collateral, fees.collateralFeeToProtocol + reserves.reserveLPers) // Any ownless LP reserve is minted as POL too
                : FullMath.mulDiv(
                    totalSupplyAndBalanceVault_.totalSupply,
                    fees.collateralFeeToProtocol,
                    reserves.reserveLPers
                );

            // Check that total supply does not overflow
            if (amountToProtocol > SystemConstants.TEA_MAX_SUPPLY - totalSupplyAndBalanceVault_.totalSupply) {
                revert TEAMaxSupplyExceeded();
            }

            // Update total supply and protocol balance
            totalSupplyAndBalanceVault_.balanceVault += uint128(amountToProtocol);
            totalSupplyAndBalanceVault_.totalSupply += uint128(amountToProtocol);

            // Update reserves
            reserves.reserveLPers += fees.collateralFeeToProtocol;

            emit TransferSingle(msg.sender, address(0), address(this), vaultId, amountToProtocol);
        }
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM STATE VIRTUAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function cumulativeSIRPerTEA(uint256 vaultId) public view override returns (uint176 cumSIRPerTEAx96) {
        return cumulativeSIRPerTEA(_systemParams, vaultIssuanceParams[vaultId], supplyExcludeVault(vaultId));
    }
}
