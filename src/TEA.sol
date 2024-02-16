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

/** @notice Modified from Solmate
 */
contract TEA is SystemState, ERC1155TokenReceiver {
    error TEAMaxSupplyExceeded();

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

    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event URI(string value, uint256 indexed id);

    mapping(address => mapping(uint256 => uint256)) internal balances;
    /** Because of the protocol owned liquidity (POL) is updated on every mint/burn of TEA/APE, we packed both values,
        totalSupply and POL balance, into a single uint256 to save gas on SLOADs.
        Fortunately, the max supply of TEA fits in 128 bits, so we can use the other 128 bits for POL.
     */
    mapping(uint256 vaultId => TotalSupplyAndBalanceVault) internal totalSupplyAndBalanceVault;

    VaultStructs.VaultParameters[] public paramsById; // Never used in Vault.sol. Just for users to access vault parameters by vault ID.
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(address systemControl, address sir) SystemState(systemControl, sir) {}

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function totalSupply(uint256 vaultId) external view returns (uint256) {
        return totalSupplyAndBalanceVault[vaultId].totalSupply;
    }

    function supplyExcludeVault(uint256 vaultId) internal view override returns (uint256) {
        TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];
        return totalSupplyAndBalanceVault_.totalSupply - totalSupplyAndBalanceVault_.balanceVault;
    }

    function uri(uint256 vaultId) external view returns (string memory) {
        uint256 totalSupply_ = totalSupplyAndBalanceVault[vaultId].totalSupply;
        return VaultExternal.teaURI(paramsById, vaultId, totalSupply_);
    }

    function balanceOf(address owner, uint256 vaultId) public view override returns (uint256) {
        return owner == address(this) ? totalSupplyAndBalanceVault[vaultId].balanceVault : balances[owner][vaultId];
    }

    function balanceOfBatch(
        address[] calldata owners,
        uint256[] calldata vaultIds
    ) external view returns (uint256[] memory balances_) {
        require(owners.length == vaultIds.length, "LENGTH_MISMATCH");

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
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        if (from != to) {
            // Update SIR issuances
            LPersBalances memory lpersBalances = LPersBalances(
                from,
                balances[from][vaultId],
                to,
                balanceOf(to, vaultId)
            );
            updateLPerIssuanceParams(
                false,
                vaultId,
                systemParams,
                vaultIssuanceParams[vaultId],
                supplyExcludeVault(vaultId),
                lpersBalances
            );

            balances[from][vaultId] = lpersBalances.balance0 - amount; // POL can never be transfered out
            unchecked {
                _setBalance(to, vaultId, lpersBalances.balance1 + amount);
            }
        }

        emit TransferSingle(msg.sender, from, to, vaultId, amount);

        require(
            to.code.length == 0
                ? to != address(0)
                : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, vaultId, amount, data) ==
                    ERC1155TokenReceiver.onERC1155Received.selector,
            "UNSAFE_RECIPIENT"
        );
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata vaultIds,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        assert(from != address(this));
        require(vaultIds.length == amounts.length, "LENGTH_MISMATCH");

        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        if (from != to) {
            LPersBalances memory lpersBalances;
            for (uint256 i = 0; i < vaultIds.length; ) {
                uint256 vaultId = vaultIds[i];
                uint256 amount = amounts[i];

                // Update SIR issuances
                lpersBalances = LPersBalances(from, balances[from][vaultId], to, balanceOf(to, vaultId));
                updateLPerIssuanceParams(
                    false,
                    vaultId,
                    systemParams,
                    vaultIssuanceParams[vaultId],
                    supplyExcludeVault(vaultId),
                    lpersBalances
                );

                balances[from][vaultId] = lpersBalances.balance0 - amount;
                unchecked {
                    _setBalance(to, vaultId, lpersBalances.balance1 + amount);

                    // An array can't have a total length
                    // larger than the max uint256 value.
                    ++i;
                }
            }
        }

        emit TransferBatch(msg.sender, from, to, vaultIds, amounts);

        require(
            to.code.length == 0
                ? to != address(0)
                : ERC1155TokenReceiver(to).onERC1155BatchReceived(msg.sender, from, vaultIds, amounts, data) ==
                    ERC1155TokenReceiver.onERC1155BatchReceived.selector,
            "UNSAFE_RECIPIENT"
        );
    }

    /**
        @dev To avoid extra SLOADs, we also mint POL when minting TEA.
        @dev If to == address(this), we know this is just POL when minting/burning APE.
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
    ) internal returns (uint256 amount, uint144 collectedFee) {
        unchecked {
            // Loads supply and balance of TEA
            TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];
            uint256 balanceTo = to == address(this) ? totalSupplyAndBalanceVault_.balanceVault : balances[to][vaultId];

            uint144 collateralIn;
            if (to != address(this)) {
                // Update SIR issuance if it is not POL
                LPersBalances memory lpersBalances = LPersBalances(to, balanceTo, address(this), 0);
                updateLPerIssuanceParams(
                    false,
                    vaultId,
                    systemParams_,
                    vaultIssuanceParams_,
                    totalSupplyAndBalanceVault_.totalSupply - totalSupplyAndBalanceVault_.balanceVault,
                    lpersBalances
                );

                // Substract fees and distribute them across SIR stakers, LPers and POL
                (collateralIn, collectedFee) = _distributeFees(
                    collateral,
                    vaultId,
                    totalSupplyAndBalanceVault_,
                    systemParams_.lpFee,
                    vaultIssuanceParams_.tax,
                    reserves,
                    collateralDeposited
                );
            } else collateralIn = collateralDeposited;

            // Mint TEA
            amount = totalSupplyAndBalanceVault_.totalSupply == 0 // By design reserveLPers can never be 0 unless it is the first mint ever
                ? _amountFirstMint(collateral, collateralIn + reserves.reserveLPers)
                : FullMath.mulDiv(totalSupplyAndBalanceVault_.totalSupply, collateralIn, reserves.reserveLPers);
            if (to != address(this)) balances[to][vaultId] = balanceTo + amount;
            else totalSupplyAndBalanceVault_.balanceVault += uint128(amount);
            if (totalSupplyAndBalanceVault_.totalSupply + amount > SystemConstants.TEA_MAX_SUPPLY)
                revert TEAMaxSupplyExceeded();
            totalSupplyAndBalanceVault_.totalSupply += uint128(amount);
            reserves.reserveLPers += collateralIn;
            emit TransferSingle(msg.sender, address(0), to, vaultId, amount);

            // Update total supply and vault balance
            totalSupplyAndBalanceVault[vaultId] = totalSupplyAndBalanceVault_;

            require(
                to.code.length == 0
                    ? to != address(0)
                    : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, address(0), vaultId, amount, "") ==
                        ERC1155TokenReceiver.onERC1155Received.selector,
                "UNSAFE_RECIPIENT"
            );
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
    ) internal returns (uint144 collateralWidthdrawn, uint144 collectedFee) {
        unchecked {
            // Loads supply and balance of TEA
            TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];
            uint256 balanceFrom = balances[from][vaultId];

            // Update SIR issuance
            LPersBalances memory lpersBalances = LPersBalances(from, balanceFrom, address(this), 0);
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
            require(amount <= balanceFrom, "Insufficient balance");
            balances[from][vaultId] = balanceFrom - amount; // Checks for underflow
            totalSupplyAndBalanceVault_.totalSupply -= uint128(amount);
            reserves.reserveLPers -= collateralOut;
            emit TransferSingle(msg.sender, from, address(0), vaultId, amount);

            // Substract fees and distribute them across SIR stakers, LPers and POL
            (collateralWidthdrawn, collectedFee) = _distributeFees(
                collateral,
                vaultId,
                totalSupplyAndBalanceVault_,
                systemParams_.lpFee,
                vaultIssuanceParams_.tax,
                reserves,
                collateralOut
            );

            // Update total supply and vault balance
            if (totalSupplyAndBalanceVault_.totalSupply > SystemConstants.TEA_MAX_SUPPLY) revert TEAMaxSupplyExceeded();
            totalSupplyAndBalanceVault[vaultId] = totalSupplyAndBalanceVault_;
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

    function _setBalance(address owner, uint256 vaultId, uint256 balance) private {
        if (owner == address(this)) totalSupplyAndBalanceVault[vaultId].balanceVault = uint128(balance);
        else balances[owner][vaultId] = balance;
    }

    function _distributeFees(
        address collateral,
        uint48 vaultId,
        TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_,
        uint8 lpFee,
        uint8 tax,
        VaultStructs.Reserves memory reserves,
        uint144 collateralDepositedOrOut
    ) private returns (uint144 collateralInOrWidthdrawn, uint144 collectedFee) {
        uint256 amountPOL;
        unchecked {
            // To avoid stack too deep errors
            // Substract fees
            uint144 lpersFee;
            uint144 polFee;
            (collateralInOrWidthdrawn, collectedFee, lpersFee, polFee) = Fees.hiddenFeeTEA(
                collateralDepositedOrOut,
                lpFee,
                tax
            );

            // Pay some fees to LPers by increasing the LP reserve so that each share (TEA unit) is worth more
            reserves.reserveLPers += lpersFee;

            // Mint some TEA as protocol owned liquidity (POL)
            amountPOL = totalSupplyAndBalanceVault_.totalSupply == 0 // By design reserveLPers can never be 0 unless it is the first mint ever
                ? _amountFirstMint(collateral, polFee + reserves.reserveLPers) // Any ownless LP reserve is minted as POL too
                : FullMath.mulDiv(totalSupplyAndBalanceVault_.totalSupply, polFee, reserves.reserveLPers);
            require(
                amountPOL + totalSupplyAndBalanceVault_.totalSupply <= SystemConstants.TEA_MAX_SUPPLY,
                "Max supply exceeded"
            );
            totalSupplyAndBalanceVault_.balanceVault += uint128(amountPOL);
            totalSupplyAndBalanceVault_.totalSupply += uint128(amountPOL);
            reserves.reserveLPers += polFee;
        }
        emit TransferSingle(msg.sender, address(0), address(this), vaultId, amountPOL);
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM STATE VIRTUAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function cumulativeSIRPerTEA(uint256 vaultId) public view override returns (uint176 cumSIRPerTEAx96) {
        return cumulativeSIRPerTEA(systemParams, vaultIssuanceParams[vaultId], supplyExcludeVault(vaultId));
    }
}
