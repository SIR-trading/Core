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
    using FloatingPoint for bytes16;

    /**
     * Parameters of a Uniswap v3 tier.
     */
    struct UniswapFeeTier {
        uint24 fee;
        uint24 tickSpacing;
        bytes16 maxPriceAttenPerSec;
    }

    /**
     * This struct is used to pass data between function.
     */
    struct UniswapOracleData {
        int64 aggLogPrice; // Aggregated log price over the period
        uint160 avLiquidity; // Average in-range liquidity over the period
        uint32 period; // Duration of the current TWAP
        bool increaseCardinality; // Necessary cardinality for the TWAP
    }

    /**
     * The following 4 state variables only take 1 slot
     */
    struct OracleState {
        bytes16 priceFP; // Last stored price
        uint32 tsPrice; // Timestamp of the last stored price
        uint8 indexFeeTier; // Uniswap v3 fee tier currently being used as oracle
        uint88 activeFeeTiers; // Active bits indicate which fee tiers by uniswapFeeTiers are active
    }

    event UniswapOracleAdded(address indexed pool);
    event PriceUpdated(bytes16 priceFP);
    event PriceTruncated(bytes16 priceUntruncated);

    /**
     * Constants
     */
    uint16 private constant MAX_CARDINALITY = 2 ^ (16 - 1);
    bytes16 private constant ONE_DIV_SIXTY = 0x3ff91111111111111111111111111111;
    bytes16 private constant _LOG2_OF_TICK_FP =
        0x3ff22e8a3a504218b0777ee4f3ff131c; // log2(1.0001)
    uint16 public constant TWAP_DELTA = 10 minutes; // When a new fee tier has larger liquidity, the TWAP array is increased in intervals of TWAP_DELTA.
    uint16 public constant TWAP_DURATION = 1 hours;

    /**
     * State variables
     */
    mapping(address tokenA => mapping(address tokenB => OracleState))
        private oracleState;
    // USE FIRST 16 BITS TO INDICATE LENGTH OF TIERS, AND 48 BITS FOR EACH EXTRA FEE TIER
    uint private _uniswapExtraFeeTiers;

    function _maxPriceAttenPerSec(uint24 fee) private pure returns (bytes16) {
        return
            FloatingPoint.ONE.sub(FloatingPoint.divu(fee, 0.5 * 10 ** 6)).pow(
                ONE_DIV_SIXTY
            ); // 5 blocks of 12s = 60s
    }

    function _uniswapFeeTiers()
        internal
        view
        returns (UniswapFeeTier[] memory uniswapFeeTiers)
    {
        // Find out # of all possible fee tiers
        uint uniswapExtraFeeTiers_ = _uniswapExtraFeeTiers;
        uint NuniswapExtraFeeTiers = uint(uint16(uniswapExtraFeeTiers_));

        uniswapFeeTiers = new UniswapFeeTier[](4 + NuniswapExtraFeeTiers);
        uniswapFeeTiers[0] = UniswapFeeTier(100, 1, 0);
        uniswapFeeTiers[1] = UniswapFeeTier(500, 10, 0);
        uniswapFeeTiers[2] = UniswapFeeTier(3000, 60, 0);
        uniswapFeeTiers[3] = UniswapFeeTier(10000, 200, 0);

        // Extra fee tiers
        if (NuniswapExtraFeeTiers > 0) {
            uniswapExtraFeeTiers_ >>= 16;
            for (uint i = 0; i < NuniswapExtraFeeTiers; i++) {
                uniswapFeeTiers[4 + i] = UniswapFeeTier(
                    uint24(uniswapExtraFeeTiers_),
                    uint24(uniswapExtraFeeTiers_ >> 24),
                    0
                );
                uniswapExtraFeeTiers_ >>= 48;
            }
        }
    }

    /**
     * @notice Initialize the oracleState for the pair of tokens
     */
    function update(address tokenA, address tokenB) external {
        (tokenA, tokenB) = _orderTokens(tokenA, tokenB);

        // Get all fee tiers
        UniswapFeeTier[] memory uniswapFeeTiers = _uniswapFeeTiers();

        // Find the best fee tier by weighted liquidity
        uint256 scoreBest;
        OracleState memory oracleState = oracleState[tokenA][tokenB];
        bool firstUpdate = oracleState.activeFeeTiers == 0;

        // Find new active fee tiers
        for (uint i = 0; i < uniswapFeeTiers.length; i++) {
            if (oracleState.activeFeeTiers & (uint88(1) << i) != 0) continue; // Skip if already active

            // Retrieve average liquidity
            UniswapOracleData memory oracleData = _uniswapOracleData(
                tokenA,
                tokenB,
                uniswapFeeTiers[i].fee,
                true
            );
            uint160 avLiquidity = oracleData.avLiquidity;

            if (avLiquidity > 0) {
                // Bit is activated to indicate pool initialized and has liquidity
                oracleState.activeFeeTiers |= uint88(1) << i;

                // Compute score
                uint256 scoreTemp = ((uint256(avLiquidity) *
                    uniswapFeeTiers[i].fee) << 72) /
                    uniswapFeeTiers[i].tickSpacing;

                // Update best score
                if (scoreTemp > scoreBest) {
                    // First time oracle is updated, we find the best fee tier to start with
                    if (firstUpdate) oracleState.indexFeeTier = i;
                    scoreBest = scoreTemp;
                }
            }
        }

        require(scoreBest > 0, "No Uniswap v3 pool with liquidity"); // CUSTOM ERROR PLS

        // Extend the memory array of the best oracle TWAP_DURATION
        uniswapV3Pools[uniswapFeeTiers[oracleState.indexFeeTier].fee] // uniswapV3Pools???
            .increaseObservationCardinalityNext(
                (TWAP_DURATION - 1) / (12 seconds) + 1
            );

        // Update oracle state
        oracleState[tokenA][tokenB] = oracleState;
    }

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns price
     */
    function getPrice(
        address addrCollateralToken
    ) external view returns (bytes16) {
        // No need to update price if it has already been updated in this block
        if (tsPrice == uint32(block.timestamp % 2 ** 32))
            return _outputPrice(addrCollateralToken, priceFP);

        // Retrieve oracle data from the most liquid fee tier
        UniswapOracleData memory oracleData = _uniswapOracleData(
            uniswapFeeTiers[indexFeeTier].fee,
            false
        );

        // Compute price
        bytes16 priceFP_ = FloatingPoint
            .fromInt(
                oracleData.aggLogPrice / int256(uint256(oracleData.period))
            )
            .mul(_LOG2_OF_TICK_FP)
            .pow_2();
        priceFP_ = _truncatePrice(priceFP_); // Oracle attack protection
        return _outputPrice(addrCollateralToken, priceFP_);
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    // Anyone can let the SIR factory know that a new fee tier exists in Uniswap V3
    function newUniswapFeeTier(uint24 fee) external {
        // Get all fee tiers
        UniswapFeeTier[] memory uniswapFeeTiers = _uniswapFeeTiers();

        // Check there is space to add a new fee tier
        require(uniswapFeeTiers.length < 9); // 4 basic fee tiers + 5 extra fee tiers max

        // Check fee tier actually exists in Uniswap v3
        int24 tickSpacing = IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY)
            .feeAmountTickSpacing(fee);
        require(tickSpacing > 0);

        // Check fee tier has not been added yet
        for (uint256 i = 0; i < uniswapFeeTiers.length; i++) {
            require(
                fee != uniswapFeeTiers[i].fee &&
                    tickSpacing != uniswapFeeTiers[i].tickSpacing
            );
        }

        // Add new fee tier
        _uniswapExtraFeeTiers |=
            (uint24(fee) | (uint24(tickSpacing) << 24)) <<
            (16 + 48 * (uniswapFeeTiers.length - 4));

        // Increase count
        _uniswapExtraFeeTiers &= (2 ** 240 - 1) << 16;
        _uniswapExtraFeeTiers |= uint16(_uniswapExtraFeeTiers) + 1;
    }

    function newFeeTier(uint24 fee) external returns (bool) {
        // ChecK fee tier actually exists in Uniswap v3
        int24 tickSpacing = IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY)
            .feeAmountTickSpacing(fee);
        require(tickSpacing > 0);

        // Check if pool has already been registered
        require(
            address(uniswapV3Pools[fee]) == address(0),
            "Uniswap v3 pool already registered."
        );

        return _newFeeTier(UniswapFeeTier(fee, uint24(tickSpacing), 0));
    }

    /**
     * @notice Returns price, stores new price and updates oracles if necessary.
     */
    function updatePriceMemory(
        address addrCollateralToken
    ) external returns (bytes16) {
        // No need to update price if it has already been updated in this block
        if (tsPrice == uint32(block.timestamp % 2 ** 32)) return priceFP;

        // Retrieve oracle data from the most liquid fee tier
        UniswapOracleData memory oracleData = _uniswapOracleData(
            uniswapFeeTiers[indexFeeTier].fee,
            false
        );

        if (oracleData.increaseCardinality) {
            // Increase the cardinality of the current fee tier
            uniswapV3Pools[uniswapFeeTiers[indexFeeTier].fee]
                .increaseObservationCardinalityNext(
                    (TWAP_DELTA - 1) / (12 seconds) + 1
                );
        } else {
            // Retrieve oracle data from the next fee tier
            UniswapOracleData memory oracleDataOther = _uniswapOracleData(
                uniswapFeeTiers[indexNextProbedFeeTier].fee,
                false
            );

            // If the probed fee tier is better, continue extending its cardinality if needed
            uint256 scoreCurrentFeeTier = ((uint256(oracleData.avLiquidity) *
                uniswapFeeTiers[indexFeeTier].fee) << 72) /
                uniswapFeeTiers[indexFeeTier].tickSpacing;
            uint256 scoreNextProbedFeeTier = ((uint256(
                oracleDataOther.avLiquidity
            ) * uniswapFeeTiers[indexNextProbedFeeTier].fee) << 72) / // Better higher in-range liquidity // Better higher fee because it is more expensive to manipulate
                uniswapFeeTiers[indexNextProbedFeeTier].tickSpacing; // Normlize the in-range liquidity for different tick spacings

            if (scoreCurrentFeeTier >= scoreNextProbedFeeTier) {
                // If the probed tier is worse, check another one in the next transaction
                indexNextProbedFeeTier =
                    (indexNextProbedFeeTier + 1) %
                    uint48(uniswapFeeTiers.length);
                if (indexNextProbedFeeTier == indexFeeTier) {
                    indexNextProbedFeeTier =
                        (indexNextProbedFeeTier + 1) %
                        uint48(uniswapFeeTiers.length);
                }
            } else if (oracleDataOther.period >= TWAP_DURATION) {
                // If the probed tier is better and the oracle is fully initialized, change to it
                indexFeeTier = indexNextProbedFeeTier;
                indexNextProbedFeeTier =
                    (indexNextProbedFeeTier + 1) %
                    uint48(uniswapFeeTiers.length);
            } else if (oracleDataOther.increaseCardinality) {
                // If the probed tier is better but the TWAP length is not sufficient, increase it
                uniswapV3Pools[uniswapFeeTiers[indexNextProbedFeeTier].fee]
                    .increaseObservationCardinalityNext(
                        (TWAP_DELTA - 1) / (12 seconds) + 1
                    );
            }
        }

        // Compute price
        bytes16 priceFP_ = FloatingPoint
            .fromInt(
                oracleData.aggLogPrice / int256(uint256(oracleData.period))
            )
            .mul(_LOG2_OF_TICK_FP)
            .pow_2();
        priceFP = _truncatePrice(priceFP_); // Oracle attack protection
        emit PriceUpdated(priceFP);
        if (priceFP_ != priceFP) emit PriceTruncated(priceFP_);
        return _outputPrice(addrCollateralToken, priceFP);
    }

    /*////////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Register new fee tier in Uniswap v3
    function _newFeeTier(
        UniswapFeeTier memory feeTier
    ) internal returns (bool) {
        // Retrieve pool address
        address addrPool = UniswapPoolAddress.computeAddress(
            Addresses.ADDR_UNISWAPV3_FACTORY,
            UniswapPoolAddress.getPoolKey(TOKEN_B, TOKEN_A, feeTier.fee)
        );

        // Add new pool
        uniswapV3Pools[feeTier.fee] = IUniswapV3Pool(addrPool);

        // Max price gain per second
        feeTier.maxPriceAttenPerSec = FloatingPoint
            .ONE
            .sub(FloatingPoint.divu(feeTier.fee, 0.5 * 10 ** 6))
            .pow(ONE_DIV_SIXTY); // 5 blocks of 12s = 60s

        // Add fee tier
        uniswapFeeTiers.push(feeTier);
        emit UniswapOracleAdded(addrPool);

        // Check if the pool actually exists
        if (addrPool.code.length == 0) return false;

        // Check if it is initialized
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(addrPool).slot0();
        if (sqrtPriceX96 == 0) return false;
        else return true;
    }

    function _uniswapPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) private pure returns (IUniswapV3Pool) {
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
        IUniswapV3Pool uniswapPool = _uniswapPool(tokenA, tokenB, fee);

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
            // If pool is not initialized (or other unexpected errors), no-op return all parameters 0.
            if (keccak256(bytes(reason)) != keccak256(bytes("OLD")))
                return oracleData;

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
             *  "cardinalityNow" is the current oracle array lenght with populated price information
             *  "cardinalityNext" is the future cardinality
             *  The oracle array is updated circularly.
             *  The array's cardinality is not bumped to cardinalityNext until the last element in the array (of length cardinalityNow) is updated
             *  just before a mint/swap/burn.
             */
            (
                ,
                ,
                observationIndex,
                cardinalityNow,
                cardinalityNext,
                ,

            ) = uniswapPool.slot0();

            // Obtain the timestamp of the oldest observation
            uint32 blockTimestampOldest;
            bool initialized;
            (blockTimestampOldest, , , initialized) = uniswapPool.observations(
                (observationIndex + 1) % cardinalityNow
            );

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
            (tickCumulativesAgain, liquidityCumulativesAgain) = uniswapV3Pools[
                fee
            ].observe(interval);
            tickCumulatives[0] = tickCumulativesAgain[0];
            liquidityCumulatives[0] = liquidityCumulativesAgain[0];

            // Estimate necessary length of the oracle if we want it to be TWAP_DURATION long
            uint256 cardinalityNeeded = (uint256(cardinalityNow) *
                TWAP_DURATION -
                1) /
                interval[0] +
                1;

            // Check if cardinality must increase
            if (cardinalityNeeded > cardinalityNext)
                oracleData.increaseCardinality = true;
        }

        // Compute average liquidity
        oracleData.avLiquidity =
            (uint160(interval[0]) << 128) /
            (liquidityCumulatives[1] - liquidityCumulatives[0]); // Liquidity is always >=1

        // Prices from Uniswap v3 are given as token1/token0
        oracleData.aggLogPrice = tickCumulatives[1] - tickCumulatives[0];

        // Duration of the observation
        oracleData.period = interval[0];
    }

    function _outputPrice(
        address addrCollateralToken,
        bytes16 priceFP_
    ) private view returns (bytes16) {
        bytes16 priceOut = addrCollateralToken == TOKEN_B
            ? priceFP_.inv()
            : priceFP;
        assert(
            priceOut.cmp(FloatingPoint.INFINITY) < 0 &&
                priceOut.cmp(FloatingPoint.ZERO) > 0
        );
        return priceOut;
    }

    /**
     * @dev https://uniswap.org/blog/uniswap-v3-oracles#potential-oracle-innovations
     */
    function _truncatePrice(bytes16 priceFP_) internal view returns (bytes16) {
        bytes16 maxPriceAttenuation = uniswapFeeTiers[indexFeeTier]
            .maxPriceAttenPerSec
            .pow(FloatingPoint.fromUInt(block.timestamp - tsPrice));

        bytes16 priceMax = priceFP.div(maxPriceAttenuation);
        if (priceFP_.cmp(priceMax) > 0) return priceMax;

        bytes16 priceMin = priceFP.mul(maxPriceAttenuation);
        if (priceFP_.cmp(priceMin) < 0) return priceMin;

        return priceFP_;
    }

    function _orderTokens(
        address tokenA,
        address tokenB
    ) private pure returns (address, address) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    }
}
