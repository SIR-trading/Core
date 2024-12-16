// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {SirStructs} from "./libraries/SirStructs.sol";
import {VaultExternal} from "./libraries/VaultExternal.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {Fees} from "./libraries/Fees.sol";
import {SystemConstants} from "./libraries/SystemConstants.sol";

// Contracts
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {SystemState} from "./SystemState.sol";

import "forge-std/console.sol";

/** @notice Modified from Solmate
 */
contract TEA is SystemState {
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

    SirStructs.VaultParameters[] internal _paramsById; // Never used in Vault.sol. Just for users to access vault parameters by vault ID.
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(address systemControl, address sir) SystemState(systemControl, sir) {}

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function paramsById(uint48 vaultId) external view returns (SirStructs.VaultParameters memory) {
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

        // Update balances
        _updateBalances(from, to, vaultId, amount);

        emit TransferSingle(msg.sender, from, to, vaultId, amount);

        if (
            to.code.length == 0
                ? to == address(0)
                : to != address(this) &&
                    ERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, vaultId, amount, data) !=
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
        unchecked {
            assert(from != address(this));
            if (vaultIds.length != amounts.length) revert LengthMismatch();
            if (msg.sender != from && !isApprovedForAll[from][msg.sender]) revert NotAuthorized();

            for (uint256 i = 0; i < vaultIds.length; ++i) {
                // Update balances
                _updateBalances(from, to, vaultIds[i], amounts[i]);
            }

            emit TransferBatch(msg.sender, from, to, vaultIds, amounts);

            if (
                to.code.length == 0
                    ? to == address(0)
                    : to != address(this) &&
                        ERC1155TokenReceiver(to).onERC1155BatchReceived(msg.sender, from, vaultIds, amounts, data) !=
                        ERC1155TokenReceiver.onERC1155BatchReceived.selector
            ) revert UnsafeRecipient();
        }
    }

    /**
        @dev To avoid extra SLOADs, we also mint POL when minting TEA.
        @dev It modifies reserves
     */
    function mint(
        address collateral,
        uint48 vaultId,
        SirStructs.SystemParameters memory systemParams_,
        SirStructs.VaultIssuanceParams memory vaultIssuanceParams_,
        SirStructs.Reserves memory reserves,
        uint144 collateralDeposited
    ) internal returns (SirStructs.Fees memory fees, uint256 amount) {
        uint256 amountToPOL;
        unchecked {
            // Loads supply and balance of TEA
            TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];
            uint256 balanceOfTo = balances[msg.sender][vaultId];

            // Update SIR issuance of gentlemen
            LPersBalances memory lpersBalances = LPersBalances(msg.sender, balanceOfTo, address(this), 0);
            updateLPerIssuanceParams(
                false,
                vaultId,
                systemParams_,
                vaultIssuanceParams_,
                totalSupplyAndBalanceVault_.totalSupply - totalSupplyAndBalanceVault_.balanceVault,
                lpersBalances
            );

            // Total amount of TEA to mint (and to split between minter and POL)
            amount = totalSupplyAndBalanceVault_.totalSupply == 0 // By design reserveLPers can never be 0 unless it is the first mint ever
                ? _amountFirstMint(collateral, collateralDeposited + reserves.reserveLPers) // In the first mint, reserveLPers contains orphaned fees from apes
                : FullMath.mulDiv(totalSupplyAndBalanceVault_.totalSupply, collateralDeposited, reserves.reserveLPers);

            // Check that total supply does not overflow
            if (amount > SystemConstants.TEA_MAX_SUPPLY - totalSupplyAndBalanceVault_.totalSupply) {
                revert TEAMaxSupplyExceeded();
            }

            // Split collateralDeposited between minter and POL
            fees = Fees.feeMintTEA(collateralDeposited, systemParams_.lpFee);

            // Part of the new minted TEA to protocol owned liquidity (POL)
            amountToPOL = totalSupplyAndBalanceVault_.totalSupply == 0
                ? FullMath.mulDiv(
                    amount,
                    fees.collateralFeeToLPers + reserves.reserveLPers, // In the first mint, orphaned fees from apes are distributed to POL
                    collateralDeposited + reserves.reserveLPers
                )
                : FullMath.mulDiv(amount, fees.collateralFeeToLPers, collateralDeposited);

            // TEA to minter
            amount -= amountToPOL;

            // Update total supply and protocol balance
            balances[msg.sender][vaultId] = balanceOfTo + amount;
            totalSupplyAndBalanceVault_.balanceVault += uint128(amountToPOL);
            totalSupplyAndBalanceVault_.totalSupply += uint128(amount + amountToPOL);

            // Store total supply
            totalSupplyAndBalanceVault[vaultId] = totalSupplyAndBalanceVault_;
        }

        // Update reserves
        reserves.reserveLPers += collateralDeposited;

        // Emit (mint) transfer events
        emit TransferSingle(msg.sender, address(0), msg.sender, vaultId, amount);
        emit TransferSingle(msg.sender, address(0), address(this), vaultId, amountToPOL);
    }

    function burn(
        uint48 vaultId,
        SirStructs.SystemParameters memory systemParams_,
        SirStructs.VaultIssuanceParams memory vaultIssuanceParams_,
        SirStructs.Reserves memory reserves,
        uint256 amount
    ) internal returns (SirStructs.Fees memory fees) {
        unchecked {
            // Loads supply and balance of TEA
            TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];
            uint256 balanceOfFrom = balances[msg.sender][vaultId];

            // Check we are not burning more than the balance
            require(amount <= balanceOfFrom);

            // Update SIR issuance
            LPersBalances memory lpersBalances = LPersBalances(msg.sender, balanceOfFrom, address(this), 0);
            updateLPerIssuanceParams(
                false,
                vaultId,
                systemParams_,
                vaultIssuanceParams_,
                totalSupplyAndBalanceVault_.totalSupply - totalSupplyAndBalanceVault_.balanceVault,
                lpersBalances
            );

            // Burn TEA
            fees.collateralInOrWithdrawn = uint144(
                FullMath.mulDiv(reserves.reserveLPers, amount, totalSupplyAndBalanceVault_.totalSupply)
            ); // Compute amount of collateral

            // Update balance and total supply
            balances[msg.sender][vaultId] = balanceOfFrom - amount;
            totalSupplyAndBalanceVault_.totalSupply -= uint128(amount);

            // Update reserves
            reserves.reserveLPers -= fees.collateralInOrWithdrawn;

            // Update total supply and vault balance
            totalSupplyAndBalanceVault[vaultId] = totalSupplyAndBalanceVault_;

            // Emit transfer event
            emit TransferSingle(msg.sender, msg.sender, address(0), vaultId, amount);
        }
    }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @notice Make sure that even if the entire supply of the collateral token was deposited into the vault,
        the amount of TEA minted is less than the maximum supply of TEA.
     */
    function _amountFirstMint(address collateral, uint144 collateralDeposited) private view returns (uint256 amount) {
        uint256 collateralTotalSupply = IERC20(collateral).totalSupply();
        /** When possible assign siz 0's to the TEA balance per unit of collateral to mitigate inflation attacks.
            If not possible mint as much as TEA as possible while forcing that if all collateral was minted, it would not overflow the TEA maximum supply.
         */
        amount = collateralTotalSupply > SystemConstants.TEA_MAX_SUPPLY / 1e6
            ? FullMath.mulDiv(SystemConstants.TEA_MAX_SUPPLY, collateralDeposited, collateralTotalSupply)
            : collateralDeposited * 1e6;
    }

    function _setBalance(address account, uint256 vaultId, uint256 balance) private {
        if (account == address(this)) totalSupplyAndBalanceVault[vaultId].balanceVault = uint128(balance);
        else balances[account][vaultId] = balance;
    }

    function _updateBalances(address from, address to, uint256 vaultId, uint256 amount) private {
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

        // Update balances
        lpersBalances.balance0 -= amount;
        if (from != to) {
            balances[from][vaultId] = lpersBalances.balance0;
            unchecked {
                _setBalance(to, vaultId, lpersBalances.balance1 + amount);
            }
        }
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM STATE VIRTUAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function cumulativeSIRPerTEA(uint256 vaultId) public view override returns (uint176 cumulativeSIRPerTEAx96) {
        return cumulativeSIRPerTEA(_systemParams, vaultIssuanceParams[vaultId], supplyExcludeVault(vaultId));
    }
}
