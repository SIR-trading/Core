// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Interfaces
import "uniswap-v2-core/interfaces/IERC20.sol";
import "./interfaces/IPoolLogic.sol";

// Libraries
import "./libraries/FloatingPoint.sol"; 
import "./libraries/TokenNaming.sol";
import "./libraries/ResettableBalancesBytes16.sol";
// import "./test/TestFloatingPoint.sol";

/**
    @notice MAAM is liquidity providers' token in the SIR protocol. It is also a rebasing token.
    The rebasing mechanism is not just a cosmetic feature but necessary for its function. Otherwise its totalSupply() would be unbounded
    due to the price fluctuations of the leverage + liquidations.
    @notice Highly modified from Solmate (https://github.com/Rari-Capital/solmate/blob/main/src/tokens/ERC20.sol)
    @dev Floating point operations on balances (_nonRebasingBalances) round down (to zero)
    Floating point operations on the total supply (nonRebasingSupply) round up (to positive infinity)
    For this reason, the sum of all internal floating-point balances may not be equal to the floating-poin supply (nonRebasingSupply),
    specially when the balances and supply in normal integer numbers occupy more than 113 bits (the accuracy of FP) 
 */
abstract contract MAAM {
    using ResettableBalancesBytes16 for ResettableBalancesBytes16.ResettableBalances;
    using FloatingPoint for bytes16;

    /*///////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Approval(address indexed owner, address indexed spender, uint256 amount);

    event Liquidation(uint256 amount);

    event MintProtocolOwnedLiquidity(uint256 amount);

    /*///////////////////////////////////////////////////////////////
                             METADATA STORAGE
    //////////////////////////////////////////////////////////////*/

    IPoolLogic internal immutable POOL_LOGIC;

    string public name;

    string public symbol;

    uint8 public immutable decimals;

    /*///////////////////////////////////////////////////////////////
                              ERC20 STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address => mapping(address => uint256)) public allowance;

    /*///////////////////////////////////////////////////////////////
                           EIP-2612 STORAGE
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 private immutable _INITIAL_CHAIN_ID;

    bytes32 private immutable _INITIAL_DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    /*///////////////////////////////////////////////////////////////
                            REBASING STORAGE
    //////////////////////////////////////////////////////////////*/

    ResettableBalancesBytes16.ResettableBalances private _nonRebasingBalances;

    /**
     *  @notice MAAM is a rebasing token so the holder's balances change over time.
     *  @notice Internally, balances are still stored as a fixed floating point number.
     *  @return the internal floating point token supply.
     */
    bytes16 public nonRebasingSupply;

    /*///////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address collateralToken, address poolLogic) {
        name = "Liquidity Provider Token of SIR";
        symbol = TokenNaming._generateSymbol("MAAM", address(this));
        decimals = IERC20(collateralToken).decimals();

        POOL_LOGIC = IPoolLogic(poolLogic);

        _INITIAL_CHAIN_ID = block.chainid;
        _INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    /*///////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

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

        _transfer(from, to, amount);

        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);

        return true;
    }

    // Very useful function for tokens that rebase on every block
    function transferAll(address to) public returns (bool) {
        require(to != address(0), "ERC20: transfer to the zero address");

        // User balance
        bytes16 nonRebasingBalance = _nonRebasingBalances.get(msg.sender);

        // Update SIR issuances
        bytes16 nonRebasingSupplyExcludePOL_ = nonRebasingSupplyExcludePOL();
        POOL_LOGIC.updateIssuance(
            msg.sender,
            _nonRebasingBalances.timestampedBalances[msg.sender].balance,
            nonRebasingBalance,
            nonRebasingSupplyExcludePOL_
        );
        POOL_LOGIC.updateIssuance(
            to,
            _nonRebasingBalances.timestampedBalances[to].balance,
            _nonRebasingBalances.get(to),
            nonRebasingSupplyExcludePOL_
        );

        // Mint POL or liquidate if necessary
        uint256 totalSupply_ = totalSupply();
        _fixSupplyDivergence(totalSupply_);

        // Update MAAM balances
        _nonRebasingBalances.decrease(msg.sender, nonRebasingBalance);
        _nonRebasingBalances.increase(to, nonRebasingBalance);

        emit Transfer(
            msg.sender,
            to,
            nonRebasingBalance == FloatingPoint.ZERO ? 0 : nonRebasingBalance.mulDiv(totalSupply_, nonRebasingSupply) // Division by 0 not possible because nonRebasingSupply>nonRebasingBalance
        );
        return true;
    }

    function _mint(
        address account,
        uint256 amount,
        uint256 totalSupply_
    ) internal {
        // Update SIR issuance
        bytes16 nonRebasingSupplyExcludePOL_ = nonRebasingSupplyExcludePOL();
        POOL_LOGIC.updateIssuance(
            account,
            _nonRebasingBalances.timestampedBalances[account].balance,
            _nonRebasingBalances.get(account),
            nonRebasingSupplyExcludePOL_
        );

        // Mint POL or liquidate if necessary
        _fixSupplyDivergence(totalSupply_);

        if (totalSupply_ == 0) {
            // Update balance
            _nonRebasingBalances.increase(account, FloatingPoint.fromUInt(amount));

            // Update supply
            nonRebasingSupply = nonRebasingSupply.addUp(FloatingPoint.fromUIntUp(amount));
        } else {
            // Update balance
            _nonRebasingBalances.increase(account, nonRebasingSupply.mulDivu(amount, totalSupply_)); // Division by 0 not possible because totalSupply_!=0

            // Update supply
            nonRebasingSupply = nonRebasingSupply.addUp(nonRebasingSupply.mulDivuUp(amount, totalSupply_));
        }

        emit Transfer(address(0), account, amount);
    }

    function _burn(
        address account,
        uint256 amount,
        uint256 totalSupply_
    ) internal {
        require(amount <= totalSupply_, "Insufficient balance");

        // Update SIR issuance
        bytes16 nonRebasingSupplyExcludePOL_ = nonRebasingSupplyExcludePOL();
        POOL_LOGIC.updateIssuance(
            account,
            _nonRebasingBalances.timestampedBalances[account].balance,
            _nonRebasingBalances.get(account),
            nonRebasingSupplyExcludePOL_
        );

        // Mint POL or liquidate if necessary
        _fixSupplyDivergence(totalSupply_);

        if (totalSupply_ != 0) {
            // Update balance
            _nonRebasingBalances.decrease(account, nonRebasingSupply.mulDivuUp(amount, totalSupply_)); // Division by 0 not possible because totalSupply_!=0

            // Update supply
            nonRebasingSupply = nonRebasingSupply.subUp(nonRebasingSupply.mulDivu(amount, totalSupply_));
        }

        emit Transfer(account, address(0), amount);
    }

    /*///////////////////////////////////////////////////////////////
                        WRITE (PRIVATE) FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(to != address(0), "ERC20: transfer to the zero address");

        // Update SIR issuances
        bytes16 nonRebasingSupplyExcludePOL_ = nonRebasingSupplyExcludePOL();
        POOL_LOGIC.updateIssuance(
            from,
            _nonRebasingBalances.timestampedBalances[from].balance,
            _nonRebasingBalances.get(from),
            nonRebasingSupplyExcludePOL_
        );
        POOL_LOGIC.updateIssuance(
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
            _nonRebasingBalances.decrease(from, nonRebasingSupply.mulDivuUp(amount, totalSupply_)); // Division by 0 not possible because totalSupply_!=0
            _nonRebasingBalances.increase(to, nonRebasingSupply.mulDivu(amount, totalSupply_));
        }

        emit Transfer(from, to, amount);
    }

    function _fixSupplyDivergence(uint256 totalSupply_) private {
        if (nonRebasingSupply == FloatingPoint.ZERO && totalSupply_ > 0)
            // Mint POL
            _nonRebasingBalances.increase(address(this), FloatingPoint.fromUInt(totalSupply_));
        else if (nonRebasingSupply != FloatingPoint.ZERO && totalSupply_ == 0) {
            // Liquidate
            POOL_LOGIC.haultLPersIssuances(nonRebasingSupply.subUp(_nonRebasingBalances.get(address(this))));
            nonRebasingSupply = FloatingPoint.ZERO;
            _nonRebasingBalances.reset();
            emit Liquidation(totalSupply_);
        }
    }

    /*///////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    function totalSupply() public view virtual returns (uint256);

    function nonRebasingSupplyExcludePOL() public view returns (bytes16) {
        return nonRebasingSupply.subUp(_nonRebasingBalances.get(address(this)));
    }

    function balanceOf(address account) public view returns (uint256) {
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

    function parametersForSIRContract(address account)
        external
        view
        returns (
            bytes16,
            bytes16,
            bytes16
        )
    {
        return (
            _nonRebasingBalances.timestampedBalances[account].balance,
            _nonRebasingBalances.get(account),
            nonRebasingSupplyExcludePOL()
        );
    }

    /**
        @return number of times MAAM has been liquidated 
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
