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
     */
    function mint(
        address to,
        VaultStructs.State memory state_,
        VaultStructs.SystemParameters memory systemParams_,
        VaultStructs.VaultIssuanceParams memory vaultIssuanceParams_,
        uint152 collateralIn,
        uint152 lpReserve
    ) internal returns (uint152 collateralDAO, uint152 collateralLpReserve) {
        unchecked {
            // Computes supply and balance of TEA
            uint256 supplyTEA = totalSupply[state_.vaultId];
            uint256 balanceTo = balanceOf[to][state_.vaultId];
            uint256 balanceVault;
            if (to != address(this)) balanceVault = balanceOf[address(this)][state_.vaultId];

            // Update SIR issuance
            updateLPerIssuanceParams(
                false,
                state_.vaultId,
                systemParams_,
                vaultIssuanceParams_,
                supplyTEA,
                to,
                balanceTo,
                to == address(this) ? address(0) : address(this), // We only need to update 1 address when it's POL only mint
                balanceVault
            );

            uint256 amount;
            uint256 amountPOL;
            if (to != address(this)) {
                // Substract fee
                uint152 collateralFee;
                (collateralIn, collateralFee) = Fees.hiddenFeeTEA(systemParams_.lpFee, collateralIn, lpReserve);

                // Compute amount of TEA diverted as protocol owned liquidity (POL)
                uint152 collateralPOL = collateralFee / 10;
                uint256 amountPOL = supplyTEA == 0 // By design lpReserve can never be 0 unless it is the first mint ever
                    ? collateralPOL + lpReserve // Any ownless LP reserve is minted as POL too
                    : FullMath.mulDiv(supplyTEA, collateralPOL, lpReserve);

                // Compute amount of collateral diverged to the DAO (max 10% of collateralFee)
                collateralDAO = uint152((uint256(collateralFee) * vaultIssuanceParams_.tax) / (10 * type(uint8).max)); // Cannot overflow cuz collateralFee is uint152 and tax is uint8

                /** Collateral that is desposited into the LP reserve.
                    1. collateralIn is for the minting gentleman
                    2. collateralFee includes a fee for all gentlemen LPing, a fee for POL and a fee to the DAO,
                       only the latter is not part of the LP reserve
                 */
                collateralLpReserve = collateralIn + collateralFee - collateralDAO;
            }

            // Compute amount of TEA to mint
            uint256 amount = supplyTEA == 0 // By design lpReserve can never be 0 unless it is the first mint ever
                ? collateralIn
                : FullMath.mulDiv(supplyTEA, collateralIn, lpReserve);

            // Update supply and balances
            uint256 newSupplyTEA = supplyTEA + amount + amountPOL;
            require(newSupplyTEA >= supplyTEA && newSupplyTEA <= TEA_MAX_SUPPLY, "OF");

            totalSupply[state_.vaultId] = newSupplyTEA;
            balanceOf[to][state_.vaultId] = balanceTo + amount;
            if (to != address(this)) balanceOf[address(this)][state_.vaultId] = balanceVault + amountPOL;

            emit TransferSingle(msg.sender, address(0), to, state_.vaultId, amount);
            if (to != address(this))
                emit TransferSingle(msg.sender, address(0), address(this), state_.vaultId, amountPOL);

            require(
                to.code.length == 0
                    ? to != address(0)
                    : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, address(0), state_.vaultId, amount, "") ==
                        ERC1155TokenReceiver.onERC1155Received.selector,
                "UNSAFE_RECIPIENT"
            );
        }
    }

    function burn(address from, uint256 vaultId, uint256 amount) internal {
        // Update SIR issuance
        updateLPerIssuanceParams(false, vaultId, from, address(0));

        // Burn
        unchecked {
            totalSupply[vaultId] -= amount;
        }
        balanceOf[from][vaultId] -= amount;

        emit TransferSingle(msg.sender, from, address(0), vaultId, amount);
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM STATE VIRTUAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function claimSIR(uint256 vaultId, address lper) external override returns (uint80) {
        require(msg.sender == _SIR);

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
            _unclaimedRewards(
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
            _vaultsIssuanceParams[oldVaults[i]] = VaultIssuanceParams({
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
            _vaultsIssuanceParams[newVaults[i]] = VaultIssuanceParams({
                tax: newTaxes[i],
                tsLastUpdate: uint40(block.timestamp),
                cumSIRPerTEAx96: cumSIRPerTEAx96
            });
        }

        // Update cumulative taxes
        systemParams.cumTax = cumTax;
    }
}
