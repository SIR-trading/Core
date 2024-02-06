// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {SystemConstants} from "./libraries/SystemConstants.sol";
import {Vault} from "./Vault.sol";

/** @notice Solmate mod
    @dev SIR supply is designed to fit in a 80-bit unsigned integer.
    @dev ETH supply is 120.2M approximately with 18 decimals, which fits in a 88-bit unsigned integer.
    @dev With 96 bits, we can represent 79,2B ETH, which is 659 times more than the current supply. 
 */
abstract contract ERC20 {
    error UnclaimedRewardsOverflow();
    error NewAuctionCannotStartYet();
    error TokensAlreadyClaimed();
    error AuctionIsNotOver();

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    Vault internal immutable VAULT;

    string public name = "Sustainable Investing Returns";
    string public symbol = "SIR";
    uint8 public immutable decimals = SystemConstants.SIR_DECIMALS;

    struct ParamsSection1 {
        uint80 stake; // Amount of staked SIR
        uint176 cumETHPerSIRx80; // Cumulative ETH per SIR * 2^80
    }

    struct ParamsSection2 {
        uint80 balance; // Amount of transferable SIR
        uint96 unclaimedWETH; // Amount of WETH owed to the staker(s)
    }

    struct Params {
        ParamsSection1 section1;
        ParamsSection2 section2;
    }

    // struct Params {
    //     uint80 stake; // Amount of staked SIR
    //     uint176 cumETHPerSIRx80; // Cumulative ETH per SIR * 2^80
    //     uint80 balance; // Amount of transferable SIR
    //     uint96 unclaimedWETH; // Amount of WETH owed to the staker(s)
    // }

    struct AuctionByToken {
        uint96 bestBid;
        address bestBidder;
        uint40 startTime; // Auction start time
        bool winnerPaid; // Whether the winner has been paid
    }

    Params internal params;

    mapping(address => AuctionByToken) public auctions;
    mapping(address => Params) internal usersParams;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 internal immutable INITIAL_CHAIN_ID;
    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    constructor(address vault) {
        VAULT = Vault(vault);

        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    // Return transferable SIR
    function balanceOf(address account) external view returns (uint256) {
        return usersParams[account].balance;
    }

    function totalBalanceOf(address account) external view returns (uint256) {
        Params memory accountParams = usersParams[account];
        return accountParams.stake + accountParams.balance;
    }

    function circulatingSupply() external view returns (uint256) {
        return params.balance;
    }

    function totalSupply() external view returns (uint256) {
        Params memory params_ = params;
        return params_.stake + params_.balance;
    }

    function maxTotalSupply() external view returns (uint256) {
        (uint40 tsIssuanceStart, , , , ) = VAULT.systemParams();

        if (tsIssuanceStart == 0) return 0;
        return SystemConstants.ISSUANCE * (block.timestamp - tsIssuanceStart);
    }

    /*//////////////////////////////////////////////////////////////
                               ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(amount <= type(uint80).max);
        usersParams[msg.sender].balance -= uint80(amount);

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint80 value.
        unchecked {
            usersParams[to].balance += uint80(amount);
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        require(amount <= type(uint80).max);
        usersParams[from].balance -= uint80(amount);

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint80 value.
        unchecked {
            usersParams[to].balance += uint80(amount);
        }

        emit Transfer(from, to, amount);

        return true;
    }

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
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    function computeDomainSeparator() internal view returns (bytes32) {
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

    function _mint(address to, uint256 amount) internal {
        assert(params.balance + params.stake + amount <= type(uint80).max);

        unchecked {
            params.balance += uint80(amount);
            usersParams[to].balance += uint80(amount);
        }

        emit Transfer(address(0), to, amount);
    }

    /*////////////////////////////////////////////////////////////////
                            STAKING FUNCTIONS 
    ////////////////////////////////////////////////////////////////*/

    function unstake(uint80 amount) external {
        // Get current unclaimed rewards
        (uint256 rewards_, Params memory userParams, uint176 cumETHPerSIRx80_) = _rewards(msg.sender);
        if (rewards_ > type(uint96).max) revert UnclaimedRewardsOverflow();

        // Update staker info
        usersParams[msg.sender] = Params(uint80(userParams.stake - amount), cumETHPerSIRx80_, uint96(rewards_));

        // Update total stake
        unchecked {
            stakeTotal -= amount; // Cannot underflow because stakeTotal >= stake >= amount
        }

        // DO NOT TRANSFER, JUST CHANGE THE balanceOf variable for the staker and the StakerParams here!!
        transfer(msg.sender, amount);
    }

    function stake() external {
        unchecked {
            // Check increase in SIR stake
            // NO NEED FOR USE TO CALL SIR TRANSFER BECAUSE THIS FUNCTION HAS ACCESS TO ALL SIR VARIABLES!!
            uint256 stakeTotalReal = balanceOf[address(this)];
            uint256 deposit = stakeTotalReal - stakeTotal;

            // Get current unclaimed rewards
            (uint256 rewards_, Params memory userParams, uint176 cumETHPerSIRx80_) = _rewards(msg.sender);
            if (rewards_ > type(uint96).max) revert UnclaimedRewardsOverflow();

            // Update staker info
            usersParams[msg.sender] = Params(uint80(userParams.stake + deposit), cumETHPerSIRx80_, uint96(rewards_));

            // Update total stake
            stakeTotal = uint80(stakeTotalReal);
        }
    }

    function claim() external {
        unchecked {
            (uint256 rewards_, Params memory userParams, ) = _rewards(msg.sender);
            usersParams[msg.sender] = Params(userParams.stake, cumETHPerSIRx80, 0);

            _WETH.transfer(msg.sender, rewards_);
        }
    }

    function rewards(address staker) public view returns (uint256 rewards_) {
        (rewards_, , ) = _rewards(staker);
    }

    function _rewards(address staker) private view returns (uint256, Params memory, uint176) {
        unchecked {
            Params memory userParams = usersParams[staker];
            uint176 cumETHPerSIRx80_ = cumETHPerSIRx80;

            return (
                userParams.unclaimedWETH +
                    ((uint256(cumETHPerSIRx80_ - userParams.cumETHPerSIRx80) * userParams.stake) >> 80),
                userParams,
                cumETHPerSIRx80_
            );
        }
    }

    /*////////////////////////////////////////////////////////////////
                        DIVIDEND PAYING FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    // function bid(address token) external {
    //     AuctionByToken memory auction = auctions[token];

    //     if (block.timestamp >= auction.startTime + SystemConstants.AUCTION_DURATION) revert AuctionIsOver();

    //     if (amount <= auction.bestBid) revert BidTooLow();

    //     // Update auction
    //     auctions[token] = AuctionByToken({
    //         bestBid: amount,
    //         bestBidder: msg.sender,
    //         startTime: auction.startTime,
    //         winnerPaid: false
    //     });

    //     // Transfer the bid to the contract
    //     TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
    // }

    function collectFeesAndStartAuction(address token) external {
        // WETH is the dividend paying token, so we do not start an auction for it.
        if (token != Addresses.ADDR_WETH) {
            AuctionByToken memory auction = auctions[token];

            if (block.timestamp < auction.startTime + SystemConstants.AUCTION_COOLDOWN)
                revert NewAuctionCannotStartYet();

            // Start a new auction
            auctions[token] = AuctionByToken({
                bestBid: 0,
                bestBidder: address(0),
                startTime: uint40(block.timestamp), // This automatically aborts any reentrancy attack
                winnerPaid: false
            });

            /** Pay the previous bidder if he has not been paid yet.
            We considered the bidder paid regardless of the success of the transfer.
         */
            _claimTokens(token, auction);
        }

        // Retrieve fees from the vault. Reverts if no fees are available.
        VAULT.withdrawFees(token);
    }

    function _distributeDividends(uint256 amount) private {
        uint256 dividends = _WETH.balanceOf(address(this));

        // Update cumETHPerSIRx80
        cumETHPerSIRx80 += uint176((dividends << 80) / stakeTotal);
    }

    function claimTokens(address token) external {
        AuctionByToken memory auction = auctions[token];
        if (block.timestamp < auction.startTime + SystemConstants.AUCTION_DURATION) revert AuctionIsNotOver();

        // Update auction
        auctions[token].winnerPaid = true;

        if (!_claimTokens(token, auction)) revert TokensAlreadyClaimed();
    }

    // UPDATE CUMETHPERSIRX80!!!
    function _claimTokens(address token, AuctionByToken memory auction) private returns (bool success) {
        // Bidder already paid
        if (auction.winnerPaid) return false;

        // Only pay if there is a non-0 bid.
        if (auction.bestBid == 0) return false;

        /** Obtain reward amount
            Low-level call to avoid revert if the ERC20 token has some problems.
         */
        bytes memory data;
        (success, data) = tokens[i].call(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));

        // balanceOf failed and we cannot continue
        if (!success || data.length != 32) return false;

        // Prize is 0, so the claim is successful but without a transfer
        uint256 prize = abi.decode(data, (uint256));
        if (prize == 0) return true;

        /** Pay the winner if prize > 0
            Low-level call to avoid revert if the ERC20 token has some problems.
         */
        (success, data) = token.call(abi.encodeWithSelector(ERC20.transfer.selector, auction.bestBidder, prize));

        /** By the ERC20 standard, the transfer may go through without reverting (success == true),
            but if it returns a boolean that is false, the transfer actually failed.
         */
        if (data.length > 0 && !abi.decode(data, (bool))) return false;
    }
}
