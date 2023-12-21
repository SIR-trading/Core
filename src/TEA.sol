// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Libraries
import {VaultStructs} from "./libraries/VaultStructs.sol";
import {VaultExternal} from "./libraries/VaultExternal.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {Fees} from "./libraries/Fees.sol";

// Contracts
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {SystemState} from "./SystemState.sol";

/** @notice Modified from Solmate
 */
abstract contract TEA is SystemState, ERC1155TokenReceiver {
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

    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event URI(string value, uint256 indexed id);

    mapping(address => mapping(uint256 => uint256)) private _balanceOf;
    /** Because of the protocol owned liquidity (POL) is updated on every mint/burn of TEA/APE, we packed both values,
        totalSupply and POL balance, into a single uint256 to save gas on SLOADs.
        
        _totalSupplyAndVaultBalance[vaultId]: [<--------128 bits-------->|<--------128 bits-------->]
                                                  totalSupply[vaultId]     balanceOf[user][vaultId]
     */
    mapping(uint256 vaultId => uint256) private _totalSupplyAndVaultBalance;

    VaultStructs.Parameters[] public paramsById; // Never used in Vault.sol. Just for users to access vault parameters by vault ID.
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(address systemControl, address sir) SystemState(systemControl, sir) {}

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function totalSupply(uint256 vaultId) public view returns (uint256) {
        return _totalSupplyAndVaultBalance[vaultId] >> 128;
    }

    function uri(uint256 vaultId) public view returns (string memory) {
        uint256 totalSupply_ = _totalSupplyAndVaultBalance[vaultId] >> 128;
        return VaultExternal.teaURI(paramsById, vaultId, totalSupply_);
    }

    function balanceOf(address owner, uint256 vaultId) public view returns (uint256) {
        return owner == address(this) ? uint128(_totalSupplyAndVaultBalance[vaultId]) : _balanceOf[owner][vaultId];
    }

    function balanceOfBatch(
        address[] calldata owners,
        uint256[] calldata vaultIds
    ) public view returns (uint256[] memory balances) {
        require(owners.length == vaultIds.length, "LENGTH_MISMATCH");

        balances = new uint256[](owners.length);

        // Unchecked because the only math done is incrementing
        // the array index counter which cannot possibly overflow.
        unchecked {
            for (uint256 i = 0; i < owners.length; ++i) {
                balances[i] = balanceOf(owners[i], vaultIds[i]);
            }
        }
    }

    function supportsInterface(bytes4 interfaceId) public view returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165 Interface ID for ERC165
            interfaceId == 0xd9b67a26 || // ERC165 Interface ID for ERC1155
            interfaceId == 0x0e89341c; // ERC165 Interface ID for ERC1155MetadataURI
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function setApprovalForAll(address operator, bool approved) public {
        isApprovedForAll[msg.sender][operator] = approved;

        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function safeTransferFrom(address from, address to, uint256 vaultId, uint256 amount, bytes calldata data) public {
        assert(from != address(this));
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        // Update SIR issuances
        LPersBalances memory lpersBalances;
        {
            // To avoid stack too deep errors
            lpersBalances = LPersBalances(from, _balanceOf[from][vaultId], to, balanceOf(to, vaultId));
        }
        updateLPerIssuanceParams(
            false,
            vaultId,
            systemParams,
            vaultIssuanceParams[vaultId],
            totalSupply(vaultId),
            lpersBalances
        );

        _balanceOf[from][vaultId] = lpersBalances.balance0 - amount; // POL can never be transfered out
        if (to == address(this)) _setVaultBalance(vaultId, lpersBalances.balance1 + amount);
        else _balanceOf[to][vaultId] = lpersBalances.balance1 + amount;

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
    ) public {
        assert(from != address(this));
        require(vaultIds.length == amounts.length, "LENGTH_MISMATCH");

        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        for (uint256 i = 0; i < vaultIds.length; ) {
            uint256 vaultId = vaultIds[i];
            uint256 amount = amounts[i];

            // Update SIR issuances
            LPersBalances memory lpersBalances;
            {
                // To avoid stack too deep errors
                lpersBalances = LPersBalances(from, _balanceOf[from][vaultId], to, balanceOf(to, vaultId));
            }
            updateLPerIssuanceParams(
                false,
                vaultId,
                systemParams,
                vaultIssuanceParams[vaultId],
                totalSupply(vaultId),
                lpersBalances
            );

            _balanceOf[from][vaultId] = lpersBalances.balance0 - amount;
            if (to == address(this)) _setVaultBalance(vaultId, lpersBalances.balance1 + amount);
            else _balanceOf[to][vaultId] = lpersBalances.balance1 + amount;

            // An array can't have a total length
            // larger than the max uint256 value.
            unchecked {
                ++i;
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
        address to,
        uint40 vaultId,
        VaultStructs.SystemParameters memory systemParams_,
        VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_,
        VaultStructs.Reserves memory reserves,
        uint152 collateralDeposited
    ) internal returns (uint256 amount) {
        unchecked {
            // Loads supply and balance of TEA
            (uint256 supplyTEA, uint256 balanceVault) = _getTotalSupplyAndVaultBalance(vaultId);
            uint256 balanceTo = to == address(this) ? balanceVault : _balanceOf[to][vaultId];

            // Update SIR issuance
            LPersBalances memory lpersBalances;
            {
                // To avoid stack too deep errors
                lpersBalances = LPersBalances(
                    to,
                    balanceTo,
                    to == address(this) ? address(0) : address(this), // We only need to update 1 address when it's POL only mint
                    balanceVault
                );
            }
            updateLPerIssuanceParams(false, vaultId, systemParams_, vaultIssuanceParams_, supplyTEA, lpersBalances);

            uint152 collateralIn;
            if (to != address(this)) {
                // Substract fees and distribute them across treasury, LPers and POL
                (supplyTEA, balanceVault, collateralIn) = _distributeFees(
                    vaultId,
                    balanceVault,
                    systemParams_.lpFee,
                    vaultIssuanceParams_.tax,
                    reserves,
                    supplyTEA,
                    collateralDeposited
                );
            } else collateralIn = collateralDeposited;

            // Mint TEA
            amount = supplyTEA == 0 // By design lpReserve can never be 0 unless it is the first mint ever
                ? collateralIn
                : FullMath.mulDiv(supplyTEA, collateralIn, reserves.lpReserve);
            if (to != address(this)) _balanceOf[to][vaultId] = balanceTo + amount;
            else balanceVault += amount;
            supplyTEA += amount;
            reserves.lpReserve += collateralIn;
            emit TransferSingle(msg.sender, address(0), to, vaultId, amount);

            // Update total supply and vault balance
            _setTotalSupplyAndVaultBalance(vaultId, supplyTEA, balanceVault);

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
        address from,
        uint40 vaultId,
        VaultStructs.SystemParameters memory systemParams_,
        VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_,
        VaultStructs.Reserves memory reserves,
        uint256 amount
    ) internal returns (uint152 collateralWidthdrawn) {
        // Loads supply and balance of TEA
        (uint256 supplyTEA, uint256 balanceVault) = _getTotalSupplyAndVaultBalance(vaultId);
        uint256 balanceFrom = _balanceOf[from][vaultId];

        // Update SIR issuance
        LPersBalances memory lpersBalances;
        {
            // To avoid stack too deep errors
            lpersBalances = LPersBalances(from, balanceFrom, address(this), balanceVault);
        }
        updateLPerIssuanceParams(false, vaultId, systemParams_, vaultIssuanceParams_, supplyTEA, lpersBalances);

        // Burn TEA
        uint152 collateralOut = uint152(FullMath.mulDiv(reserves.lpReserve, amount, supplyTEA)); // Compute amount of collateral
        _balanceOf[from][vaultId] = balanceFrom - amount; // Checks for underflow
        unchecked {
            supplyTEA -= amount;
            reserves.lpReserve -= collateralOut;
            emit TransferSingle(msg.sender, from, address(0), vaultId, amount);

            // Substract fees and distribute them across treasury, LPers and POL
            (supplyTEA, balanceVault, collateralWidthdrawn) = _distributeFees(
                vaultId,
                balanceVault,
                systemParams_.lpFee,
                vaultIssuanceParams_.tax,
                reserves,
                supplyTEA,
                collateralOut
            );

            // Update total supply and vault balance
            _setTotalSupplyAndVaultBalance(vaultId, supplyTEA, balanceVault);
        }
    }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _getTotalSupplyAndVaultBalance(
        uint256 vaultId
    ) internal view returns (uint256 totalSupply_, uint256 balanceVault) {
        uint256 totalSupplyAndVaultBalance_ = _totalSupplyAndVaultBalance[vaultId];
        totalSupply_ = totalSupplyAndVaultBalance_ >> 128;
        balanceVault = uint128(totalSupplyAndVaultBalance_);
    }

    function _setTotalSupplyAndVaultBalance(uint256 vaultId, uint256 totalSupply_, uint256 balanceVault) private {
        require(totalSupply_ <= TEA_MAX_SUPPLY, "OF"); // Check for overflow
        _totalSupplyAndVaultBalance[vaultId] = (totalSupply_ << 128) | balanceVault;
    }

    function _setVaultBalance(uint256 vaultId, uint256 balanceVault) private {
        _totalSupplyAndVaultBalance[vaultId] = ((_totalSupplyAndVaultBalance[vaultId] >> 128) << 128) | balanceVault;
    }

    function _distributeFees(
        uint40 vaultId,
        uint256 balanceVault,
        uint8 lpFee,
        uint8 tax,
        VaultStructs.Reserves memory reserves,
        uint256 supplyTEA,
        uint152 collateralDepositedOrOut
    ) private returns (uint256 newSupplyTEA, uint256 newBalanceVault, uint152 collateralInOrWidthdrawn) {
        uint256 amountPOL;
        unchecked {
            // To avoid stack too deep errors
            // Substract fees
            uint152 treasuryFee;
            uint152 lpersFee;
            uint152 polFee;
            (collateralInOrWidthdrawn, treasuryFee, lpersFee, polFee) = Fees.hiddenFeeTEA(
                collateralDepositedOrOut,
                lpFee,
                tax
            );

            // Diverge some of the deposited collateral to the Treasury
            reserves.treasury += treasuryFee;

            // Pay some fees to LPers by increasing the LP reserve so that each share (TEA unit) is worth more
            reserves.lpReserve += lpersFee;

            // Mint some TEA as protocol owned liquidity (POL)
            amountPOL = supplyTEA == 0 // By design lpReserve can never be 0 unless it is the first mint ever
                ? polFee + reserves.lpReserve // Any ownless LP reserve is minted as POL too
                : FullMath.mulDiv(supplyTEA, polFee, reserves.lpReserve);
            newBalanceVault = balanceVault + amountPOL;
            newSupplyTEA += amountPOL;
            reserves.lpReserve += polFee;
        }
        emit TransferSingle(msg.sender, address(0), address(this), vaultId, amountPOL);
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM STATE VIRTUAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function claimSIR(uint256 vaultId, address lper) external override returns (uint80) {
        require(msg.sender == sir);

        LPersBalances memory lpersBalances;
        {
            // To avoid stack too deep errors
            lpersBalances = LPersBalances(lper, balanceOf(lper, vaultId), address(0), 0);
        }

        return
            updateLPerIssuanceParams(
                true,
                vaultId,
                systemParams,
                vaultIssuanceParams[vaultId],
                totalSupply(vaultId),
                lpersBalances
            );
    }

    function unclaimedRewards(uint256 vaultId, address lper) external view override returns (uint80) {
        return
            unclaimedRewards(
                vaultId,
                lper,
                balanceOf(lper, vaultId),
                cumulativeSIRPerTEA(systemParams, vaultIssuanceParams[vaultId], totalSupply(vaultId))
            );
    }

    function cumulativeSIRPerTEA(uint256 vaultId) external view override returns (uint176 cumSIRPerTEAx96) {
        return cumulativeSIRPerTEA(systemParams, vaultIssuanceParams[vaultId], totalSupply(vaultId));
    }

    function updateVaults(
        uint40[] calldata oldVaults,
        uint40[] calldata newVaults,
        uint8[] calldata newTaxes,
        uint16 cumTax
    ) external override onlySystemControl {
        VaultStructs.SystemParameters memory systemParams_ = systemParams;

        // Stop old issuances
        for (uint256 i = 0; i < oldVaults.length; ++i) {
            // Retrieve the vault's current cumulative SIR per unit of TEA
            uint176 cumSIRPerTEAx96 = cumulativeSIRPerTEA(
                systemParams_,
                vaultIssuanceParams[oldVaults[i]],
                totalSupply(oldVaults[i])
            );

            // Update vault issuance parameters
            vaultIssuanceParams[oldVaults[i]] = VaultStructs.VaultIssuanceParams({
                tax: 0, // Nul tax, and consequently nul SIR issuance
                tsLastUpdate: uint40(block.timestamp),
                cumSIRPerTEAx96: cumSIRPerTEAx96
            });
        }

        // Start new issuances
        for (uint256 i = 0; i < newVaults.length; ++i) {
            // Retrieve the vault's current cumulative SIR per unit of TEA
            uint176 cumSIRPerTEAx96 = cumulativeSIRPerTEA(
                systemParams_,
                vaultIssuanceParams[newVaults[i]],
                totalSupply(newVaults[i])
            );

            // Update vault issuance parameters
            vaultIssuanceParams[newVaults[i]] = VaultStructs.VaultIssuanceParams({
                tax: newTaxes[i],
                tsLastUpdate: uint40(block.timestamp),
                cumSIRPerTEAx96: cumSIRPerTEAx96
            });
        }

        // Update cumulative taxes
        systemParams.cumTax = cumTax;
    }
}
