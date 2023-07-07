// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Interfaces
import {IPoolLogic} from "./interfaces/IPoolLogic.sol";

// Libraries
import {FloatingPoint} from "./libraries/FloatingPoint.sol";
import {TokenNaming} from "./libraries/TokenNaming.sol";
import {ResettableBalancesBytes16} from "./libraries/ResettableBalancesBytes16.sol";

// import "./test/TestFloatingPoint.sol";

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
        uint256 id,
        uint256 amount
    );

    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] amounts
    );

    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event URI(string value, uint256 indexed id);
    event Liquidation(uint256 vaultId, uint256 amount);

    IPoolLogic internal immutable _POOL_LOGIC;

    /**
     * ERC-1155 state
     */

    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /**
     *  @notice MAAM is a rebasing token so the holder's balances change over time.
     *  @notice Internally, balances are still stored as a fixed floating point number.
     *  @return the internal floating point token supply.
     */
    mapping(uint256 id => ResettableBalancesBytes16.ResettableBalances) private _nonRebasingBalances;

    /*///////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /**
     * Constructor
     */
    constructor(address collateralToken, address poolLogic) {
        _POOL_LOGIC = IPoolLogic(poolLogic);
    }

    function setApprovalForAll(address operator, bool approved) public virtual {
        isApprovedForAll[msg.sender][operator] = approved;

        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) public virtual {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        // Update SIR issuances
        _POOL_LOGIC.updateIssuance(id, _nonRebasingBalances[id], [from, to]);

        // Transfer
        _nonRebasingBalances[id].transfer(from, to, amount, totalSupply_);

        emit TransferSingle(msg.sender, from, to, id, amount);

        require(
            to.code.length == 0
                ? to != address(0)
                : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, id, amount, data) ==
                    ERC1155TokenReceiver.onERC1155Received.selector,
            "UNSAFE_RECIPIENT"
        );
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) public virtual {
        require(ids.length == amounts.length, "LENGTH_MISMATCH");

        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        // Storing these outside the loop saves ~15 gas per iteration.
        uint256 id;
        uint256 amount;

        for (uint256 i = 0; i < ids.length; ) {
            id = ids[i];
            amount = amounts[i];

            // Update SIR issuances
            _POOL_LOGIC.updateIssuance(id, _nonRebasingBalances[id], [from, to]);

            // Transfer
            _nonRebasingBalances[id].transfer(from, to, amount, totalSupply_);

            // An array can't have a total length
            // larger than the max uint256 value.
            unchecked {
                ++i;
            }
        }

        emit TransferBatch(msg.sender, from, to, ids, amounts);

        require(
            to.code.length == 0
                ? to != address(0)
                : ERC1155TokenReceiver(to).onERC1155BatchReceived(msg.sender, from, ids, amounts, data) ==
                    ERC1155TokenReceiver.onERC1155BatchReceived.selector,
            "UNSAFE_RECIPIENT"
        );
    }

    function safeTransferAllFrom(address from, address to, uint256 id, bytes calldata data) public virtual {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "NOT_AUTHORIZED");

        // Update SIR issuances
        _POOL_LOGIC.updateIssuance(id, _nonRebasingBalances[id], [from, to]);

        // Transfer
        bytes16 nonRebasingAmount = _nonRebasingBalances[id].transferAll(from, to);
        uint amount = nonRebasingAmount.mulDiv(totalSupply(), _nonRebasingBalances[id].nonRebasingSupply);

        emit TransferSingle(msg.sender, from, to, id, amount);

        require(
            to.code.length == 0
                ? to != address(0)
                : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, id, amount, data) ==
                    ERC1155TokenReceiver.onERC1155Received.selector,
            "UNSAFE_RECIPIENT"
        );
    }

    function balanceOfBatch(
        address[] calldata owners,
        uint256[] calldata ids
    ) public view virtual returns (uint256[] memory balances) {
        require(owners.length == ids.length, "LENGTH_MISMATCH");

        balances = new uint256[](owners.length);

        // Unchecked because the only math done is incrementing
        // the array index counter which cannot possibly overflow.
        unchecked {
            for (uint256 i = 0; i < owners.length; ++i) {
                balances[i] = balanceOf[owners[i]][ids[i]];
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

    function _mint(address to, uint256 id, uint256 amount, bytes memory data) internal virtual {
        // Update SIR issuance
        _POOL_LOGIC.updateIssuance(id, _nonRebasingBalances[id], [account]);

        // Mint and liquidate previous LPers if totalSupply_ is 0
        if (_nonRebasingBalances[id].mint(account, amount, totalSupply_)) {
            _POOL_LOGIC.haultIssuance(id);
            emit Liquidation(id, totalSupply_);
        }

        emit TransferSingle(msg.sender, address(0), to, id, amount);

        require(
            to.code.length == 0
                ? to != address(0)
                : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, address(0), id, amount, data) ==
                    ERC1155TokenReceiver.onERC1155Received.selector,
            "UNSAFE_RECIPIENT"
        );
    }

    function _burn(address from, uint256 id, uint256 amount) internal virtual {
        // Update SIR issuance
        _POOL_LOGIC.updateIssuance(id, _nonRebasingBalances[id], [account]);

        // Burn
        _nonRebasingBalances[id].burn(account, amount, totalSupply_);

        emit TransferSingle(msg.sender, from, address(0), id, amount);
    }

    /*///////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /**
     *  @dev To be implemented in Pool.sol. Use a JSON data URI to customize the metadata for each id
     */
    function uri(uint256 id) public view virtual returns (string memory);

    function totalSupply(uint256 id) public view virtual returns (uint256);

    function balanceOf(address account, uint256 id) public view returns (uint256) {
        bytes16 nonRebasingBalance = _nonRebasingBalances[id].get(account);
        assert(nonRebasingBalance.cmp(_nonRebasingBalances[id].nonRebasingSupply) <= 0);
        return nonRebasingBalance.mulDiv(totalSupply(), _nonRebasingBalances[id].nonRebasingSupply); // Division by 0 not possible because nonRebasingSupply!=0
    }

    /**
     *  @notice MAAM is a rebasing token so the holder's balances change over time.
     *  @notice Internally, balances are still stored as a fixed floating point number.
     *  @return the internal floating point balance.
     */
    function nonRebasingBalanceOf(address account) external view returns (bytes16) {
        bytes16 nonRebasingBalance = _nonRebasingBalances[id].get(account);
        assert(nonRebasingBalance.cmp(_nonRebasingBalances[id].nonRebasingSupply) <= 0);
        return nonRebasingBalance;
    }

    /**
     * @return number of times MAAM has been liquidated
     */
    function numberOfLiquidations() external view returns (uint216) {
        return _nonRebasingBalances[id].numLiquidations;
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
