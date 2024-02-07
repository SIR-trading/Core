// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {SystemConstants} from "./libraries/SystemConstants.sol";
import {Vault} from "./Vault.sol";

/** @notice Solmate mod
    @dev SIR balance is designed to fit in a 80-bit unsigned integer.
    @dev ETH balance is 120.2M approximately with 18 decimals, which fits in a 88-bit unsigned integer.
    @dev With 96 bits, we can represent 79,2B ETH, which is 659 times more than the current balance. 
 */
contract ERC20Staker {
    error NewAuctionCannotStartYet();
    error TokensAlreadyClaimed();
    error AuctionIsNotOver();

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);

    Vault internal immutable VAULT;

    string public name = "Sustainable Investing Returns";
    string public symbol = "SIR";
    uint8 public immutable decimals = SystemConstants.SIR_DECIMALS;

    struct StakingParams {
        uint80 stake; // Amount of staked SIR
        uint176 cumETHPerSIRx80; // Cumulative ETH per SIR * 2^80
    }

    struct Balance {
        uint80 balanceOfSIR; // Amount of transferable SIR
        uint96 unclaimedWETH; // Amount of WETH owed to the staker(s)
    }

    // struct WinningBidder {
    //     uint96 bid; // Amount of ETH bidded
    //     address addr; // Address of the bidder
    // }

    struct Auction {
        uint96 bid; // Amount of ETH bidded
        address bidder; // Address of the bidder
        uint40 startTime; // Auction start time
        bool winnerPaid; // Whether the winner has been paid
    }

    StakingParams internal stakingParams; // Total staked SIR and cumulative ETH per SIR
    Balance internal supply; // Total unstaked SIR and WETH owed to the stakers

    mapping(address token => Auction) public auctions;
    // mapping(address token => WinningBidder) public winningBidders;
    mapping(address user => Balance) public balances;
    mapping(address user => StakingParams) internal stakersParams;

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
        return balances[account].balanceOfSIR;
    }

    // Return staked SIR
    function totalBalanceOf(address account) external view returns (uint256) {
        return stakersParams[account].stake + balances[account].balanceOfSIR;
    }

    // Return total staked SIR
    function stakedSupply() external view returns (uint256) {
        return stakingParams.stake;
    }

    // Return staked SIR + transferable SIR
    function totalSupply() external view returns (uint256) {
        return stakingParams.stake + supply.balanceOfSIR;
    }

    // Return all SIR if all tokens were in circulation
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

    function _mint(address to, uint80 amount) internal {
        unchecked {
            supply.balanceOfSIR += uint80(amount);
            balances[to].balanceOfSIR += uint80(amount);

            emit Transfer(address(0), to, amount);
        }
    }

    /*////////////////////////////////////////////////////////////////
                            STAKING FUNCTIONS 
    ////////////////////////////////////////////////////////////////*/

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

            // Update supply
            supply.balanceOfSIR += amount;

            // Update total stake
            stakingParams.stake = stakingParams_.stake - amount;

            emit Unstaked(msg.sender, amount);
        }
    }

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

            // Update supply
            supply.balanceOfSIR -= amount;

            // Update total stake
            stakingParams.stake = stakingParams_.stake + amount;

            emit Staked(msg.sender, amount);
        }
    }

    function claim() external {
        unchecked {
            StakingParams memory stakingParams_ = stakingParams;
            uint96 dividends_ = _dividends(balances[msg.sender], stakingParams_, stakersParams[msg.sender]);

            // Null the unclaimed dividends
            balances[msg.sender].unclaimedWETH = 0;

            // Update staker info
            stakersParams[msg.sender].cumETHPerSIRx80 = stakingParams_.cumETHPerSIRx80;

            // Update ETH supply in the contract
            supply.unclaimedWETH -= dividends_;

            // WETH is immutable so we can use the low-level call
            Addresses.ADDR_WETH.call(abi.encodeWithSignature("transfer(address,uint256)", msg.sender, dividends_));
        }
    }

    function dividends(address staker) public view returns (uint96) {
        return _dividends(balances[staker], stakingParams, stakersParams[staker]);
    }

    function _dividends(
        Balance memory balance,
        StakingParams memory stakingParams_,
        StakingParams memory stakerParams
    ) private pure returns (uint96) {
        unchecked {
            return
                balance.unclaimedWETH +
                uint96( // Safe to cast to uint96 because supply.unclaimedWETH is uint96
                    (uint256(stakingParams_.cumETHPerSIRx80 - stakerParams.cumETHPerSIRx80) * stakerParams.stake) >> 80
                );
        }
    }

    /*////////////////////////////////////////////////////////////////
                        DIVIDEND PAYING FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    // WHAT IF STAKE IS 0??????????????

    // function bid(address token) external {
    //     Auction memory auction = auctions[token];

    //     if (block.timestamp >= auction.startTime + SystemConstants.AUCTION_DURATION) revert AuctionIsOver();

    //     if (amount <= auction.bid) revert BidTooLow();

    //     // Update auction
    //     auctions[token] = Auction({
    //         bid: amount,
    //         addr: msg.sender,
    //         startTime: auction.startTime,
    //         winnerPaid: false
    //     });

    //     // Transfer the bid to the contract
    //     TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
    // }

    function collectFeesAndStartAuction(address token) external {
        // WETH is the dividend paying token, so we do not start an auction for it.
        if (token != Addresses.ADDR_WETH) {
            Auction memory auction = auctions[token];

            if (block.timestamp < auction.startTime + SystemConstants.AUCTION_COOLDOWN)
                revert NewAuctionCannotStartYet();

            // Start a new auction
            auctions[token] = Auction({
                bid: 0,
                addr: address(0),
                startTime: uint40(block.timestamp), // This automatically aborts any reentrancy attack
                winnerPaid: false
            });

            // We pay the previous winner if it has not been paid yet
            _payAuctionWinner(token, auction);

            // Distribute dividends even if paying the previous winner fails
            _distributeDividends();
        }

        // Retrieve fees from the vault. Reverts if no fees are available.
        VAULT.withdrawFees(token);
    }

    /// @notice It reverts if the transfer fails and the dividends (WETH) is not distributed, allowing the bidder to try again.
    function payAuctionWinner(address token) external {
        Auction memory auction = auctions[token];
        if (block.timestamp < auction.startTime + SystemConstants.AUCTION_DURATION) revert AuctionIsNotOver();

        // Update auction
        auctions[token].winnerPaid = true;

        if (!_payAuctionWinner(token, auction)) revert TokensAlreadyClaimed();

        // Distribute dividends
        _distributeDividends();
    }

    function _distributeDividends() private {
        unchecked {
            // Get the total amount of WETH in the contract
            uint256 newUnclaimedWETH = Addresses.ADDR_WETH.call(
                abi.encodeWithSignature("balanceOf(address)", address(this))
            );

            // Any excess WETH in the contracdt will also be distributed.
            uint256 dividends = newUnclaimedWETH - supply.unclaimedWETH;
            if (dividends == 0) return;

            // Update cumETHPerSIRx80
            StakingParams memory stakingParams_ = stakingParams;
            stakingParams.cumETHPerSIRx80 =
                stakingParams_.cumETHPerSIRx80 +
                uint176((dividends << 80) / stakingParams_.stake);

            // Update supply
            supply.unclaimedWETH = uint96(newUnclaimedWETH);
        }
    }

    /// @dev This function must never revert, instead it returns false.
    function _payAuctionWinner(address token, Auction memory auction) private returns (bool success) {
        // Bidder already paid
        if (auction.winnerPaid) return false;

        // Only pay if there is a non-0 bid.
        if (auction.bid == 0) return false;

        // Wrap ETH (bid) to WETH (dividends)
        Addresses.ADDR_WETH.call{value: auction.bid}(abi.encodeWithSignature("deposit()"));

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
        (success, data) = token.call(abi.encodeWithSelector(ERC20.transfer.selector, auction.addr, prize));

        /** By the ERC20 standard, the transfer may go through without reverting (success == true),
            but if it returns a boolean that is false, the transfer actually failed.
         */
        if (data.length > 0 && !abi.decode(data, (bool))) return false;
    }
}
