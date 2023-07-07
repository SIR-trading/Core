// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import "uniswap-v3-core/interfaces/IUniswapV3Factory.sol";
import "uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import "./interfaces/IFactory.sol";

// Libraries
import "./libraries/FloatingPoint.sol";
import "./libraries/UniswapPoolAddress.sol";

// Contracts
import "./libraries/Addresses.sol";

/**
 * @dev Some alternative partial implementation @ https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/OracleLibrary.sol
 *     @dev Gas cost: Around 10k gas for calling Uniswap v3 oracle, plus 10k gas for each different fee pool, making a min gas of approx 20k. For reference a Uniswap trade costs around 120k. Thus, calling the Uniswap v3 oracle is relatively cheap. Use a max liquidity approach rather than a weighted average.
 *     @dev Long vs short TWAP: E.g., a 120s-TWAP would decrease the price oscillation in a block by 10. Thus, a buy & sell time arbitrage would require a price change of 10*0.3%*2 = 6%!
 *     @dev Extending the TWAP memory costs 20k per slot, so divide TWAPinSeconds / 12 * 20k. So 5h TWAP at 10 gwei/gas woulc cost 0.3 ETH.
 */

/**
 * ON MULTI-BLOCK ORALCE ATTACK
 *
 *     Oracle manipulation is a problem that has plagued the DeFi space since the beginning.
 *     The problem is that a malicious actor can manipulate the price of an asset by front-running a transaction and then reverting it.
 *     This is a problem because the price oracle is used to determine the price of an asset,
 *     and the price of an asset is used to determine the amount of collateral that is required to mint a synthetic token.
 *     If the price of an asset is manipulated, then the amount of collateral required to mint a synthetic token can be manipulated.
 *
 *     The solution to this problem is to use a TWAP (time-weighted average price) instead of a single price point.
 *     The TWAP is calculated by taking the average price of an asset over a certain amount of time.
 *     This means that the price of an asset is less susceptible to manipulation because the price of an asset is the average price over a certain amount of time.
 *     The longer the TWAP, the less susceptible the price is to manipulation.
 *
 *     For more information read https://uniswap.org/blog/uniswap-v3-oracles
 *
 *
 *     ANALYSIS OF ORACLE ATTACK IN SIR TRADING
 *
 *     To analyze SIR, we look at worst case scenarios. If the attacker wanted to manipulate the price up, the worse case scenario for SIR would be when there are only
 *     gentlemen because minting fresh APE or MAAM will have maximum leverage. That is totalReserve = gentlemenReserve. Since LPers do not pay fees to mint,
 *     the steps of an attack maximizing profit are:
 *     1. Attacker mints MAAM with collateral
 *     2. Attacker manipulates price up
 *     3. Attacker burns MAAM getting more collateral in return
 *     4. Attacker returns price to market price
 *
 *     Let z denote value of the LPer's minted MAAM, let R be the value of the total reserve, let T be the amoung of minted TEA, and let p be the price of the collateral.
 *     A) After minting MAAM, R' = R + z = T/p + z
 *     B) As price goes up, the LPer's new holding is: z' = R' - T/p' = z + T(1/p - 1/p')
 *     C) Upon defining the price gain as g = p'/p, we get that the attacker's profit is z'-z = R(1-1/g)
 *
 *     Neglecting the cost of capital, the cost of this attack is the cost of manipulating the Uniswap v3 TWAP.
 *     In the worse case scenario, all Uni v3 liquidity (say Q) is concentrated just above the current price.
 *     D) So the cost of manipulating the price are the trading fees: 2*Q*f where f is the fee portion charged counted twice because the attacker must eventually revert the trade.
 *
 *     Furthermore, we assume the attacker can maintain this attack for 5 straight blocks without suffering arbitrage losses, which would in a normal situation incurs in huge losses.
 *     The total profit of the attacker under these assumptions is:
 *     E) R(1-1/g) - 2*Q*f
 *
 *     If we wish to make this attack unprofitable whenever R ≤ Q, we get that the maximum price gain allowed over 5 blocks must not be greater than
 *     gmax = 1/(1-2f)
 *     For instance, if f = 0.05%, then gmax = 1/(1-2*0.0005) = 1.001, which means that the TWAP can only go up by 0.1% in 1 minute.
 *     For a 1h TWAP, the instance price would be allowed to increase 34% from block-to-block.
 *
 *
 *     ABOUT PRICE CALCULATION ACROSS FEE TIERS
 *
 *     A TWAP weighted across pools of different liquidity is just as weak as the weakest pool (pool with least liquiity).
 *     For this reason, we select the best pool acrooss all fee tiers with the highest liquidity by tick weighted by fee, because as
 *     shown in the previous section, the fee has a direct impact on the price manipulation cost.
 */

contract Oracle {
    error NoUniswapV3Pool();
    error UniswapFeeTierIndexOutOfBounds();
    error OracleAlreadyInitialized();
    error OracleNotInitialized();

    event UniswapFeeTierAdded(uint24 fee);
    event OracleInitialized(address tokenA, address tokenB, uint24 feeTier);
    event OracleFeeTierChanged(address tokenA, address tokenB, uint24 feeTier);
    event PriceUpdated(address tokenA, address tokenB, bytes16 price);
    event PriceTruncated(address tokenA, address tokenB, bytes16 price);

    using FloatingPoint for bytes16;

    /**
     * Parameters of a Uniswap v3 tier.
     */
    struct UniswapFeeTier {
        uint24 fee;
        int24 tickSpacing;
    }

    /**
     * This struct is used to pass data between function.
     */
    struct UniswapOracleData {
        int64 aggLogPrice; // Aggregated log price over the period
        uint160 avLiquidity; // Average in-range liquidity over the period
        uint40 period; // Duration of the current TWAP
        uint16 cardinalityToIncrease; // Cardinality suggested for increase
    }

    /**
     * The following 4 state variables only take 1 slot
     */
    struct OracleState {
        bytes16 price; // Last stored price
        uint40 timeStamp; // Timestamp of the last stored price
        uint8 indexFeeTier; // Uniswap v3 fee tier currently being used as oracle
        uint8 indexFeeTierProbeNext; // Uniswap v3 fee tier to probe next
        bool initialized; // Whether the oracle has been initialized
        UniswapFeeTier uniswapFeeTier; // Uniswap v3 fee tier currently being used as oracle
    }

    /**
     * Constants
     */
    bytes16 private constant _ONE_DIV_SIXTY = 0x3ff91111111111111111111111111111;
    bytes16 private constant _LOG2_OF_TICK_FP = 0x3ff22e8a3a504218b0777ee4f3ff131c; // log2(1.0001)
    uint32 public constant TWAP_DELTA = 10 minutes; // When a new fee tier has larger liquidity, the TWAP array is increased in intervals of TWAP_DELTA.
    uint32 public constant TWAP_DURATION = 1 hours;

    /**
     * State variables
     */
    mapping(address tokenA => mapping(address tokenB => OracleState)) public oracleStates;
    uint private _uniswapExtraFeeTiers; // Least significant 8 bits represent the length of this tightly packed array, 48 bits for each extra fee tier

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    // Anyone can let the SIR factory know that a new fee tier exists in Uniswap V3
    function newUniswapFeeTier(uint24 fee) external {
        // Get all fee tiers
        UniswapFeeTier[] memory uniswapFeeTiers = getUniswapFeeTiers();

        // Check there is space to add a new fee tier
        require(uniswapFeeTiers.length < 9); // 4 basic fee tiers + 5 extra fee tiers max

        // Check fee tier actually exists in Uniswap v3
        int24 tickSpacing = IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY).feeAmountTickSpacing(fee);
        require(tickSpacing > 0);

        // Check fee tier has not been added yet
        for (uint256 i = 0; i < uniswapFeeTiers.length; i++) {
            require(fee != uniswapFeeTiers[i].fee);
        }

        // Add new fee tier
        _uniswapExtraFeeTiers |=
            (uint(fee) | uint(uint24(tickSpacing) << 24)) <<
            (8 + 48 * (uniswapFeeTiers.length - 4));

        // Increase count
        uint NuniswapExtraFeeTiers = uint(uint8(_uniswapExtraFeeTiers));
        _uniswapExtraFeeTiers &= (2 ** 240 - 1) << 8;
        _uniswapExtraFeeTiers |= NuniswapExtraFeeTiers + 1;

        emit UniswapFeeTierAdded(fee);
    }

    /**
     * @notice Initialize the oracleState for the pair of tokens
     * @notice The order of the tokens does not matter
     */
    function initialize(address tokenA, address tokenB) external {
        (tokenA, tokenB) = _orderTokens(tokenA, tokenB);

        // Get oracle state
        OracleState memory oracleState = oracleStates[tokenA][tokenB];
        if (oracleState.initialized) revert OracleAlreadyInitialized();

        // Get all fee tiers
        UniswapFeeTier[] memory uniswapFeeTiers = getUniswapFeeTiers();

        // Find the best fee tier by weighted liquidity
        uint256 score;
        uint16 cardinalityToIncrease;
        for (uint i = 0; i < uniswapFeeTiers.length; i++) {
            // Retrieve instant liquidity (we pass true as the last argument) because some pools may not have an initialized TWAP yet.
            UniswapOracleData memory oracleData = _uniswapOracleData(tokenA, tokenB, uniswapFeeTiers[i].fee, true);

            if (oracleData.avLiquidity > 0) {
                // Compute score
                uint256 scoreTemp = _feeTierScore(oracleData.avLiquidity, uniswapFeeTiers[i]);

                // Update best score
                if (scoreTemp > score) {
                    oracleState.indexFeeTier = uint8(i);
                    cardinalityToIncrease = oracleData.cardinalityToIncrease;
                    score = scoreTemp;
                }
            }
        }

        if (score == 0) revert NoUniswapV3Pool();
        oracleState.indexFeeTierProbeNext = (oracleState.indexFeeTier + 1) % uint8(uniswapFeeTiers.length);
        oracleState.initialized = true;
        oracleState.uniswapFeeTier = uniswapFeeTiers[oracleState.indexFeeTier];

        // Extend the memory array of the selected Uniswap pool.
        if (cardinalityToIncrease > 0) {
            IUniswapV3Pool uniswapPool = _getUniswapPool(tokenA, tokenB, uniswapFeeTiers[oracleState.indexFeeTier].fee);
            uniswapPool.increaseObservationCardinalityNext(cardinalityToIncrease);
        }

        // Update oracle state
        oracleStates[tokenA][tokenB] = oracleState;

        emit OracleInitialized(tokenA, tokenB, uniswapFeeTiers[oracleState.indexFeeTier].fee);
    }

    /**
     * @return the TWAP price of the pair of tokens
     * @notice Update the oracle state for the pair of tokens
     * @notice The order of the tokens does not matter for updating the oracle state, it only matters if we need to retrie the price
     */
    function updateOracleState(address collateralToken, address debtToken) external returns (bytes16) {
        (address tokenA, address tokenB) = _orderTokens(collateralToken, debtToken);

        // Get oracle state
        OracleState memory oracleState = oracleStates[tokenA][tokenB];
        if (!oracleState.initialized) revert OracleNotInitialized();

        // Update price
        UniswapOracleData memory oracleData = _uniswapOracleData(tokenA, tokenB, oracleState.uniswapFeeTier.fee, false);
        if (_updatePrice(oracleState, oracleData)) emit PriceTruncated(tokenA, tokenB, oracleState.price);

        // Fee tier is updated once per block at most
        if (oracleState.timeStamp != uint32(block.timestamp)) {
            // Get current fee tier and the one we wish to probe
            UniswapFeeTier memory uniswapFeeTierProbed = _uniswapFeeTier(oracleState.indexFeeTierProbeNext);

            // Retrieve oracle data
            UniswapOracleData memory oracleDataProbed = _uniswapOracleData(
                tokenA,
                tokenB,
                uniswapFeeTierProbed.fee,
                false
            );

            // Check the scores for the current fee tier and the probed one
            uint256 score = _feeTierScore(oracleData.avLiquidity, oracleState.uniswapFeeTier);
            uint256 scoreProbed = _feeTierScore(oracleDataProbed.avLiquidity, uniswapFeeTierProbed);

            if (score >= scoreProbed) {
                if (oracleData.cardinalityToIncrease > 0) {
                    // If the current tier is better and the TWAP's cardinality is insufficient, increase the cardinality
                    IUniswapV3Pool uniswapPool = _getUniswapPool(tokenA, tokenB, oracleState.uniswapFeeTier.fee);
                    uniswapPool.increaseObservationCardinalityNext(oracleData.cardinalityToIncrease);
                }
            } else {
                if (oracleDataProbed.cardinalityToIncrease > 0) {
                    // If the probed tier is better and the TWAP's cardinality is insufficient, increase the cardinality
                    IUniswapV3Pool uniswapPoolProbed = _getUniswapPool(tokenA, tokenB, uniswapFeeTierProbed.fee);
                    uniswapPoolProbed.increaseObservationCardinalityNext(oracleDataProbed.cardinalityToIncrease);
                } else if (oracleDataProbed.period >= TWAP_DURATION) {
                    // If the probed tier is better and the TWAP is fully initialized, switch to the probed tier
                    oracleState.indexFeeTier = oracleState.indexFeeTierProbeNext;
                    oracleState.uniswapFeeTier = uniswapFeeTierProbed;
                    emit OracleFeeTierChanged(tokenA, tokenB, uniswapFeeTierProbed.fee);
                }
            }

            // Update indices
            uint NuniswapFeeTiers = 4 + uint8(_uniswapExtraFeeTiers);
            oracleState.indexFeeTierProbeNext = (oracleState.indexFeeTierProbeNext + 1) % uint8(NuniswapFeeTiers);
            if (oracleState.indexFeeTier == oracleState.indexFeeTierProbeNext)
                oracleState.indexFeeTierProbeNext = (oracleState.indexFeeTierProbeNext + 1) % uint8(NuniswapFeeTiers);

            // Update timestamp
            oracleState.timeStamp = uint40(block.timestamp);
        }

        // Save new oracle state to storage
        oracleStates[tokenA][tokenB] = oracleState;
        emit PriceUpdated(tokenA, tokenB, oracleState.price);

        // Invert price if necessary
        if (collateralToken == tokenB) return oracleState.price.inv();
        return oracleState.price;
    }

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    function getUniswapFeeTiers() public view returns (UniswapFeeTier[] memory uniswapFeeTiers) {
        // Find out # of all possible fee tiers
        uint uniswapExtraFeeTiers_ = _uniswapExtraFeeTiers;
        uint NuniswapExtraFeeTiers = uint(uint8(uniswapExtraFeeTiers_));

        uniswapFeeTiers = new UniswapFeeTier[](4 + NuniswapExtraFeeTiers);
        uniswapFeeTiers[0] = UniswapFeeTier(100, 1);
        uniswapFeeTiers[1] = UniswapFeeTier(500, 10);
        uniswapFeeTiers[2] = UniswapFeeTier(3000, 60);
        uniswapFeeTiers[3] = UniswapFeeTier(10000, 200);

        // Extra fee tiers
        if (NuniswapExtraFeeTiers > 0) {
            uniswapExtraFeeTiers_ >>= 8;
            for (uint i = 0; i < NuniswapExtraFeeTiers; i++) {
                uniswapFeeTiers[4 + i] = UniswapFeeTier(
                    uint24(uniswapExtraFeeTiers_),
                    int24(uint24(uniswapExtraFeeTiers_ >> 24))
                );
                uniswapExtraFeeTiers_ >>= 48;
            }
        }
    }

    /**
     * @return the TWAP price of the pair of tokens
     */
    function getPrice(address collateralToken, address debtToken) external view returns (bytes16) {
        (address tokenA, address tokenB) = _orderTokens(collateralToken, debtToken);

        // Get oracle state
        OracleState memory oracleState = oracleStates[tokenA][tokenB];
        if (!oracleState.initialized) revert OracleNotInitialized();

        // Update price
        UniswapOracleData memory oracleData = _uniswapOracleData(tokenA, tokenB, oracleState.uniswapFeeTier.fee, false);
        _updatePrice(oracleState, oracleData);

        // Invert price if necessary
        if (collateralToken == tokenB) return oracleState.price.inv();
        return oracleState.price;
    }

    /*////////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates price
     */
    function _updatePrice(
        OracleState memory oracleState,
        UniswapOracleData memory oracleData
    ) internal view returns (bool truncated) {
        // Compute price
        bytes16 price = FloatingPoint
            .fromInt(oracleData.aggLogPrice / int256(uint256(oracleData.period)))
            .mul(_LOG2_OF_TICK_FP)
            .pow_2();

        // Truncate price if moves too fast
        (oracleState.price, truncated) = _truncatePrice(price, oracleState); // Oracle attack protection
    }

    function _uniswapFeeTier(uint8 indexFeeTier) internal view returns (UniswapFeeTier memory uniswapFeeTier) {
        if (indexFeeTier == 0) return UniswapFeeTier(100, 1);
        if (indexFeeTier == 1) return UniswapFeeTier(500, 10);
        if (indexFeeTier == 2) return UniswapFeeTier(3000, 60);
        if (indexFeeTier == 3) return UniswapFeeTier(10000, 200);
        else {
            // Extra fee tiers
            uint uniswapExtraFeeTiers_ = _uniswapExtraFeeTiers;
            uint NuniswapExtraFeeTiers = uint(uint8(uniswapExtraFeeTiers_));
            if (indexFeeTier >= NuniswapExtraFeeTiers + 4) revert UniswapFeeTierIndexOutOfBounds();

            uniswapExtraFeeTiers_ >>= 8 + 48 * (indexFeeTier - 4);
            return UniswapFeeTier(uint24(uniswapExtraFeeTiers_), int24(uint24(uniswapExtraFeeTiers_ >> 24)));
        }
    }

    function _feeTierScore(uint160 liquidity, UniswapFeeTier memory uniswapFeeTier) private pure returns (uint256) {
        return ((uint256(liquidity) * uint256(uniswapFeeTier.fee)) << 72) / uint256(uint24(uniswapFeeTier.tickSpacing));
    }

    function _getUniswapPool(address tokenA, address tokenB, uint24 fee) private pure returns (IUniswapV3Pool) {
        return
            IUniswapV3Pool(
                UniswapPoolAddress.computeAddress(
                    Addresses.ADDR_UNISWAPV3_FACTORY,
                    UniswapPoolAddress.getPoolKey(tokenA, tokenB, fee)
                )
            );
    }

    function _uniswapOracleData(
        address tokenA,
        address tokenB,
        uint24 fee,
        bool instantData
    ) private view returns (UniswapOracleData memory oracleData) {
        // Retrieve Uniswap pool
        IUniswapV3Pool uniswapPool = _getUniswapPool(tokenA, tokenB, fee);

        // If pool does not exist, no-op, return all parameters 0.
        if (address(uniswapPool).code.length == 0) return oracleData;

        // Retrieve oracle info from Uniswap v3
        uint32[] memory interval = new uint32[](2);
        interval[0] = instantData ? 1 : TWAP_DURATION;
        interval[1] = 0;
        int56[] memory tickCumulatives;
        uint160[] memory liquidityCumulatives;

        try uniswapPool.observe(interval) returns (
            int56[] memory tickCumulatives_,
            uint160[] memory liquidityCumulatives_
        ) {
            tickCumulatives = tickCumulatives_;
            liquidityCumulatives = liquidityCumulatives_;
        } catch Error(string memory reason) {
            // If pool is not initialized (or other unexpected errors), no-op, return all parameters 0.
            if (keccak256(bytes(reason)) != keccak256(bytes("OLD"))) return oracleData;

            /* 
                If Uniswap v3 Pool reverts with the message 'OLD' then
                ...the cardinality of Uniswap v3 oracle is insufficient
                ...or the TWAP storage is not yet filled with price data
             */
            // Get current oracle length
            uint16 cardinalityNow;
            uint16 cardinalityNext;
            uint16 observationIndex;

            /**
             * About Uni v3 Cardinality
             *  "cardinalityNow" is the current oracle array length with populated price information
             *  "cardinalityNext" is the future cardinality
             *  The oracle array is updated circularly.
             *  The array's cardinality is not bumped to cardinalityNext until the last element in the array (of length cardinalityNow) is updated
             *  just before a mint/swap/burn.
             */
            (, , observationIndex, cardinalityNow, cardinalityNext, , ) = uniswapPool.slot0();

            // Obtain the timestamp of the oldest observation
            uint40 blockTimestampOldest;
            bool initialized;
            (blockTimestampOldest, , , initialized) = uniswapPool.observations((observationIndex + 1) % cardinalityNow);

            // The next index might not be populated if the cardinality is in the process of increasing. In this case the oldest observation is always in index 0
            if (!initialized) {
                (blockTimestampOldest, , , ) = uniswapPool.observations(0);
                cardinalityNow = observationIndex + 1;
            }

            // Get longest available TWAP
            interval = new uint32[](1);
            interval[0] = uint32(block.timestamp - blockTimestampOldest);

            int56[] memory tickCumulativesAgain;
            uint160[] memory liquidityCumulativesAgain;
            (tickCumulativesAgain, liquidityCumulativesAgain) = uniswapPool.observe(interval);
            tickCumulatives[0] = tickCumulativesAgain[0];
            liquidityCumulatives[0] = liquidityCumulativesAgain[0];

            // Estimate necessary length of the oracle if we want it to be TWAP_DURATION long
            uint256 cardinalityNeeded = (uint256(cardinalityNow) * TWAP_DURATION - 1) / interval[0] + 1;

            /**
             * Check if cardinality must increase,
             * if so we add a TWAP_DELTA increment taking into consideration that every block takes in average 12 seconds
             */
            if (cardinalityNeeded > cardinalityNext)
                oracleData.cardinalityToIncrease = cardinalityNext + (TWAP_DELTA - 1) / (12 seconds) + 1;
        }

        // Compute average liquidity
        oracleData.avLiquidity = (uint160(interval[0]) << 128) / (liquidityCumulatives[1] - liquidityCumulatives[0]); // Liquidity is always >=1

        // Prices from Uniswap v3 are given as token1/token0
        oracleData.aggLogPrice = tickCumulatives[1] - tickCumulatives[0];

        // Duration of the observation
        oracleData.period = interval[0];
    }

    /**
     * @dev https://uniswap.org/blog/uniswap-v3-oracles#potential-oracle-innovations
     */
    function _truncatePrice(bytes16 price, OracleState memory oracleState) internal view returns (bytes16, bool) {
        bytes16 maxPriceAttenPerSec = FloatingPoint
            .ONE
            .sub(FloatingPoint.divu(oracleState.uniswapFeeTier.fee, 0.5 * 10 ** 6))
            .pow(_ONE_DIV_SIXTY); // 5 blocks of 12s = 60s
        bytes16 maxPriceAttenuation = maxPriceAttenPerSec.pow(
            FloatingPoint.fromUInt(block.timestamp - oracleState.timeStamp)
        );

        bytes16 priceMax = price.div(maxPriceAttenuation);
        if (price.cmp(priceMax) > 0) return (priceMax, true);

        bytes16 priceMin = price.mul(maxPriceAttenuation);
        if (price.cmp(priceMin) < 0) return (priceMin, true);

        return (price, false);
    }

    function _orderTokens(address tokenA, address tokenB) private pure returns (address, address) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return (tokenA, tokenB);
    }
}
