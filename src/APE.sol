// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Interfaces
import {IVaultExternal} from "./interfaces/IVaultExternal.sol";

// Libraries
import {Fees} from "./libraries/Fees.sol";
import {FullMath} from "./libraries/FullMath.sol";

// Contracts
import {Owned} from "./Owned.sol";

/**
 * @dev Modified from Solmate's ERC20.sol
 */
contract APE is Owned {
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    address public immutable debtToken;
    address public immutable collateralToken;
    int8 public immutable leverageTier;

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 private immutable INITIAL_CHAIN_ID;
    bytes32 private immutable INITIAL_DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    /*///////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /** @dev CREATE2 deployment allows Vault.sol to compute the APE address (needed by Vault to make external calls)
        without storing it in storage, saving gas. However, because Vault.sol is already at the limit of 24KB,
        we can't import the APE creation code necessary for predicting the CREATE2 address.
        However, CREATE2 uses the hash of the creation code and its parameters to predict the address.
        So if we do not pass any parameters we can just hardcode the hash of the APE creation code which
        only takes 32 bytes.
     */
    constructor() {
        // Set immutable parameters
        (name, symbol, decimals, debtToken, collateralToken, leverageTier) = IVaultExternal(msg.sender)
            .latestTokenParams();

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

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

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
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                                ),
                                owner,
                                spender,
                                value,
                                nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_SIGNER");

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
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }

    /*///////////////////////////////////////////////////////////////
                       MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function mint(
        address to,
        uint16 baseFee,
        uint8 tax,
        uint152 collateralIn,
        uint152 apesReserve
    )
        external
        onlyOwner
        returns (uint152 collateralDAO, uint152 collateralPOL, uint152 collateralFee, uint152 collateralApesReserve)
    {
        // Computes supply and balance of TEA
        uint256 supplyAPE = totalSupply;

        // Substract fee
        (collateralIn, collateralFee) = Fees.hiddenFeeAPE(baseFee, collateralIn, leverageTier);

        uint256 amount;
        unchecked {
            // Compute amount of APE to mint for the user
            collateralPOL = collateralFee / 10;
            amount = supplyAPE == 0 // By design apesReserve can never be 0 unless it is the first mint ever
                ? collateralIn + apesReserve // Any ownless APE reserve is minted by the first ape
                : FullMath.mulDiv(supplyAPE, collateralIn, apesReserve);

            // Compute amount of collateral diverged to the DAO (max 10% of collateralFee)
            collateralDAO = uint152((uint256(collateralFee) * tax) / (10 * type(uint8).max)); // Cannot overflow cuz collateralFee is uint152 and tax is uint8

            collateralApesReserve = collateralIn - collateralDAO;

            // Cannot overflow because the sum of all user
            // balances can't exceed the max uint256 value.
            balanceOf[to] += amount;
        }

        totalSupply = supplyAPE + amount;

        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        balanceOf[from] -= amount;

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }
}
