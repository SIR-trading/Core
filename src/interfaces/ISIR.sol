// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface SIR {
    struct Auction {
        address bidder;
        uint96 bid;
        uint40 startTime;
    }

    error AuctionIsNotOver();
    error BidTooLow();
    error InsufficientUnlockedStake();
    error InvalidSigner();
    error NewAuctionCannotStartYet();
    error NoAuction();
    error NoAuctionLot();
    error NoFeesCollected();
    error NotTheAuctionWinner();
    error PRBMath_MulDiv_Overflow(uint256 x, uint256 y, uint256 denominator);
    error PermitDeadlineExpired();
    error TransferToStakingVaultNotPermitted();

    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event AuctionStarted(address indexed token, uint256 feesToBeAuctioned);
    event AuctionedTokensSentToWinner(
        address indexed winner,
        address indexed beneficiary,
        address indexed token,
        uint256 reward
    );
    event BidReceived(address indexed bidder, address indexed token, uint96 previousBid, uint96 newBid);
    event DividendsClaimed(address indexed staker, uint96 amount);
    event DividendsPaid(uint96 amountETH, uint80 amountStakedSIR);
    event RewardsClaimed(address indexed contributor, uint256 indexed vaultId, uint80 rewards);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    receive() external payable;

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function ISSUANCE_RATE() external pure returns (uint72);
    function LP_ISSUANCE_FIRST_3_YEARS() external pure returns (uint72);
    function STAKING_VAULT() external view returns (address);
    function SYSTEM_CONTROL() external view returns (address);
    function allowMinting(bool mintingOfSIRHalted_) external;
    function allowance(address, address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function auctions(address token) external view returns (Auction memory);
    function balanceOf(address account) external view returns (uint256);
    function bid(address token, uint96 amount) external;
    function claim() external returns (uint96 dividends_);
    function collectFeesAndStartAuction(address token) external returns (uint256 totalFees);
    function contributorMint() external returns (uint80 rewards);
    function contributorMintAndStake() external returns (uint80 rewards);
    function contributorUnclaimedSIR(address contributor) external view returns (uint80);
    function decimals() external view returns (uint8);
    function getAuctionLot(address token, address beneficiary) external;
    function initialize(address vault_) external;
    function lperMint(uint256 vaultId) external returns (uint80 rewards);
    function lperMintAndStake(uint256 vaultId) external returns (uint80 rewards);
    function maxTotalSupply() external view returns (uint256);
    function name() external view returns (string memory);
    function nonces(address) external view returns (uint256);
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
    function stakeOf(address staker) external view returns (uint80 unlockedStake, uint80 lockedStake);
    function supply() external view returns (uint256);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function unclaimedDividends(address staker) external view returns (uint96);
    function unstake(uint80 amount) external;
    function unstakeAndClaim(uint80 amount) external returns (uint96 dividends_);
    function vault() external view returns (address);
}
