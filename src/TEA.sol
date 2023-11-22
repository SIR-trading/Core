// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {TEAExternal} from "./libraries/TEAExternal.sol";

// Contracts
import {SystemCommons} from "./SystemCommons.sol";
import {IVaultExternal} from "./interfaces/IVaultExternal.sol";
import {ERC1155, ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import "forge-std/Test.sol";

abstract contract TEA is ERC1155, SystemCommons {
    IVaultExternal internal immutable VAULT_EXTERNAL;

    mapping(uint256 vaultId => uint256) public totalSupply;

    constructor(address systemControl, address vaultExternal) SystemCommons(systemControl) {
        VAULT_EXTERNAL = IVaultExternal(vaultExternal);
    }

    function uri(uint256 vaultId) public view override returns (string memory) {
        return VAULT_EXTERNAL.teaURI(vaultId, totalSupply[vaultId]);
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

    function mint(address to, uint256 vaultId, uint256 amount) internal {
        unchecked {
            // Update SIR issuance
            updateLPerIssuanceParams(false, vaultId, to, address(0));

            // Mint
            uint256 totalSupply_ = totalSupply[vaultId];
            uint256 totalSupplyPlusAmount = totalSupply_ + amount;
            require(totalSupplyPlusAmount >= totalSupply_ && totalSupplyPlusAmount <= TEA_MAX_SUPPLY, "OF");

            totalSupply[vaultId] = totalSupplyPlusAmount;
            balanceOf[to][vaultId] += amount;

            emit TransferSingle(msg.sender, address(0), to, vaultId, amount);

            require(
                to.code.length == 0
                    ? to != address(0)
                    : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, address(0), vaultId, amount, "") ==
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
                            VIRTUAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function updateLPerIssuanceParams(
        bool sirIsCaller,
        uint256 vaultId,
        address lper0,
        address lper1
    ) internal virtual returns (uint80 unclaimedRewards);
}
