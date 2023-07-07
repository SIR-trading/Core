// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Interfaces
import {IERC20} from "uniswap-v2-core/interfaces/IERC20.sol";
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
    event Liquidation(uint256 amount);
    event MintProtocolOwnedLiquidity(uint256 amount);

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
        bytes16 nonRebasingSupplyExcludePOL_ = nonRebasingSupplyExcludePOL();
        _POOL_LOGIC.updateIssuance(
            id,
            from,
            _nonRebasingBalances.timestampedBalances[from].balance,
            _nonRebasingBalances.get(from),
            nonRebasingSupplyExcludePOL_
        );
        _POOL_LOGIC.updateIssuance(
            id,
            to,
            _nonRebasingBalances.timestampedBalances[to].balance,
            _nonRebasingBalances.get(to),
            nonRebasingSupplyExcludePOL_
        );

        // Mint POL or liquidate if necessary
        uint256 totalSupply_ = totalSupply(id);
        _fixSupplyDivergence(totalSupply_); // PASS id TOO HERE!

        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;

        emit TransferSingle(msg.sender, from, to, id, amount);

        require(
            to.code.length == 0
                ? to != address(0)
                : ERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, id, amount, data) ==
                    ERC1155TokenReceiver.onERC1155Received.selector,
            "UNSAFE_RECIPIENT"
        );
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }

        require(to != address(0), "ERC20: transfer to the zero address");

        // Update SIR issuances
        bytes16 nonRebasingSupplyExcludePOL_ = nonRebasingSupplyExcludePOL();
        _POOL_LOGIC.updateIssuance(
            from,
            _nonRebasingBalances.timestampedBalances[from].balance,
            _nonRebasingBalances.get(from),
            nonRebasingSupplyExcludePOL_
        );
        _POOL_LOGIC.updateIssuance(
            to,
            _nonRebasingBalances.timestampedBalances[to].balance,
            _nonRebasingBalances.get(to),
            nonRebasingSupplyExcludePOL_
        );

        // Mint POL or liquidate if necessary
        uint256 totalSupply_ = totalSupply();
        _fixSupplyDivergence(totalSupply_);

        // Update MAAM balances
        if (totalSupply_ != 0) {
            _nonRebasingBalances.transfer(from, to, amount, totalSupply_);

            emit Transfer(from, to, amount);

            return true;
        }
    }

    // Very useful function for tokens that rebase on every block
    function transferAll(address to) public returns (bool) {
        require(to != address(0), "ERC20: transfer to the zero address");

        // User balance
        bytes16 nonRebasingBalance = _nonRebasingBalances.get(msg.sender);

        // Update SIR issuances
        bytes16 nonRebasingSupplyExcludePOL_ = nonRebasingSupplyExcludePOL();
        _POOL_LOGIC.updateIssuance(
            msg.sender,
            _nonRebasingBalances.timestampedBalances[msg.sender].balance,
            nonRebasingBalance,
            nonRebasingSupplyExcludePOL_
        );
        _POOL_LOGIC.updateIssuance(
            to,
            _nonRebasingBalances.timestampedBalances[to].balance,
            _nonRebasingBalances.get(to),
            nonRebasingSupplyExcludePOL_
        );

        // Mint POL or liquidate if necessary
        uint256 totalSupply_ = totalSupply();
        _fixSupplyDivergence(totalSupply_);

        // Update MAAM balances
        _nonRebasingBalances.transfer(from, to, nonRebasingBalance);

        emit Transfer(
            msg.sender,
            to,
            nonRebasingBalance == FloatingPoint.ZERO ? 0 : nonRebasingBalance.mulDiv(totalSupply_, nonRebasingSupply) // Division by 0 not possible because nonRebasingSupply>nonRebasingBalance
        );
        return true;
    }

    function _mint(address account, uint256 amount, uint256 totalSupply_) internal {
        // Update SIR issuance
        bytes16 nonRebasingSupplyExcludePOL_ = nonRebasingSupplyExcludePOL();
        _POOL_LOGIC.updateIssuance(
            account,
            _nonRebasingBalances.timestampedBalances[account].balance,
            _nonRebasingBalances.get(account),
            nonRebasingSupplyExcludePOL_
        );

        // Mint POL or liquidate if necessary
        _fixSupplyDivergence(totalSupply_);

        _nonRebasingBalances.mint(account, amount, totalSupply_);

        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount, uint256 totalSupply_) internal {
        require(amount <= totalSupply_, "Insufficient balance");

        // Update SIR issuance
        bytes16 nonRebasingSupplyExcludePOL_ = nonRebasingSupplyExcludePOL();
        _POOL_LOGIC.updateIssuance(
            account,
            _nonRebasingBalances.timestampedBalances[account].balance,
            _nonRebasingBalances.get(account),
            nonRebasingSupplyExcludePOL_
        );

        // Mint POL or liquidate if necessary
        _fixSupplyDivergence(totalSupply_);

        _nonRebasingBalances.burn(account, amount, totalSupply_);

        emit Transfer(account, address(0), amount);
    }

    /*///////////////////////////////////////////////////////////////
                        WRITE (PRIVATE) FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    function _fixSupplyDivergence(uint256 totalSupply_) private {
        if (nonRebasingSupply == FloatingPoint.ZERO && totalSupply_ > 0) {
            // Mint POL
            _nonRebasingBalances.mint(address(this), totalSupply_, 0);
        } else if (nonRebasingSupply != FloatingPoint.ZERO && totalSupply_ == 0) {
            // Liquidate
            _POOL_LOGIC.haultLPersIssuances(nonRebasingSupply.subUp(_nonRebasingBalances.get(address(this)))); // THIS IS NOT IN THE LIBRARY
            nonRebasingSupply = FloatingPoint.ZERO;
            _nonRebasingBalances.reset();
            emit Liquidation(totalSupply_);
        }
    }

    /*///////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /**
     *  @dev To be implemented in Pool.sol. Use a JSON data URI to customize the metadata for each id
     */
    function uri(uint256 id) public view virtual returns (string memory);

    function totalSupply(uint256 id) public view virtual returns (uint256);

    function nonRebasingSupplyExcludePOL() public view returns (bytes16) {
        return nonRebasingSupply.subUp(_nonRebasingBalances.get(address(this)));
    }

    function balanceOf(address account, uint256 id) public view returns (uint256) {
        if (nonRebasingSupply == FloatingPoint.ZERO) return 0;

        bytes16 nonRebasingBalance = _nonRebasingBalances.get(account);
        assert(nonRebasingBalance.cmp(nonRebasingSupply) <= 0);
        return nonRebasingBalance.mulDiv(totalSupply(), nonRebasingSupply); // Division by 0 not possible because nonRebasingSupply!=0
    }

    /**
     *  @notice MAAM is a rebasing token so the holder's balances change over time.
     *  @notice Internally, balances are still stored as a fixed floating point number.
     *  @return the internal floating point balance.
     */
    function nonRebasingBalanceOf(address account) external view returns (bytes16) {
        bytes16 nonRebasingBalance = _nonRebasingBalances.get(account);
        assert(nonRebasingBalance.cmp(nonRebasingSupply) <= 0);
        return nonRebasingBalance;
    }

    function parametersForSIRContract(address account) external view returns (bytes16, bytes16, bytes16) {
        return (
            _nonRebasingBalances.timestampedBalances[account].balance,
            _nonRebasingBalances.get(account),
            nonRebasingSupplyExcludePOL()
        );
    }

    /**
     * @return number of times MAAM has been liquidated
     */
    function numberOfLiquidations() external view returns (uint216) {
        return _nonRebasingBalances.numLiquidations;
    }

    /*///////////////////////////////////////////////////////////////
                              EIP-2612 LOGIC
    //////////////////////////////////////////////////////////////*/

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        require(deadline >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            bytes32 digest = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
                )
            );

            address recoveredAddress = ecrecover(digest, v, r, s);
            require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_PERMIT_SIGNATURE");

            allowance[recoveredAddress][spender] = value;
        }

        emit Approval(owner, spender, value);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _INITIAL_CHAIN_ID ? _INITIAL_DOMAIN_SEPARATOR : _computeDomainSeparator();
    }

    function _computeDomainSeparator() private view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(name)),
                    keccak256(bytes("1")),
                    block.chainid,
                    address(this)
                )
            );
    }
}
