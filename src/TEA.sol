// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {TEAExternal} from "./libraries/TEAExternal.sol";
import {VaultStructs} from "./libraries/VaultStructs.sol";
import {VaultExternal} from "./libraries/VaultExternal.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {Fees} from "./libraries/Fees.sol";

// Contracts
import {ERC1155, ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {SystemState} from "./SystemState.sol";

abstract contract TEA is SystemState, ERC1155 {
    VaultStructs.Parameters[] public paramsById; // Never used in Vault.sol. Just for users to access vault parameters by vault ID.

    mapping(uint256 vaultId => uint256) public totalSupply;

    constructor(address systemControl, address sir) SystemState(systemControl, sir) {}

    function uri(uint256 vaultId) public view override returns (string memory) {
        return VaultExternal.teaURI(paramsById, vaultId, totalSupply[vaultId]);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 vaultId,
        uint256 amount,
        bytes calldata data
    ) public override {
        // Update SIR issuances
        updateLPerIssuanceParams(false, vaultId, from, to);

        TEAExternal.safeTransferFrom(balanceOf, isApprovedForAll, from, to, vaultId, amount, data);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata vaultIds,
        uint256[] calldata amounts,
        bytes calldata data
    ) public override {
        for (uint256 i = 0; i < vaultIds.length; ) {
            // Update SIR issuances
            updateLPerIssuanceParams(false, vaultIds[i], from, to);

            // An array can't have a total length
            // larger than the max uint256 value.
            unchecked {
                ++i;
            }
        }

        TEAExternal.safeBatchTransferFrom(balanceOf, isApprovedForAll, from, to, vaultIds, amounts, data);
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
            uint256 supplyTEA = totalSupply[vaultId];
            uint256 balanceTo = balanceOf[to][vaultId];
            uint256 balanceVault;
            if (to != address(this)) balanceVault = balanceOf[address(this)][vaultId];

            // Update SIR issuance
            updateLPerIssuanceParams(
                false,
                vaultId,
                systemParams_,
                vaultIssuanceParams_,
                supplyTEA,
                to,
                balanceTo,
                to == address(this) ? address(0) : address(this), // We only need to update 1 address when it's POL only mint
                balanceVault
            );

            uint152 collateralIn;
            if (to != address(this)) {
                // Substract fees and distribute them across treasury, LPers and POL
                (supplyTEA, collateralIn) = _distributeFees(
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
            balanceOf[to][vaultId] = balanceTo + amount;
            supplyTEA += amount;
            reserves.lpReserve += collateralIn;
            emit TransferSingle(msg.sender, address(0), to, vaultId, amount);

            // Update total supply
            require(supplyTEA <= TEA_MAX_SUPPLY, "OF"); // Check for overflow
            totalSupply[vaultId] = supplyTEA;

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
        uint256 supplyTEA = totalSupply[vaultId];
        uint256 balanceFrom = balanceOf[from][vaultId];
        uint256 balanceVault = balanceOf[address(this)][vaultId];

        // Update SIR issuance
        updateLPerIssuanceParams(
            false,
            vaultId,
            systemParams_,
            vaultIssuanceParams_,
            supplyTEA,
            from,
            balanceFrom,
            address(this),
            balanceVault
        );

        // Burn TEA
        uint152 collateralOut = uint152(FullMath.mulDiv(reserves.lpReserve, amount, supplyTEA)); // Compute amount of collateral
        balanceOf[from][vaultId] = balanceFrom - amount; // Checks for underflow
        unchecked {
            supplyTEA -= amount;
            reserves.lpReserve -= collateralOut;
            emit TransferSingle(msg.sender, from, address(0), vaultId, amount);

            // Substract fees and distribute them across treasury, LPers and POL
            (supplyTEA, collateralWidthdrawn) = _distributeFees(
                vaultId,
                balanceVault,
                systemParams_.lpFee,
                vaultIssuanceParams_.tax,
                reserves,
                supplyTEA,
                collateralOut
            );

            // Update
            require(supplyTEA <= TEA_MAX_SUPPLY, "OF"); // Checks for overflow
            totalSupply[vaultId] = supplyTEA;
        }
    }

    function _distributeFees(
        uint40 vaultId,
        uint256 balanceVault,
        uint8 lpFee,
        uint8 tax,
        VaultStructs.Reserves memory reserves,
        uint256 supplyTEA,
        uint152 collateralDepositedOrOut
    ) private returns (uint256 newSupplyTEA, uint152 collateralInOrWidthdrawn) {
        unchecked {
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
            uint256 amountPOL = supplyTEA == 0 // By design lpReserve can never be 0 unless it is the first mint ever
                ? polFee + reserves.lpReserve // Any ownless LP reserve is minted as POL too
                : FullMath.mulDiv(supplyTEA, polFee, reserves.lpReserve);
            balanceOf[address(this)][vaultId] = balanceVault + amountPOL;
            newSupplyTEA += amountPOL;
            reserves.lpReserve += polFee;
            emit TransferSingle(msg.sender, address(0), address(this), vaultId, amountPOL);
        }
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM STATE VIRTUAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function claimSIR(uint256 vaultId, address lper) external override returns (uint80) {
        require(msg.sender == sir);

        return
            updateLPerIssuanceParams(
                true,
                vaultId,
                systemParams,
                totalSupply[vaultId],
                lper,
                balanceOf[lper][vaultId],
                address(0),
                0
            );
    }

    function unclaimedRewards(uint256 vaultId, address lper) external view override returns (uint80) {
        return
            unclaimedRewards(
                vaultId,
                lper,
                balanceOf[lper][vaultId],
                cumulativeSIRPerTEA(systemParams, _vaultsIssuanceParams[vaultId], totalSupply[vaultId])
            );
    }

    function cumulativeSIRPerTEA(uint256 vaultId) external view override returns (uint176 cumSIRPerTEAx96) {
        return cumulativeSIRPerTEA(vaultId, systemParams, _vaultsIssuanceParams[vaultId], totalSupply[vaultId]);
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
                oldVaults[i],
                systemParams_,
                _vaultsIssuanceParams[oldVaults[i]],
                totalSupply[oldVaults[i]]
            );

            // Update vault issuance parameters
            _vaultsIssuanceParams[oldVaults[i]] = VaultStructs.VaultIssuanceParams({
                tax: 0, // Nul tax, and consequently nul SIR issuance
                tsLastUpdate: uint40(block.timestamp),
                cumSIRPerTEAx96: cumSIRPerTEAx96
            });
        }

        // Start new issuances
        for (uint256 i = 0; i < newVaults.length; ++i) {
            // Retrieve the vault's current cumulative SIR per unit of TEA
            uint176 cumSIRPerTEAx96 = cumulativeSIRPerTEA(
                newVaults[i],
                systemParams_,
                _vaultsIssuanceParams[newVaults[i]],
                totalSupply[newVaults[i]]
            );

            // Update vault issuance parameters
            _vaultsIssuanceParams[newVaults[i]] = VaultStructs.VaultIssuanceParams({
                tax: newTaxes[i],
                tsLastUpdate: uint40(block.timestamp),
                cumSIRPerTEAx96: cumSIRPerTEAx96
            });
        }

        // Update cumulative taxes
        systemParams.cumTax = cumTax;
    }
}
