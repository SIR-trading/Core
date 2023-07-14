// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Libraries
import {FloatingPoint} from "./libraries/FloatingPoint.sol";
import {ResettableBalancesBytes16} from "./libraries/ResettableBalancesBytes16.sol";

// Contracts
import {VaultLogic} from "./VaultLogic.sol";

/**
 * @notice MAAM is liquidity providers' token in the SIR protocol. It is also a rebasing token.
 * The rebasing mechanism is not just a cosmetic feature but necessary for its function. Otherwise its totalSupply() would be unbounded
 * due to the price fluctuations of the leverage + liquidations.
 * @notice Highly modified from Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC1155.sol)
 * @dev Floating point operations on balances (_nonRebasingBalances) round down (to zero)
 * Floating point operations on the total supply (nonRebasingSupply) round up (to positive infinity)
 * For this reason, the sum of all internal floating-point balances may not be equal to the floating-poin supply (nonRebasingSupply),
 * specially when the balances and supply in normal integer numbers occupy more than 113 bits (the accuracy of quadruple precision IEEE 754)
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
abstract contract MAAM {
    using ResettableBalancesBytes16 for ResettableBalancesBytes16.ResettableBalances;
    using FloatingPoint for bytes16;

    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 vaultId,
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
    event URI(string value, uint256 indexed vaultId);
    event Liquidation(uint256 indexed vaultId, uint256 amount);
    event MintPOL(uint256 indexed vaultId, uint256 amount);

    VaultLogic internal immutable _VAULT_LOGIC;

    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /**
     *  @notice MAAM is a rebasing token so the holder's balances change over time.
     *  @notice Internally, balances are still stored as a fixed floating point number.
     *  @return the internal floating point token supply.
     */
    mapping(uint256 vaultId => ResettableBalancesBytes16.ResettableBalances) private _nonRebasingBalances;

    /*///////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    constructor() {
        _VAULT_LOGIC = VaultLogic(vaultLogic);
    }

    function setApprovalForAll(address operator, bool approved) public virtual {
        isApprovedForAll[msg.sender][operator] = approved;

        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 vaultId,
        uint256 amount,
        bytes calldata data
    ) public virtual {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        // Update SIR issuances
        _VAULT_LOGIC.updateIssuances(vaultId, _nonRebasingBalances[vaultId], [from, to]);

        // Transfer
        _nonRebasingBalances[vaultId].transfer(from, to, amount, totalSupply(vaultId));

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
    ) public virtual {
        require(vaultIds.length == amounts.length, "LENGTH_MISMATCH");

        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        // Storing these outside the loop saves ~15 gas per iteration.
        uint256 vaultId;
        uint256 amount;

        for (uint256 i = 0; i < vaultIds.length; ) {
            vaultId = vaultIds[i];
            amount = amounts[i];

            // Update SIR issuances
            _VAULT_LOGIC.updateIssuances(vaultId, _nonRebasingBalances[vaultId], [from, to]);

            // Transfer
            _nonRebasingBalances[vaultId].transfer(from, to, amount, totalSupply(vaultId));

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

    function safeTransferAllFrom(address from, address to, uint256 vaultId, bytes calldata data) public virtual {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        // Update SIR issuances
        _VAULT_LOGIC.updateIssuances(vaultId, _nonRebasingBalances[vaultId], [from, to]);

        // Transfer
        bytes16 nonRebasingAmount = _nonRebasingBalances[vaultId].transferAll(from, to);
        uint amount = nonRebasingAmount.mulDiv(totalSupply(vaultId), _nonRebasingBalances[vaultId].nonRebasingSupply);

        emit TransferSingle(msg.sender, from, to, vaultId, amount);

        require(
            to.code.length == 0
                ? to != address(0)
                : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, vaultId, amount, data) ==
                    ERC1155TokenReceiver.onERC1155Received.selector,
            "UNSAFE_RECIPIENT"
        );
    }

    function balanceOfBatch(
        address[] calldata owners,
        uint256[] calldata vaultIds
    ) public view virtual returns (uint256[] memory balances) {
        require(owners.length == vaultIds.length, "LENGTH_MISMATCH");

        balances = new uint256[](owners.length);

        // Unchecked because the only math done is incrementing
        // the array index counter which cannot possibly overflow.
        unchecked {
            for (uint256 i = 0; i < owners.length; ++i) {
                balances[i] = balanceOf[owners[i]][vaultIds[i]];
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ERC165 LOGIC
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165 Interface ID for ERC165
            interfaceId == 0xd9b67a26 || // ERC165 Interface ID for ERC1155
            interfaceId == 0x0e89341c; // ERC165 Interface ID for ERC1155MetadataURI
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(address to, uint256 vaultId, uint256 amount, uint256 totalSupply_) internal virtual {
        // Update SIR issuance
        _VAULT_LOGIC.updateIssuances(vaultId, _nonRebasingBalances[vaultId], [account]);

        // Mint and liquidate previous LPers if totalSupply_ is 0
        (bool lpersLiquidated, bool mintedPOL) = _nonRebasingBalances[vaultId].mint(account, amount, totalSupply_);
        if (lpersLiquidated) {
            _VAULT_LOGIC.haultIssuance(vaultId);
            emit Liquidation(vaultId, totalSupply_);
        } else if (mintedPOL) {
            emit MintPOL(vaultId, totalSupply_);
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

    function _burn(address from, uint256 vaultId, uint256 amount, uint256 totalSupply_) internal virtual {
        // Update SIR issuance
        _VAULT_LOGIC.updateIssuances(vaultId, _nonRebasingBalances[vaultId], [account]);

        // Burn
        _nonRebasingBalances[vaultId].burn(account, amount, totalSupply_);

        emit TransferSingle(msg.sender, from, address(0), vaultId, amount);
    }

    /*///////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /**
     *  @dev To be implemented in Vault.sol. Use a JSON data URI to customize the metadata for each vaultId
     */
    function uri(uint256 vaultId) public view virtual returns (string memory);

    function totalSupply(uint256 vaultId) public view virtual returns (uint256);

    function balanceOf(address account, uint256 vaultId) public view returns (uint256) {
        bytes16 nonRebasingBalance = _nonRebasingBalances[vaultId].getBalance(account);
        assert(nonRebasingBalance.cmp(_nonRebasingBalances[vaultId].nonRebasingSupply) <= 0);

        if (_nonRebasingBalances[vaultId].nonRebasingSupply == FloatingPoint.ZERO) return 0;
        return nonRebasingBalance.mulDiv(totalSupply(vaultId), _nonRebasingBalances[vaultId].nonRebasingSupply);
    }

    /**
     *  @notice MAAM is a rebasing token so the holder's balances change over time.
     *  @notice Internally, balances are still stored as a fixed floating point number.
     *  @return the internal floating point balance.
     */
    function nonRebasingBalanceOf(address account, uint256 vaultId) external view returns (bytes16) {
        bytes16 nonRebasingBalance = _nonRebasingBalances[vaultId].getBalance(account);
        assert(nonRebasingBalance.cmp(_nonRebasingBalances[vaultId].nonRebasingSupply) <= 0);
        return nonRebasingBalance;
    }

    /**
     * @return number of times MAAM has been liquidated
     */
    function numberOfLiquidations(uint256 vaultId) external view returns (uint216) {
        return _nonRebasingBalances[vaultId].numLiquidations;
    }
}

/// @notice A generic interface for a contract which properly accepts ERC1155 tokens.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC1155.sol)
abstract contract ERC1155TokenReceiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external virtual returns (bytes4) {
        return ERC1155TokenReceiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external virtual returns (bytes4) {
        return ERC1155TokenReceiver.onERC1155BatchReceived.selector;
    }
}
