// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library SystemConstants {
    uint8 internal constant SIR_DECIMALS = 12;

    /** SIR Token Issuance Rate
        If we want to issue 2,015,000,000 SIR per year, this implies an issuance rate of 63.9 SIR/s.
     */
    uint72 internal constant ISSUANCE = uint72(2015000000 * 10 ** SIR_DECIMALS) / 365 days; // [sir/s]

    // During the first 3 years, 20% of the emissions are diverged to contributors.
    uint72 internal constant ISSUANCE_FIRST_3_YEARS = (ISSUANCE * 8) / 10;

    uint128 internal constant TEA_MAX_SUPPLY = (uint128(ISSUANCE_FIRST_3_YEARS) << 96) / type(uint16).max; // Must fit in uint128

    uint40 internal constant THREE_YEARS = 3 * 365 days;

    address internal constant ADDR_UNISWAPV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    int64 internal constant MAX_TICK_X42 = 1951133415219145403; // log_1.0001((2^128-1(/2^64))*2^42

    // Approximately 10 days. We did not choose 10 days precisely to avoid auctions always ending on the same day and time of the week.
    uint40 internal constant AUCTION_COOLDOWN = 247 hours; // 247h & 240h have no common factors

    uint40 internal constant AUCTION_DURATION = 24 hours;

    int8 internal constant MAX_LEVERAGE_TIER = 2;

    int8 internal constant MIN_LEVERAGE_TIER = -4;
}
