// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {SystemConstants} from "./libraries/SystemConstants.sol";
import {Vault} from "./Vault.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {SirStructs} from "./libraries/SirStructs.sol";
import {Addresses} from "./libraries/Addresses.sol";

import "forge-std/console.sol";

/** @notice Solmate mod
    @dev SIR supply is designed to fit in a 80-bit unsigned integer.
    @dev ETH supply is 120.2M approximately with 18 decimals, which fits in a 88-bit unsigned integer.
    @dev With 96 bits, we can represent 79,2B ETH, which is 659 times more than the current supply. 
 */
contract Staker {
    error NewAuctionCannotStartYet();
    error NoAuctionLot();
    error NoFeesCollectedYet();
    error AuctionIsNotOver();
    error NoAuction();
    error BidTooLow();
    error InvalidSigner();
    error PermitDeadlineExpired();

    event AuctionStarted(address indexed token);
    event AuctionedTokensSentToWinner(address indexed winner, address indexed token, uint256 reward);
    event DividendsPaid(uint256 amountETH);
    event BidReceived(address indexed bidder, address indexed token, uint96 previousBid, uint96 newBid);
    event DividendsClaimed(address indexed staker, uint96 amount);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);

    address immutable deployer; // Just used to make sure function initialize() is not called by anyone else.
    IWETH9 private constant _WETH = IWETH9(payable(Addresses.ADDR_WETH));
    Vault internal vault;

    string public constant name = "Synthetics Implemented Right";
    string public constant symbol = "SIR";
    uint8 public immutable decimals = SystemConstants.SIR_DECIMALS;

    struct Balance {
        uint80 balanceOfSIR; // Amount of transferable SIR
        uint96 unclaimedETH; // Amount of ETH owed to the staker(s)
    }

    SirStructs.StakingParams internal stakingParams; // Total staked SIR and cumulative ETH per SIR
    Balance private _supply; // Total unstaked SIR and ETH owed to the stakers
    uint96 internal totalWinningBids; // Total amount of WETH deposited by the bidders
    bool private _initialized;

    mapping(address token => SirStructs.Auction) internal _auctions;
    mapping(address user => Balance) internal balances;
    mapping(address user => SirStructs.StakingParams) internal _stakersParams;

    mapping(address => mapping(address => uint256)) public allowance;

    uint256 internal immutable INITIAL_CHAIN_ID;
    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    constructor() {
        deployer = msg.sender;

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
        return _stakersParams[account].stake + balances[account].balanceOfSIR;
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
        return SystemConstants.ISSUANCE * (block.timestamp - vault.TIMESTAMP_ISSUANCE_START());
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
        SirStructs.StakingParams memory stakingParams_ = stakingParams;
        SirStructs.StakingParams memory stakerParams = _stakersParams[msg.sender];

        uint80 newBalanceOfSIR = balance.balanceOfSIR - amount;

        unchecked {
            // Update balance
            balances[msg.sender] = Balance(newBalanceOfSIR, _dividends(balance, stakingParams_, stakerParams));

            // Update staker info
            _stakersParams[msg.sender] = SirStructs.StakingParams(
                stakerParams.stake + amount,
                stakingParams_.cumulativeETHPerSIRx80
            );

            // Update _supply
            _supply.balanceOfSIR -= amount;

            // Update total stake
            stakingParams.stake = stakingParams_.stake + amount;

            emit Staked(msg.sender, amount);
        }
    }

    function unstake(uint80 amount) public {
        Balance memory balance = balances[msg.sender];
        SirStructs.StakingParams memory stakingParams_ = stakingParams;
        SirStructs.StakingParams memory stakerParams = _stakersParams[msg.sender];

        uint80 newStake = stakerParams.stake - amount;

        unchecked {
            // Update balance
            balances[msg.sender] = Balance(
                balance.balanceOfSIR + amount,
                _dividends(balance, stakingParams_, stakerParams)
            );

            // Update staker info
            _stakersParams[msg.sender] = SirStructs.StakingParams(newStake, stakingParams_.cumulativeETHPerSIRx80);

            // Update _supply
            _supply.balanceOfSIR += amount;

            // Update total stake
            stakingParams.stake = stakingParams_.stake - amount;

            emit Unstaked(msg.sender, amount);
        }
    }

    function claim() public returns (uint96 dividends_) {
        unchecked {
            SirStructs.StakingParams memory stakingParams_ = stakingParams;
            dividends_ = _dividends(balances[msg.sender], stakingParams_, _stakersParams[msg.sender]);

            // Null the unclaimed dividends
            balances[msg.sender].unclaimedETH = 0;

            // Update staker info
            _stakersParams[msg.sender].cumulativeETHPerSIRx80 = stakingParams_.cumulativeETHPerSIRx80;

            // Update ETH _supply in the contract
            _supply.unclaimedETH -= dividends_;

            // Emit event
            emit DividendsClaimed(msg.sender, dividends_);

            // Transfer dividends
            payable(msg.sender).transfer(dividends_);
        }
    }

    function unstakeAndClaim(uint80 amount) external returns (uint96 dividends_) {
        unstake(amount);
        return claim();
    }

    function dividends(address staker) public view returns (uint96) {
        return _dividends(balances[staker], stakingParams, _stakersParams[staker]);
    }

    function _dividends(
        Balance memory balance,
        SirStructs.StakingParams memory stakingParams_,
        SirStructs.StakingParams memory stakerParams
    ) private pure returns (uint96 dividends_) {
        unchecked {
            dividends_ = balance.unclaimedETH;
            if (stakerParams.stake > 0) {
                dividends_ += uint96( // Safe to cast to uint96 because _supply.unclaimedETH is uint96
                    (uint256(stakingParams_.cumulativeETHPerSIRx80 - stakerParams.cumulativeETHPerSIRx80) *
                        stakerParams.stake) >> 80
                );
            }
        }
    }

    /*////////////////////////////////////////////////////////////////
                        DIVIDEND PAYING FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function bid(address token, uint96 amount) external {
        unchecked {
            SirStructs.Auction memory auction = _auctions[token];

            // Unchecked because time stamps cannot overflow
            if (block.timestamp >= auction.startTime + SystemConstants.AUCTION_DURATION) revert NoAuction();

            // Transfer the bid to the contract
            _WETH.transferFrom(msg.sender, address(this), amount);

            if (msg.sender == auction.bidder) {
                // If the bidder is the current winner, we just increase the bid
                totalWinningBids += amount;
                amount += auction.bid;
            } else {
                // Return the previous bid to the previous bidder
                totalWinningBids += amount - auction.bid;
                _WETH.transfer(auction.bidder, auction.bid);
            }

            /** If the bidder is not the current winner, we check if the bid is higher.
                Null bids are no possible because auction.bid >=0 always.
             */
            if (amount <= auction.bid) revert BidTooLow();

            // Update bidder & bid
            _auctions[token] = SirStructs.Auction({bidder: msg.sender, bid: amount, startTime: auction.startTime});

            emit BidReceived(msg.sender, token, auction.bid, amount);
        }
    }

    /// @notice It cannot fail if the dividends transfer fails or payment to the winner fails.
    function collectFeesAndStartAuction(address token) external returns (uint256 totalFeesToStakers) {
        unchecked {
            // (W)ETH is the dividend paying token, so we do not start an auction for it.
            uint96 totalWinningBids_ = totalWinningBids;
            SirStructs.Auction memory auction;
            if (token != address(_WETH)) {
                auction = _auctions[token];

                uint40 newStartTime = auction.startTime + SystemConstants.AUCTION_COOLDOWN;
                if (block.timestamp < newStartTime) revert NewAuctionCannotStartYet();

                // Start a new auction
                _auctions[token] = SirStructs.Auction({
                    bidder: address(0),
                    bid: 0,
                    startTime: uint40(block.timestamp) // This automatically aborts any reentrancy attack
                });

                // Last bid is converted to dividends
                totalWinningBids_ -= auction.bid;
                totalWinningBids = totalWinningBids_;

                // Emit event for the new auction
                emit AuctionStarted(token);
            }

            // Retrieve fees from the vault to be auctioned, or distributed if they are WETH
            totalFeesToStakers = vault.withdrawFees(token); // WONT THIS AMOUNT ALSO BE PAID TO THE AUCTION WINNER?!?!

            /** For non-WETH tokens, do not start an auction if there are no fees to collect.
                For WETH, we distribute the fees immediately as dividends.
             */
            if (totalFeesToStakers == 0 && token != address(_WETH)) revert NoFeesCollectedYet();

            // Distribute dividends from the previous auction even if paying the previous winner fails
            bool noDividends = _distributeDividends(totalWinningBids_);

            /** For non-WETH tokens, it is possible it was a non-sale auction, but we don't want to revert because want to be able to start a new auction.
                For WETH, there are no _auctions. Fees are distributed immediately as dividends unless no-one is staking or there are no dividends.
                    No dividends => no fees.
             */
            if (noDividends && token == address(_WETH)) revert NoFeesCollectedYet();

            /** The auction winner is paid last because
                it makes external calls that could be used for reentrancy attacks. 
             */
            if (token != address(_WETH)) _payAuctionWinner(token, auction);
        }
    }

    /// @notice It reverts if the transfer fails and the dividends (WETH) is not distributed, allowing the bidder to try again.
    function payAuctionWinner(address token) external {
        SirStructs.Auction memory auction = _auctions[token];
        if (block.timestamp < auction.startTime + SystemConstants.AUCTION_DURATION) revert AuctionIsNotOver();

        // Update auction
        _auctions[token].bid = 0;

        // Last bid is converted to dividends
        uint96 totalWinningBids_ = totalWinningBids - auction.bid;
        totalWinningBids = totalWinningBids_;

        // Distribute dividends.
        _distributeDividends(totalWinningBids_);

        /** The auction winner is paid last because
            it makes external calls that could be used for reentrancy attacks. 
        */
        if (!_payAuctionWinner(token, auction)) revert NoAuctionLot();
    }

    function _distributeDividends(uint96 totalWinningBids_) private returns (bool noDividends) {
        unchecked {
            // Any excess WETH in the contract will be distributed.
            uint256 excessWETH = _WETH.balanceOf(address(this)) - totalWinningBids_;

            // Any excess ETH from when stake was 0, or from donations
            uint96 unclaimedETH = _supply.unclaimedETH;
            uint256 excessETH = address(this).balance - unclaimedETH;

            // Compute dividends
            uint256 dividends_ = excessWETH + excessETH;
            if (dividends_ == 0) return true;

            // Unwrap WETH dividends to ETH
            _WETH.withdraw(excessWETH);

            SirStructs.StakingParams memory stakingParams_ = stakingParams;
            if (stakingParams_.stake == 0) return true;

            // Update cumulativeETHPerSIRx80
            stakingParams.cumulativeETHPerSIRx80 =
                stakingParams_.cumulativeETHPerSIRx80 +
                uint176((dividends_ << 80) / stakingParams_.stake);

            // Update _supply
            _supply.unclaimedETH = unclaimedETH + uint96(dividends_);

            // Dividends are considered paid after unclaimedETH is updated
            emit DividendsPaid(dividends_);
        }
    }

    /// @dev This function must never revert, instead it returns false.
    function _payAuctionWinner(address token, SirStructs.Auction memory auction) private returns (bool success) {
        // Only pay if there is any bid
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
        return true;
    }

    /*////////////////////////////////////////////////////////////////
                                GETTERS
    ////////////////////////////////////////////////////////////////*/

    function auctions(address token) external view returns (SirStructs.Auction memory) {
        return _auctions[token];
    }

    function stakersParams(address staker) external view returns (SirStructs.StakingParams memory) {
        return _stakersParams[staker];
    }
}
