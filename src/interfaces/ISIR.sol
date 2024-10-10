// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import {SirStructs} from "../libraries/SirStructs.sol";

interface ISIR {
    error AuctionIsNotOver();
    error BidTooLow();
    error InvalidSigner();
    error NewAuctionCannotStartYet();
    error NoAuction();
    error NoAuctionLot();
    error NoFeesCollectedYet();
    error PermitDeadlineExpired();

    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event AuctionStarted(address indexed token);
    event AuctionedTokensSentToWinner(address indexed winner, address indexed token, uint256 reward);
    event BidReceived(address indexed bidder, address indexed token, uint96 previousBid, uint96 newBid);
    event DividendsPaid(uint256 amountETH);
    event RewardsClaimed(address indexed contributor, uint256 indexed vaultId, uint80 rewards);
    event Staked(address indexed staker, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);

    receive() external payable;

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function ISSUANCE_RATE() external pure returns (uint72);

    function LP_ISSUANCE_FIRST_3_YEARS() external pure returns (uint72);

    function allowance(address, address) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function auctions(address token) external view returns (SirStructs.Auction memory);

    function balanceOf(address account) external view returns (uint256);

    function bid(address token, uint96 amount) external;

    function claim() external returns (uint96 dividends_);

    function collectFeesAndStartAuction(address token) external returns (uint112 totalFeesToStakers);

    function contributorMint() external returns (uint80 rewards);

    function contributorUnclaimedSIR(address contributor) external view returns (uint80);

    function decimals() external view returns (uint8);

    function dividends(address staker) external view returns (uint96);

    function initialize(address vault_) external;

    function lPerMint(uint256 vaultId) external returns (uint80 rewards);

    function lPerMintAndStake(uint256 vaultId) external returns (uint80 rewards);

    function maxTotalSupply() external view returns (uint256);

    function name() external view returns (string memory);

    function nonces(address) external view returns (uint256);

    function payAuctionWinner(address token) external;

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function stake(uint80 amount) external;

    function stakersParams(address staker) external view returns (SirStructs.StakingParams memory);

    function supply() external view returns (uint256);

    function symbol() external view returns (string memory);

    function totalBalanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    function unstake(uint80 amount) external;

    function unstakeAndClaim(uint80 amount) external returns (uint96 dividends_);
}
