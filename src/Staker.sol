// SPDX-License-Identifier: AGPL-3.0-only
// Solmate mod of its ERC20 implementation
pragma solidity ^0.8.0;

import {SystemConstants} from "./libraries/SystemConstants.sol";
import {Vault} from "./Vault.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {SirStructs} from "./libraries/SirStructs.sol";
import {UD60x18, uEXP2_MAX_INPUT, uUNIT, convert} from "prb/UD60x18.sol";
import {exp2} from "prb/Common.sol";

import "forge-std/console.sol";

/** @notice The Staker contract handles mostly the staking of SIR tokens, and the token auctions.
    @notice Collection of fees from the vault can be triggered by anyone and also start an auction to convert them to ETH.
    @notice Stakers only receive dividends in the form of ETH.
    @dev SIR supply is designed to fit in a 80-bit unsigned integer.
    @dev ETH supply is 120.2M approximately with 18 decimals, which fits in a 88-bit unsigned integer.
    @dev With 96 bits, we can represent 79,2B ETH, which is 659 times more than the current supply. 
 */
contract Staker {
    error NewAuctionCannotStartYet();
    error NoAuctionLot();
    error NoFeesCollected();
    error AuctionIsNotOver();
    error NoAuction();
    error BidTooLow();
    error InvalidSigner();
    error PermitDeadlineExpired();
    error NotTheAuctionWinner();
    error InsufficientUnlockedStake();

    event AuctionStarted(address indexed token, uint256 feesToBeAuctioned);
    event AuctionedTokensSentToWinner(
        address indexed winner,
        address indexed beneficiary,
        address indexed token,
        uint256 reward
    );
    event DividendsPaid(uint96 amountETH, uint80 amountStakedSIR);
    event BidReceived(address indexed bidder, address indexed token, uint96 previousBid, uint96 newBid);
    event DividendsClaimed(address indexed staker, uint96 amount);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);

    address immutable deployer; // Just used to make sure function initialize() is not called by anyone else.
    IWETH9 private immutable _WETH;
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
    mapping(address user => SirStructs.StakerParams) internal _stakersParams;

    mapping(address => mapping(address => uint256)) public allowance;

    uint256 internal immutable INITIAL_CHAIN_ID;
    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    constructor(address weth) {
        _WETH = IWETH9(payable(weth));

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

    // Return transferable (unstaked) SIR only
    function supply() external view returns (uint256) {
        return _supply.balanceOfSIR;
    }

    // Return staked SIR + transferable (unstaked) SIR
    function totalSupply() external view returns (uint256) {
        return stakingParams.stake + _supply.balanceOfSIR;
    }

    // Return supply as if all tokens were in circulation (i.e., unclaimed SIR from LPers and contributors, staked SIR and unstaked SIR)
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

    /** @notice Stakes SIR tokens
        @notice Tokens can be unstaked at any time.
        @notice Your tokens must be staked during a dividend payment to receive ETH dividends
        @param amount of SIR to stake
     */
    function stake(uint80 amount) public {
        Balance memory balance = balances[msg.sender];
        SirStructs.StakingParams memory stakingParams_ = stakingParams;
        SirStructs.StakerParams memory stakerParams = getStakerParams(msg.sender);

        uint80 newBalanceOfSIR = balance.balanceOfSIR - amount;

        unchecked {
            // Update balance
            balances[msg.sender] = Balance(newBalanceOfSIR, _dividends(balance, stakingParams_, stakerParams));

            // Update staker info
            stakerParams.stake += amount;
            stakerParams.lockedStake += amount;
            stakerParams.cumulativeETHPerSIRx80 = stakingParams_.cumulativeETHPerSIRx80;
            _stakersParams[msg.sender] = stakerParams;

            // Update _supply
            _supply.balanceOfSIR -= amount;

            // Update total stake
            stakingParams.stake = stakingParams_.stake + amount;

            emit Staked(msg.sender, amount);
        }
    }

    /** @notice Unstakes SIR tokens
        @param amount of SIR to unstake
     */
    function unstake(uint80 amount) public {
        unchecked {
            Balance memory balance = balances[msg.sender];
            SirStructs.StakingParams memory stakingParams_ = stakingParams;
            SirStructs.StakerParams memory stakerParams = getStakerParams(msg.sender);

            // Check user has enough unlocked SIR to unstake
            if (amount > stakerParams.stake - stakerParams.lockedStake) revert InsufficientUnlockedStake();

            // Update balance of SIR and ETH dividends
            balances[msg.sender] = Balance(
                balance.balanceOfSIR + amount,
                _dividends(balance, stakingParams_, stakerParams)
            );

            // Update staker info
            stakerParams.stake -= amount;
            stakerParams.cumulativeETHPerSIRx80 = stakingParams_.cumulativeETHPerSIRx80;
            _stakersParams[msg.sender] = stakerParams;

            // Update _supply of SIR
            _supply.balanceOfSIR += amount;

            // Update total stake
            stakingParams.stake = stakingParams_.stake - amount;

            emit Unstaked(msg.sender, amount);
        }
    }

    /** @notice Claim ETH dividends.
        @notice You can claim even if you already unstaked you SIR.
        @return dividends_ of ETH received
     */
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
            (bool success, bytes memory data) = msg.sender.call{value: dividends_}("");
            if (!success) revert(string(data));
        }
    }

    /** @notice Convenient function for unstaking SIR and claim ETH dividens in one call.
        @param amount of SIR to unstake
        @return dividends_ received in ETH 
     */
    function unstakeAndClaim(uint80 amount) external returns (uint96 dividends_) {
        unstake(amount);
        return claim();
    }

    /** @return amount of unclaimed ETH
     */
    function unclaimedDividends(address staker) external view returns (uint96) {
        return _dividends(balances[staker], stakingParams, _stakersParams[staker]);
    }

    function _dividends(
        Balance memory balance,
        SirStructs.StakingParams memory stakingParams_,
        SirStructs.StakerParams memory stakerParams
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
    function collectFeesAndStartAuction(address token) external returns (uint256 totalFees) {
        unchecked {
            uint96 totalWinningBids_ = totalWinningBids;

            // Because ETH is the dividend paying token, we do not need to start an auction if fees are in WETH.
            if (token != address(_WETH)) {
                SirStructs.Auction memory auction = _auctions[token];

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

                // Distribute dividends collected from the previous auction if there were any
                _distributeDividends(totalWinningBids_);

                // The winner of the previous auction is paid after all state changes have been made to avoid reentrancy attacks.
                _payAuctionWinner(token, auction, address(0));

                /** Retrieve fees from the vault to be auctioned next.
                    This function must come after _payAuctionWinner to avoid paying the previous auction winner twice.
                */
                totalFees = vault.withdrawFees(token);

                // Do not start a new auction if there are no fees to auction
                if (totalFees == 0) revert NoFeesCollected();

                // Emit event with the new auction's details
                emit AuctionStarted(token, totalFees);
            } else {
                //  Retrieve WETH from the vault to be distributed as dividends.
                totalFees = vault.withdrawFees(token);

                // Distribute WETH as ETH dividends
                bool noDividends = _distributeDividends(totalWinningBids_);

                //  Revert if there is no (W)ETH be to distributed.
                if (noDividends) revert NoFeesCollected();
            }
        }
    }

    /** @notice Winner of the auction can call this function to get the auction lot.
        @notice If the transfer of the auction lot fails it reverts and the dividends (WETH) are not distributed, allowing the bidder to try again later.
        @param token of the auction lot
        @param beneficiary address of the auction lot. If it is 0, the auction lot is sent to the bidder address.
     */
    function getAuctionLot(address token, address beneficiary) external {
        SirStructs.Auction memory auction = _auctions[token];
        if (block.timestamp < auction.startTime + SystemConstants.AUCTION_DURATION) revert AuctionIsNotOver();
        if (msg.sender != auction.bidder) revert NotTheAuctionWinner();

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
        if (!_payAuctionWinner(token, auction, beneficiary)) revert NoAuctionLot();
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
            emit DividendsPaid(uint96(dividends_), stakingParams_.stake);
        }
    }

    /// @dev This function must never revert, instead it returns false.
    function _payAuctionWinner(
        address token,
        SirStructs.Auction memory auction,
        address beneficiary
    ) private returns (bool success) {
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
            Low-level call to avoid revert in case the destination has been banned from receiving tokens.
         */
        if (beneficiary == address(0)) beneficiary = auction.bidder;
        (success, data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", beneficiary, tokenAmount));

        /** By the ERC20 standard, the transfer may go through without reverting (success == true),
            but if it returns a boolean that is false, the transfer actually failed.
         */
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) return false;

        emit AuctionedTokensSentToWinner(auction.bidder, beneficiary, token, tokenAmount);
        return true;
    }

    /** @notice Returns the staking parameters of a staker at the present time
        @notice This function is responsible for unlocking stake and updating tsLastUpdate in stakerParams
     */
    function getStakerParams(address staker) internal view returns (SirStructs.StakerParams memory stakerParams) {
        unchecked {
            stakerParams = _stakersParams[staker];

            uint256 elapsedTime = block.timestamp - stakerParams.tsLastUpdate;
            stakerParams.tsLastUpdate = uint40(block.timestamp);

            /** If no time has passed since the stake parameters were last updated
                or there is no locked stake, then locked stake remains unchanged.
             */
            if (elapsedTime == 0 || stakerParams.lockedStake == 0) return stakerParams;

            /** Compute (t-t0)/T where
                    t-t0 is the elapsed time since last update
                    and T is period of time it takes for the locked stake to halve
             */
            UD60x18 exponent = UD60x18.wrap(elapsedTime * uUNIT).div( // Cannot overflow because 2^40 < 10^60
                    UD60x18.wrap(SystemConstants.HALVING_PERIOD * uUNIT)
                );

            // Compute 2^[(t-t0)/T]
            uint256 exponentUint = exponent.unwrap();
            if (exponentUint > uEXP2_MAX_INPUT) {
                // Too large, so we just round it to 0
                stakerParams.lockedStake = 0;
            } else {
                // Convert x to the 192.64-bit fixed-point format.
                uint256 exponent_192x64 = (exponentUint << 64) / uUNIT;

                // decay ≥ 1 always because exponent_192x64 is positive
                UD60x18 decay = UD60x18.wrap(exp2(exponent_192x64));

                /** Converting lockedStake to UD60x18 does not overflow because 2^80 < 10^60
                    Computes lockedStake/2^[(t-t0)/T]
                 */
                stakerParams.lockedStake = uint80(convert(UD60x18.wrap(stakerParams.lockedStake * uUNIT).div(decay)));
            }
        }
    }

    /*////////////////////////////////////////////////////////////////
                                GETTERS
    ////////////////////////////////////////////////////////////////*/

    function auctions(address token) external view returns (SirStructs.Auction memory) {
        return _auctions[token];
    }

    function stakeOf(address staker) external view returns (uint80 unlockedStake, uint80 lockedStake) {
        SirStructs.StakerParams memory stakerParams = getStakerParams(staker);

        return (stakerParams.stake - stakerParams.lockedStake, stakerParams.lockedStake);
    }
}
