// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {SystemConstants} from "./libraries/SystemConstants.sol";
import {Vault} from "./Vault.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

import "forge-std/console.sol";

/** @notice Solmate mod
    @dev SIR supply is designed to fit in a 80-bit unsigned integer.
    @dev ETH supply is 120.2M approximately with 18 decimals, which fits in a 88-bit unsigned integer.
    @dev With 96 bits, we can represent 79,2B ETH, which is 659 times more than the current supply. 
 */
contract Staker {
    error NewAuctionCannotStartYet(uint40 startTime);
    error NoTokensAvailable();
    error AuctionIsNotOver();
    error AuctionIsOver();
    error BidTooLow();
    error InvalidSigner();
    error PermitDeadlineExpired();

    event AuctionedTokensSentToWinner(address winner, address token, uint256 reward);
    event DividendsPaid(uint256 amount);
    event BidReceived(address bidder, address token, uint96 previousBid, uint96 newBid);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);

    address immutable deployer; // Just used to make sure function initialize() is not called by anyone else.
    IWETH9 private immutable _WETH;
    Vault internal vault;

    string public name = "Safer Investment Rehypothecation";
    string public symbol = "SIR";
    uint8 public immutable decimals = SystemConstants.SIR_DECIMALS;

    struct StakingParams {
        uint80 stake; // Amount of staked SIR
        uint176 cumETHPerSIRx80; // Cumulative ETH per SIR * 2^80
    }

    struct Balance {
        uint80 balanceOfSIR; // Amount of transferable SIR
        uint96 unclaimedETH; // Amount of ETH owed to the staker(s)
    }

    struct Auction {
        address bidder; // Address of the bidder
        uint96 bid; // Amount of the bid
        uint40 startTime; // Auction start time
        bool winnerPaid; // Whether the winner has been paid
    }

    StakingParams internal stakingParams; // Total staked SIR and cumulative ETH per SIR
    Balance private _supply; // Total unstaked SIR and ETH owed to the stakers
    uint96 internal totalBids; // Total amount of WETH deposited by the bidders
    bool private _initialized;

    mapping(address token => Auction) public auctions;
    mapping(address user => Balance) internal balances;
    mapping(address user => StakingParams) public stakersParams;

    mapping(address => mapping(address => uint256)) public allowance;

    uint256 internal immutable INITIAL_CHAIN_ID;
    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    constructor(address weth) {
        deployer = msg.sender;

        _WETH = IWETH9(payable(weth));

        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    /// @dev Necessary so the contract can unwrap WETH to ETH
    receive() external payable {}

    function initialize(address vault_) external {
        require(!_initialized && msg.sender == deployer);

        vault = Vault(vault_);

        _initialized = true;
    }

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    // Return transferable (unstaked) SIR
    function balanceOf(address account) external view returns (uint256) {
        return balances[account].balanceOfSIR;
    }

    // Return staked SIR + transferable (unstaked) SIR
    function totalBalanceOf(address account) external view returns (uint256) {
        return stakersParams[account].stake + balances[account].balanceOfSIR;
    }

    // Return transferable SIR only
    function supply() external view returns (uint256) {
        return _supply.balanceOfSIR;
    }

    // Return staked SIR + transferable (unstaked) SIR
    function totalSupply() external view returns (uint256) {
        return stakingParams.stake + _supply.balanceOfSIR;
    }

    // Return supply if all tokens were in circulation (including unminted from LPers and contributors, staked and unstaked)
    function maxTotalSupply() external view returns (uint256) {
        (uint40 tsIssuanceStart, , , , ) = vault.systemParams();

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
        unchecked {
            uint80 balance = balances[msg.sender].balanceOfSIR;
            require(amount <= balance);
            balances[msg.sender].balanceOfSIR = balance - uint80(amount);

            balances[to].balanceOfSIR += uint80(amount);

            emit Transfer(msg.sender, to, amount);

            return true;
        }
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        unchecked {
            uint80 balance = balances[from].balanceOfSIR;
            require(amount <= balance);
            balances[from].balanceOfSIR = balance - uint80(amount);

            balances[to].balanceOfSIR += uint80(amount);

            emit Transfer(from, to, amount);

            return true;
        }
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
        if (deadline < block.timestamp) revert PermitDeadlineExpired();

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

            if (recoveredAddress == address(0) || recoveredAddress != owner) revert InvalidSigner();

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

    function _mint(address to, uint80 amount) internal {
        unchecked {
            _supply.balanceOfSIR += uint80(amount);
            balances[to].balanceOfSIR += uint80(amount);

            emit Transfer(address(0), to, amount);
        }
    }

    /*////////////////////////////////////////////////////////////////
                            STAKING FUNCTIONS 
    ////////////////////////////////////////////////////////////////*/

    function stake(uint80 amount) external {
        Balance memory balance = balances[msg.sender];
        StakingParams memory stakingParams_ = stakingParams;
        StakingParams memory stakerParams = stakersParams[msg.sender];

        uint80 newBalanceOfSIR = balance.balanceOfSIR - amount;

        unchecked {
            // Update balance
            balances[msg.sender] = Balance(newBalanceOfSIR, _dividends(balance, stakingParams_, stakerParams));

            // Update staker info
            stakersParams[msg.sender] = StakingParams(stakerParams.stake + amount, stakingParams_.cumETHPerSIRx80);

            // Update _supply
            _supply.balanceOfSIR -= amount;

            // Update total stake
            stakingParams.stake = stakingParams_.stake + amount;

            emit Staked(msg.sender, amount);
        }
    }

    function unstake(uint80 amount) external {
        Balance memory balance = balances[msg.sender];
        StakingParams memory stakingParams_ = stakingParams;
        StakingParams memory stakerParams = stakersParams[msg.sender];

        uint80 newStake = stakerParams.stake - amount;

        unchecked {
            // Update balance
            balances[msg.sender] = Balance(
                balance.balanceOfSIR + amount,
                _dividends(balance, stakingParams_, stakerParams)
            );

            // Update staker info
            stakersParams[msg.sender] = StakingParams(newStake, stakingParams_.cumETHPerSIRx80);

            // Update _supply
            _supply.balanceOfSIR += amount;

            // Update total stake
            stakingParams.stake = stakingParams_.stake - amount;

            emit Unstaked(msg.sender, amount);
        }
    }

    function claim() external returns (uint96 dividends_) {
        unchecked {
            StakingParams memory stakingParams_ = stakingParams;
            dividends_ = _dividends(balances[msg.sender], stakingParams_, stakersParams[msg.sender]);

            // Null the unclaimed dividends
            balances[msg.sender].unclaimedETH = 0;

            // Update staker info
            stakersParams[msg.sender].cumETHPerSIRx80 = stakingParams_.cumETHPerSIRx80;

            // Update ETH _supply in the contract
            _supply.unclaimedETH -= dividends_;

            // Transfer dividends
            payable(msg.sender).transfer(dividends_);
        }
    }

    function dividends(address staker) public view returns (uint96) {
        return _dividends(balances[staker], stakingParams, stakersParams[staker]);
    }

    function _dividends(
        Balance memory balance,
        StakingParams memory stakingParams_,
        StakingParams memory stakerParams
    ) private pure returns (uint96 dividends_) {
        unchecked {
            dividends_ = balance.unclaimedETH;
            if (stakerParams.stake > 0) {
                dividends_ += uint96( // Safe to cast to uint96 because _supply.unclaimedETH is uint96
                    (uint256(stakingParams_.cumETHPerSIRx80 - stakerParams.cumETHPerSIRx80) * stakerParams.stake) >> 80
                );
            }
        }
    }

    /*////////////////////////////////////////////////////////////////
                        DIVIDEND PAYING FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function bid(address token) external payable {
        Auction memory auction = auctions[token];

        if (block.timestamp >= auction.startTime + SystemConstants.AUCTION_DURATION) revert AuctionIsOver();

        // Get the current bid
        uint96 totalBids_ = totalBids;
        uint96 newBid = uint96(_WETH.balanceOf(address(this)) - totalBids_);

        // If the bidder is the current winner, we just increase the bid
        if (msg.sender == auction.bidder) {
            auctions[token].bid += newBid;
            totalBids = totalBids_ + newBid - auction.bid;
            return;
        }

        // If the bidder is not the current winner, we check if the bid is higher
        if (newBid <= auction.bid) revert BidTooLow();

        // Update bidder & bid
        auctions[token] = Auction({bidder: msg.sender, bid: newBid, startTime: auction.startTime, winnerPaid: false});

        // Return the previous bid
        _WETH.transfer(auction.bidder, auction.bid);

        emit BidReceived(msg.sender, token, auction.bid, newBid);
    }

    /// @notice It cannot fail if the dividends transfer fails or payment to the winner fails.
    function collectFeesAndStartAuction(address token) external returns (uint112 collectedFees) {
        // (W)ETH is the dividend paying token, so we do not start an auction for it.
        if (token != address(_WETH)) {
            Auction memory auction = auctions[token];

            uint40 newStartTime = auction.startTime + SystemConstants.AUCTION_COOLDOWN;
            if (block.timestamp < newStartTime) revert NewAuctionCannotStartYet(newStartTime);

            // Start a new auction
            auctions[token] = Auction({
                bidder: address(0),
                bid: 0,
                startTime: uint40(block.timestamp), // This automatically aborts any reentrancy attack
                winnerPaid: false
            });

            // Update totalBids
            totalBids -= auction.bid;

            // We pay the previous winner if it has not been paid yet
            _payAuctionWinner(token, auction);
        }

        // Retrieve fees from the vault to be auctioned, or distributed if they are WETH
        collectedFees = vault.withdrawFees(token);

        // Distribute dividends from the previous auction even if paying the previous winner fails
        _distributeDividends();
    }

    /// @notice It reverts if the transfer fails and the dividends (WETH) is not distributed, allowing the bidder to try again.
    function payAuctionWinner(address token) external {
        Auction memory auction = auctions[token];
        if (block.timestamp < auction.startTime + SystemConstants.AUCTION_DURATION) revert AuctionIsNotOver();

        // Update auction
        auctions[token].winnerPaid = true;

        if (!_payAuctionWinner(token, auction)) revert NoTokensAvailable();

        // Distribute dividends
        _distributeDividends();
    }

    function _distributeDividends() private {
        unchecked {
            // Any excess WETH in the contract will be distributed.
            uint256 excessWETH = _WETH.balanceOf(address(this)) - totalBids;

            // Any excess ETH from when stake was 0, or from donations
            uint96 unclaimedETH = _supply.unclaimedETH;
            uint256 excessETH = address(this).balance - unclaimedETH;

            // Compute dividends
            uint256 dividends_ = excessWETH + excessETH;
            if (dividends_ == 0) return;

            // Unwrap WETH dividends to ETH
            _WETH.withdraw(excessWETH);

            StakingParams memory stakingParams_ = stakingParams;
            if (stakingParams_.stake > 0) {
                // Update cumETHPerSIRx80
                stakingParams.cumETHPerSIRx80 =
                    stakingParams_.cumETHPerSIRx80 +
                    uint176((dividends_ << 80) / stakingParams_.stake);

                // Update _supply
                _supply.unclaimedETH = unclaimedETH + uint96(dividends_);
            }

            emit DividendsPaid(dividends_);
        }
    }

    /// @dev This function must never revert, instead it returns false.
    function _payAuctionWinner(address token, Auction memory auction) private returns (bool success) {
        // Bidder already paid
        if (auction.winnerPaid) return false;

        // Only pay if there is a non-0 bid.
        if (auction.bid == 0) return false;

        /** Obtain reward amount
            Low-level call to avoid revert if the ERC20 token has some problems.
         */
        bytes memory data;
        (success, data) = token.call(abi.encodeWithSignature("balanceOf(address)", address(this)));

        // balanceOf failed and we cannot continue
        if (!success || data.length != 32) return false;

        // Prize is 0, so the claim is successful but without a transfer
        uint256 tokenAmount = abi.decode(data, (uint256));
        if (tokenAmount == 0) return true;

        /** Pay the winner if tokenAmount > 0
            Low-level call to avoid revert if the ERC20 token has some problems.
         */
        (success, data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", auction.bidder, tokenAmount));

        /** By the ERC20 standard, the transfer may go through without reverting (success == true),
            but if it returns a boolean that is false, the transfer actually failed.
         */
        if (data.length > 0 && !abi.decode(data, (bool))) return false;

        emit AuctionedTokensSentToWinner(auction.bidder, token, tokenAmount);
    }
}
