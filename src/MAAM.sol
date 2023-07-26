// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Contracts
import {SystemState} from "./SystemState.sol";

/**
 * @dev Metadata description for ERC-1155 can be bound at https://eips.ethereum.org/EIPS/eip-1155
 * @dev uri(_id) returns the metadata URI for the token type _id, .e.g,
 {
    "description": "Description of MAAM token",
	"name": "Super Saiya-jin token",
	"symbol": "MAAM",
	"decimals": 18,
	"chainId": 1
}
 */
abstract contract MAAM is ERC1155 {
    SystemState internal immutable systemState;

    mapping(uint256 vaultId => uint256) public totalSupply;

    constructor(address systemState_) {
        systemState = SystemState(systemState_);
    }

    function uri(uint256 id) public view override returns (string memory) {}

    function safeTransferFrom(
        address from,
        address to,
        uint256 vaultId,
        uint256 amount,
        bytes calldata data
    ) public override {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        // Update SIR issuances
        systemState.updateIssuances(vaultId, balanceOf, [from, to]);

        // Transfer
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;

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
    ) public override {
        require(vaultIds.length == amounts.length, "LENGTH_MISMATCH");

        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        // Storing these outside the loop saves ~15 gas per iteration.
        uint256 vaultId;
        uint256 amount;

        for (uint256 i = 0; i < vaultIds.length; ) {
            vaultId = vaultIds[i];
            amount = amounts[i];

            // Update SIR issuances
            systemState.updateIssuances(vaultId, balanceOf[vaultId], [from, to]);

            // Transfer
            balanceOf[from][id] -= amount;
            balanceOf[to][id] += amount;

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

    function _mint(address to, uint256 vaultId, uint256 amount) internal {
        // Update SIR issuance
        systemState.updateIssuances(vaultId, balanceOf, [account]);

        // Mint
        totalSupply[vaultId] += amount;
        unchecked {
            balanceOf[to][vaultId] += amount;
        }

        emit TransferSingle(msg.sender, address(0), to, vaultId, amount);

        require(
            to.code.length == 0
                ? to != address(0)
                : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, address(0), vaultId, amount, "") ==
                    ERC1155TokenReceiver.onERC1155Received.selector,
            "UNSAFE_RECIPIENT"
        );
    }

    function _burn(address from, uint256 vaultId, uint256 amount, uint256 totalSupply_) internal override {
        // Update SIR issuance
        systemState.updateIssuances(vaultId, _nonRebasingBalances[vaultId], [account]);

        // Burn
        totalSupply[vaultId] -= amount;
        unchecked {
            balanceOf[from][id] -= amount;
        }

        emit TransferSingle(msg.sender, from, address(0), vaultId, amount);
    }
}
