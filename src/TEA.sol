// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {Strings} from "openzeppelin/utils/Strings.sol";

// Contracts
import {ERC1155, ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";

abstract contract TEA is ERC1155 {
    mapping(uint256 vaultId => uint256) public totalSupply;

    function uri(uint256 vaultId) public view override returns (string memory) {
        string memory vaultIdStr = Strings.toString(vaultId);
        (address debtToken, address collateralToken, int8 leverageTier) = paramsById(vaultId);
        return
            string.concat(
                "data:application/json;charset=UTF-8,%7B%22name%22%3A%22LP%20Token%20for%20APE",
                vaultIdStr,
                "%22%2C%22symbol%22%3A%22TEA-",
                vaultIdStr,
                "%22%2C%22decimals%22%3A",
                Strings.toString(IERC20(collateralToken).decimals()),
                "%2C%22chainId%22%3A1%2C%22debtToken%22%3A%22",
                Strings.toHexString(debtToken),
                "%22%2C%22collateralToken%22%3A%22",
                Strings.toHexString(collateralToken),
                "%22%2C%22leverageTier%22%3A",
                Strings.toString(leverageTier),
                "%7D"
            );
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 vaultId,
        uint256 amount,
        bytes calldata data
    ) public override {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        // Update SIR issuances
        _updateLPerIssuanceParams(vaultId, from, to, false);

        // Transfer
        balanceOf[from][vaultId] -= amount;
        balanceOf[to][vaultId] += amount;

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
            _updateLPerIssuanceParams(vaultId, from, to, false);

            // Transfer
            balanceOf[from][vaultId] -= amount;
            balanceOf[to][vaultId] += amount;

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
        _updateLPerIssuanceParams(vaultId, to, address(0), false);

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

    function _burn(address from, uint256 vaultId, uint256 amount) internal override {
        // Update SIR issuance
        _updateLPerIssuanceParams(vaultId, from, address(0), false);

        // Burn
        totalSupply[vaultId] -= amount;
        unchecked {
            balanceOf[from][vaultId] -= amount;
        }

        emit TransferSingle(msg.sender, from, address(0), vaultId, amount);
    }

    /*////////////////////////////////////////////////////////////////
                            VIRTUAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _updateLPerIssuanceParams(
        uint256 vaultId,
        address lper0,
        address lper1,
        bool sirIsCaller
    ) internal virtual returns (uint104 unclaimedRewards);

    function paramsById(
        uint256 vaultId
    ) public view virtual returns (address debtToken, address collateralToken, int8 leverageTier);
}
