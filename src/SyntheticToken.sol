// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Interfaces
import "uniswap-v2-core/interfaces/IERC20.sol";

// Libraries
import "./libraries/FullMath.sol";
import "./libraries/TokenNaming.sol";
import "openzeppelin/utils/Strings.sol";
import "./libraries/ResettableBalancesUInt216.sol";

// Contracts
import "./Owned.sol";

/// @notice Highly modified ERC20 from Solmate (https://github.com/Rari-Capital/solmate/blob/main/src/tokens/IERC20.sol)
abstract contract SyntheticToken is Owned {
    using ResettableBalancesUInt216 for ResettableBalancesUInt216.ResettableBalances;

    address public immutable DEBT_TOKEN;
    address public immutable COLLATERAL_TOKEN;
    int8 public immutable LEVERAGE_TIER;

    /*///////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Approval(address indexed owner, address indexed spender, uint256 amount);

    event Liquidation(uint256 amount);

    /*///////////////////////////////////////////////////////////////
                             METADATA STORAGE
    //////////////////////////////////////////////////////////////*/

    string public name;

    string public symbol;

    uint8 public immutable decimals;

    /*///////////////////////////////////////////////////////////////
                              IERC20 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public totalSupply;

    /**
        @notice SyntheticToken is the base contract of all TEA & APE tokens because logic-wise TEA and APE are identical.
     */
    ResettableBalancesUInt216.ResettableBalances private _balances;

    mapping(address => mapping(address => uint256)) public allowance;

    /*///////////////////////////////////////////////////////////////
                           EIP-2612 STORAGE
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 private immutable INITIAL_CHAIN_ID;

    bytes32 private immutable INITIAL_DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    /*///////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        string memory name_,
        string memory symbolPrefix,
        uint8 decimals_,
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) {
        name = name_;
        symbol = TokenNaming._generateSymbol(symbolPrefix, address(msg.sender));
        decimals = decimals_;

        DEBT_TOKEN = debtToken;
        COLLATERAL_TOKEN = collateralToken;
        LEVERAGE_TIER = leverageTier;

        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    /*///////////////////////////////////////////////////////////////
                              IERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances.get(account);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances.decrease(msg.sender, amount);
        _balances.increase(to, amount);

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }

        _balances.decrease(from, amount);
        _balances.increase(to, amount);

        emit Transfer(from, to, amount);

        return true;
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
    ) external {
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
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : _computeDomainSeparator();
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

    /*///////////////////////////////////////////////////////////////
                       MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function mint(address to, uint256 amount) external onlyOwner {
        totalSupply += amount;

        // Cannot overflow because the sum of all user balances can't exceed the max uint256 value.
        _balances.increase(to, amount);

        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _balances.decrease(from, amount);

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }

    /**
        @notice It resets all balances to 0
     */
    function liquidate() external onlyOwner {
        if (totalSupply == 0) return;

        _balances.reset();

        emit Liquidation(totalSupply);
        totalSupply = 0;
    }

    /**
     *  @notice All holders could potentially be liquidated.
     *  @return true if all balances and the token supply are 0
     */
    function isLiquidated() external view returns (bool) {
        return totalSupply == 0;
    }

    /**
        @return number of times MAAM has been liquidated 
     */
    function numberOfLiquidations() public view returns (uint216) {
        return _balances.numLiquidations;
    }
}
