// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "./interfaces/IFactory.sol";

// Libraries
import "./libraries/FloatingPoint.sol";
import "./libraries/UniswapPoolAddress.sol";

// Contracts
import "./libraries/Addresses.sol";

import "hardhat/console.sol";

/**
    @dev Some alternative partial implementation @ https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/OracleLibrary.sol
    @dev Gas cost: Around 10k gas for calling Uniswap v3 oracle, plus 10k gas for each different fee pool, making a min gas of approx 20k. For reference a Uniswap trade costs around 120k. Thus, calling the Uniswap v3 oracle is relatively cheap. Use a max liquidity approach rather than a weighted average.
    @dev Long vs short TWAP: E.g., a 120s-TWAP would decrease the price oscillation in a block by 10. Thus, a buy & sell time arbitrage would require a price change of 10*0.3%*2 = 6%!
    @dev Extending the TWAP memory costs 20k per slot, so divide TWAPinSeconds / 12 * 20k. So 5h TWAP at 10 gwei/gas woulc cost 0.3 ETH.
 */

/**
    ON MULTI-BLOCK ORALCE ATTACK

    Oracle manipulation is a problem that has plagued the DeFi space since the beginning.
    The problem is that a malicious actor can manipulate the price of an asset by front-running a transaction and then reverting it.
    This is a problem because the price oracle is used to determine the price of an asset,
    and the price of an asset is used to determine the amount of collateral that is required to mint a synthetic token.
    If the price of an asset is manipulated, then the amount of collateral required to mint a synthetic token can be manipulated.

    The solution to this problem is to use a TWAP (time-weighted average price) instead of a single price point.
    The TWAP is calculated by taking the average price of an asset over a certain amount of time.
    This means that the price of an asset is less susceptible to manipulation because the price of an asset is the average price over a certain amount of time.
    The longer the TWAP, the less susceptible the price is to manipulation.
    
    For more information read https://uniswap.org/blog/uniswap-v3-oracles

 ** 
    ANALYSIS OF ORACLE ATTACK IN SIR TRADING 

    To analyze SIR, we look at worst case scenarios. If the attacker wanted to manipulate the price up, the worse case scenario for SIR would be when there are only
    gentlemen because minting fresh APE or MAAM will have maximum leverage. That is totalReserve = gentlemenReserve. Since LPers do not pay fees to mint,
    the steps of an attack maximizing profit are:
    1. Attacker mints MAAM with collateral
    2. Attacker manipulates price up
    3. Attacker burns MAAM getting more collateral in return
    4. Attacker returns price to market price

    Let z denote value of the LPer's minted MAAM, let R be the value of the total reserve, let T be the amoung of minted TEA, and let p be the price of the collateral.
    A) After minting MAAM, R' = R + z = T/p + z
    B) As price goes up, the LPer's new holding is: z' = R' - T/p' = z + T(1/p - 1/p')
    C) Upon defining the price gain as g = p'/p, we get that the attacker's profit is z'-z = R(1-1/g)

    Neglecting the cost of capital, the cost of this attack is the cost of manipulating the Uniswap v3 TWAP.
    In the worse case scenario, all Uni v3 liquidity (say Q) is concentrated just above the current price.
    D) So the cost of manipulating the price are the trading fees: 2*Q*f where f is the fee portion charged counted twice because the attacker must eventually revert the trade.
    
    Furthermore, we assume the attacker can maintain this attack for 5 straight blocks without suffering arbitrage losses, which would in a normal situation incurs in huge losses.
    The total profit of the attacker under these assumptions is:
    E) R(1-1/g) - 2*Q*f

    If we wish to make this attack unprofitable whenever R ≤ Q, we get that the maximum price gain allowed over 5 blocks must not be greater than
    gmax = 1/(1-2f)
    For instance, if f = 0.05%, then gmax = 1/(1-2*0.0005) = 1.001, which means that the TWAP can only go up by 0.1% in 1 minute.
    For a 1h TWAP, the instance price would be allowed to increase 34% from block-to-block.

  **
    ABOUT PRICE CALCULATION ACROSS FEE TIERS

    A TWAP weighted across pools of different liquidity is just as weak as the weakest pool (pool with least liquiity).
    For this reason, we select the best pool acrooss all fee tiers with the highest liquidity by tick weighted by fee, because as
    shown in the previous section, the fee has a direct impact on the price manipulation cost.
  */

contract Oracle {
    using FloatingPoint for bytes16;

    struct UniswapFeeTier {
        uint24 fee;
        uint24 tickSpacing;
        bytes16 maxPriceAttenPerSec;
    }

    struct OracleData {
        int64 aggLogPrice; // Aggregated log price over the period
        uint160 avLiquidity; // Average in-range liquidity over the period
        uint32 period; // Duration of the current TWAP
        bool increaseCardinality; // Necessary cardinality for the TWAP
    }

    event OracleCreated(address indexed tokenA, address indexed tokenB);
    event UniswapOracleAdded(address indexed pool);
    event PriceUpdated(bytes16 priceFP);
    event PriceTruncated(bytes16 priceUntruncated);
    // U3 emits IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew) when its oracle cardinality is updated

    uint16 private constant MAX_CARDINALITY = 2 ^ (16 - 1);
    bytes16 private constant ONE_DIV_SIXTY = 0x3ff91111111111111111111111111111;
    bytes16 private constant _LOG2_OF_TICK_FP = 0x3ff22e8a3a504218b0777ee4f3ff131c; // log2(1.0001)
    uint16 public constant TWAP_DELTA = 10 minutes; // When a new fee tier has larger liquidity, the TWAP array is increased in intervals of TWAP_DELTA.
    uint16 public constant TWAP_DURATION = 1 hours;

    address public immutable TOKEN_A;
    address public immutable TOKEN_B;

    /**
        The following 4 state variables only take 1 slot
     */
    bytes16 private _priceFP; // Last stored price
    uint32 private _tsPrice; // Timestamp of the last stored price
    uint48 private _indexCurrentFeeTier; // Uniswap v3 fee tier currently being used as oracle
    uint48 private _indexNextProbedFeeTier; // Uniswap v3 fee tier that will be probed in case we must initialize or change the oracle fee tier

    UniswapFeeTier[] public uniswapFeeTiers;
    mapping(uint24 => IUniswapV3Pool) public uniswapV3Pools;

    constructor(address tokenA, address tokenB) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        TOKEN_A = tokenA;
        TOKEN_B = tokenB;

        emit OracleCreated(tokenA, tokenB);
    }

    /**
        @notice Initialize the variable-lengtha array uniswapFeeTiers.
        @dev This function is called right after its creation.
     */
    function initialize(UniswapFeeTier[] memory uniswapFeeTiers_) external {
        // To ensure this function is only called once right after deployment
        require(uniswapFeeTiers.length == 0);

        uint48 NuniswapFeeTiers = uint48(uniswapFeeTiers_.length);

        // Add the fee tiers, and get data for those that are initialized
        bool anyIsInitialized = false;
        uint160[] memory avLiquidity = new uint160[](NuniswapFeeTiers);
        for (uint48 i = 0; i < NuniswapFeeTiers; i++) {
            bool isInitialized = _newFeeTier(uniswapFeeTiers_[i]);
            anyIsInitialized = isInitialized || anyIsInitialized;

            // Retrieve oracle data from each initialized fee tier
            OracleData memory oracleData = _getUniswapOracleData(uniswapFeeTiers_[i].fee, true);
            if (isInitialized) avLiquidity[i] = oracleData.avLiquidity;
        }
        require(anyIsInitialized, "No initialized Uniswap v3 pool");

        // Find the best oracle by weighted liquidity
        uint256 score;
        for (uint48 i = 0; i < NuniswapFeeTiers; i++) {
            uint256 scoreTemp = ((uint256(avLiquidity[i]) * uniswapFeeTiers_[i].fee) << 72) /
                uniswapFeeTiers_[i].tickSpacing;
            if (scoreTemp > score) {
                _indexCurrentFeeTier = i;
                score = scoreTemp;
            }
        }
        require(score > 0, "No Uniswap v3 with liquidity");

        // Initialize the memory array of the best oracle TWAP_DURATION
        uniswapV3Pools[uniswapFeeTiers_[_indexCurrentFeeTier].fee].increaseObservationCardinalityNext(
            (TWAP_DURATION - 1) / (12 seconds) + 1
        );

        _indexNextProbedFeeTier = (_indexCurrentFeeTier + 1) % NuniswapFeeTiers;
    }

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    /**
        @notice Returns price
     */
    function getPrice(address addrCollateralToken) external view returns (bytes16) {
        // No need to update price if it has already been updated in this block
        if (_tsPrice == uint32(block.timestamp % 2**32)) return _outputPrice(addrCollateralToken, _priceFP);

        // Retrieve oracle data from the most liquid fee tier
        OracleData memory oracleData = _getUniswapOracleData(uniswapFeeTiers[_indexCurrentFeeTier].fee, false);

        // Compute price
        bytes16 priceFP_ = FloatingPoint
            .fromInt(oracleData.aggLogPrice / int256(uint256(oracleData.period)))
            .mul(_LOG2_OF_TICK_FP)
            .pow_2();
        priceFP_ = _truncatePrice(priceFP_); // Oracle attack protection
        return _outputPrice(addrCollateralToken, priceFP_);
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    function newFeeTier(uint24 fee) external returns (bool) {
        // ChecK fee tier actually exists in Uniswap v3
        int24 tickSpacing = IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY).feeAmountTickSpacing(fee);
        require(tickSpacing > 0);

        // Check if pool has already been registered
        require(address(uniswapV3Pools[fee]) == address(0), "Uniswap v3 pool already registered.");

        return _newFeeTier(UniswapFeeTier(fee, uint24(tickSpacing), 0));
    }

    /**
        @notice Returns price, stores new price and updates oracles if necessary.
     */
    function updatePriceMemory(address addrCollateralToken) external returns (bytes16) {
        // No need to update price if it has already been updated in this block
        if (_tsPrice == uint32(block.timestamp % 2**32)) return _priceFP;

        // Retrieve oracle data from the most liquid fee tier
        OracleData memory oracleData = _getUniswapOracleData(uniswapFeeTiers[_indexCurrentFeeTier].fee, false);

        if (oracleData.increaseCardinality)
            // Increase the cardinality of the current fee tier
            uniswapV3Pools[uniswapFeeTiers[_indexCurrentFeeTier].fee].increaseObservationCardinalityNext(
                (TWAP_DELTA - 1) / (12 seconds) + 1
            );
        else {
            // Retrieve oracle data from the next fee tier
            OracleData memory oracleDataOther = _getUniswapOracleData(
                uniswapFeeTiers[_indexNextProbedFeeTier].fee,
                false
            );

            // If the probed fee tier is better, continue extending its cardinality if needed
            uint256 scoreCurrentFeeTier = ((uint256(oracleData.avLiquidity) *
                uniswapFeeTiers[_indexCurrentFeeTier].fee) << 72) / uniswapFeeTiers[_indexCurrentFeeTier].tickSpacing;
            uint256 scoreNextProbedFeeTier = ((uint256(oracleDataOther.avLiquidity) * // Better higher in-range liquidity
                uniswapFeeTiers[_indexNextProbedFeeTier].fee) << 72) / // Better higher fee because it is more expensive to manipulate
                uniswapFeeTiers[_indexNextProbedFeeTier].tickSpacing; // Normlize the in-range liquidity for different tick spacings

            if (scoreCurrentFeeTier >= scoreNextProbedFeeTier) {
                // If the probed tier is worse, check another one in the next transaction
                _indexNextProbedFeeTier = (_indexNextProbedFeeTier + 1) % uint48(uniswapFeeTiers.length);
                if (_indexNextProbedFeeTier == _indexCurrentFeeTier)
                    _indexNextProbedFeeTier = (_indexNextProbedFeeTier + 1) % uint48(uniswapFeeTiers.length);
            } else if (oracleDataOther.period >= TWAP_DURATION) {
                // If the probed tier is better and the oracle is fully initialized, change to it
                _indexCurrentFeeTier = _indexNextProbedFeeTier;
                _indexNextProbedFeeTier = (_indexNextProbedFeeTier + 1) % uint48(uniswapFeeTiers.length);
            } else if (oracleDataOther.increaseCardinality) {
                // If the probed tier is better but the TWAP length is not sufficient, increase it
                uniswapV3Pools[uniswapFeeTiers[_indexNextProbedFeeTier].fee].increaseObservationCardinalityNext(
                    (TWAP_DELTA - 1) / (12 seconds) + 1
                );
            }
        }

        // Compute price
        bytes16 priceFP_ = FloatingPoint
            .fromInt(oracleData.aggLogPrice / int256(uint256(oracleData.period)))
            .mul(_LOG2_OF_TICK_FP)
            .pow_2();
        _priceFP = _truncatePrice(priceFP_); // Oracle attack protection
        emit PriceUpdated(_priceFP);
        if (priceFP_ != _priceFP) emit PriceTruncated(priceFP_);
        return _outputPrice(addrCollateralToken, _priceFP);
    }

    /*////////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Register new fee tier in Uniswap v3
    function _newFeeTier(UniswapFeeTier memory feeTier) internal returns (bool) {
        // Retrieve pool address
        address addrPool = UniswapPoolAddress.computeAddress(
            Addresses.ADDR_UNISWAPV3_FACTORY,
            UniswapPoolAddress.getPoolKey(TOKEN_B, TOKEN_A, feeTier.fee)
        );

        // Add new pool
        uniswapV3Pools[feeTier.fee] = IUniswapV3Pool(addrPool);

        // Max price gain per second
        feeTier.maxPriceAttenPerSec = FloatingPoint.ONE.sub(FloatingPoint.divu(feeTier.fee, 0.5 * 10**6)).pow(
            ONE_DIV_SIXTY
        ); // 5 blocks of 12s = 60s

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

    function _getUniswapOracleData(uint24 fee, bool instantData) private view returns (OracleData memory oracleData) {
        // Retrieve oracle info from Uniswap v3
        uint32[] memory interval = new uint32[](2);
        interval[0] = instantData ? 1 : TWAP_DURATION;
        interval[1] = 0;
        int56[] memory tickCumulatives;
        uint160[] memory liquidityCumulatives;

        try uniswapV3Pools[fee].observe(interval) returns (
            int56[] memory tickCumulatives_,
            uint160[] memory liquidityCumulatives_
        ) {
            tickCumulatives = tickCumulatives_;
            liquidityCumulatives = liquidityCumulatives_;
        } catch Error(string memory reason) {
            // If pool is not initialized (or other unexpected errors), no-op return all parameters 0.
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
                    About Uni v3 Cardinality
                     "cardinalityNow" is the current oracle array lenght with populated price information
                     "cardinalityNext" is the future cardinality
                     The oracle array is updated circularly.
                     The array's cardinality is not bumped to cardinalityNext until the last element in the array (of length cardinalityNow) is updated
                     just before a mint/swap/burn. 
                 */
            (, , observationIndex, cardinalityNow, cardinalityNext, , ) = uniswapV3Pools[fee].slot0();

            // Obtain the timestamp of the oldest observation
            uint32 blockTimestampOldest;
            bool initialized;
            (blockTimestampOldest, , , initialized) = uniswapV3Pools[fee].observations(
                (observationIndex + 1) % cardinalityNow
            );

            // The next index might not be populated if the cardinality is in the process of increasing. In this case the oldest observation is always in index 0
            if (!initialized) {
                (blockTimestampOldest, , , ) = uniswapV3Pools[fee].observations(0);
                cardinalityNow = observationIndex + 1;
            }

            // Get longest available TWAP
            interval = new uint32[](1);
            interval[0] = uint32(block.timestamp - blockTimestampOldest);

            int56[] memory tickCumulativesAgain;
            uint160[] memory liquidityCumulativesAgain;
            (tickCumulativesAgain, liquidityCumulativesAgain) = uniswapV3Pools[fee].observe(interval);
            tickCumulatives[0] = tickCumulativesAgain[0];
            liquidityCumulatives[0] = liquidityCumulativesAgain[0];

            // Estimate necessary length of the oracle if we want it to be TWAP_DURATION long
            uint256 cardinalityNeeded = (uint256(cardinalityNow) * TWAP_DURATION - 1) / interval[0] + 1;

            // Check if cardinality must increase
            if (cardinalityNeeded > cardinalityNext) oracleData.increaseCardinality = true;
        }

        // Compute average liquidity
        oracleData.avLiquidity = (uint160(interval[0]) << 128) / (liquidityCumulatives[1] - liquidityCumulatives[0]); // Liquidity is always >=1

        // Prices from Uniswap v3 are given as token1/token0
        oracleData.aggLogPrice = tickCumulatives[1] - tickCumulatives[0];

        // Duration of the observation
        oracleData.period = interval[0];
    }

    function _outputPrice(address addrCollateralToken, bytes16 priceFP_) private view returns (bytes16) {
        bytes16 priceOut = addrCollateralToken == TOKEN_B ? priceFP_.inv() : _priceFP;
        assert(priceOut.cmp(FloatingPoint.INFINITY) < 0 && priceOut.cmp(FloatingPoint.ZERO) > 0);
        return priceOut;
    }

    /**
        @dev https://uniswap.org/blog/uniswap-v3-oracles#potential-oracle-innovations
     */
    function _truncatePrice(bytes16 priceFP_) internal view returns (bytes16) {
        console.logBytes16(_priceFP);
        console.log("_tsPrice", _tsPrice);
        // console.log("block.timestamp", block.timestamp);
        bytes16 maxPriceAttenuation = uniswapFeeTiers[_indexCurrentFeeTier].maxPriceAttenPerSec.pow(
            FloatingPoint.fromUInt(block.timestamp - _tsPrice)
        );

        bytes16 priceMax = _priceFP.div(maxPriceAttenuation);
        if (priceFP_.cmp(priceMax) > 0) return priceMax;

        bytes16 priceMin = _priceFP.mul(maxPriceAttenuation);
        if (priceFP_.cmp(priceMin) < 0) return priceMin;

        return priceFP_;
    }
}
