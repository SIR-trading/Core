// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

// Libraries
import {TickMathPrecision} from "./libraries/TickMathPrecision.sol";
import {UniswapPoolAddress} from "./libraries/UniswapPoolAddress.sol";

// Contracts
import {Addresses} from "./libraries/Addresses.sol";
import "forge-std/Test.sol";

/**
 *     @dev Some alternative partial implementation @ https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/OracleLibrary.sol
 *     @dev Gas cost: Around 10k gas for calling Uniswap v3 oracle, plus 10k gas for each different fee pool, making a min gas of approx 20k. For reference a Uniswap trade costs around 120k.
 *     @dev Extending the TWAP memory costs 20k per slot, so divide TWAPinSeconds / 12 * 20k. So 5h TWAP at 10 gwei/gas woulc cost 0.3 ETH.
 *
 *
 *     ON MULTI-BLOCK ORALCE ATTACK
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
 *     However, the TWAP solution is not as good as it used to be in Uniswap v2 because of the concetrated liquidity idiosyncratic to v3.
 *     For example, if all the liquidity in a hypothetical pool was concentrated around the current market price, once an attacker manages
 *     to pierce throught the current price, he can the move the price of the pool to the most extreme tick at no cost. This is different to v2
 *     where the liquidity is spread in the price range 0 to ∞.
 *     For more information read https://uniswap.org/blog/uniswap-v3-oracles
 *
 *
 *     SOLUTION : TWAP WITH PRICE TRUNCATION
 *
 *     To mitigate multi-block oracle attacks in Ethereum PoS, we implement price bounds for the TWAP. That is we allow price to increase
 *     (or decrease) up to a maximum factor. However, we still want to allow for normal market fluctuations so the bounds have to be
 *     chosen very careffuly. Assume 12s blocks, and denote
 *          h = maximum organic price increase in 1 minute [min^-1]
 *          D = duration of the TWAP
 *          p & p' = TWAP price before and after 1 minute
 *     Given that h is the max price increase in 1 minute, h^(1/5) is the maximum price increase in a 12s block because 5 blocks are mined in 1 minute,
 *     or alternatively, in the "tick domain", it is log_1.0001(h^(1/5)) = log_1.0001(h)/5.
 *     With this in mind the maximum TWAP price increase is
 *          g ≥ p'/p = 1.0001^[12s/D*Σ_{i=1}^5 i*log_1.0001(h)/5] = 1.0001^[45s/D*log_1.0001(h)] = h^(45s/D)
 *     where g is the gain where truncation occurs, or
 *          G ≥ log_1.0001(p'/p) = 45s/D*log_1.0001(h)
 *     in the "tick domain".
 *
 *     For example, if we believe that the maximum price increase in 1 minute is 10% and the TWAP duration is 1h
 *          h=1.1 |
 *                |=> G ≥ 11.91 tick/min or g ≥ 1.0012 min^-1
 *          D=1h  |
 *     where g denotes the maximum TWAP organic price increase, and G in the "tick domain". More examples,
 *          h=1.1 |
 *                |=> G ≥ 5.96 tick/min
 *          D=2h  |
 *
 *          h=1.2 |
 *                |=> G ≥ 22.79 tick/min
 *          D=1h  |
 *
 *          h=1.1   |
 *                  |=> G ≥ 23.83 tick/min
 *          D=30min |
 *
 *
 *     ANALYSIS OF 5-BLOCK ORACLE ATTACK WHERE ATTACKERS MINTS AND BURNS TEA
 *
 *     Sequence of actions for an attacker that wishes to mint TEA at a cheaper price:
 *     1. Attacker moves oracle price up to its highest tick, moving the TWAP price up
 *     2. Attacker mints TEA (no previous TEA minted, so attacker will receive all fees)
 *     3. Attacker returns price to market price, profiting from the apes' losses.
 *
 *     Alternative similar attack:
 *     1. Attacker moves oracle price to its lowest tick for 5 consecutive blocks, moving the TWAP price down,
 *        profiting from the apes' losses.
 *     2. Attacker burns his TEA (we assume he was the only LPer).
 *     3. Attacker returns price to market price, profiting from the apes' losses.
 *
 *     Assumptions:
 *     - Gas fees are negligible
 *     - The fees paid to Uniswap are negligible.
 *     - The missed profits from not taking Uniswap transactions as block builder are negligible.
 *     - The attacker has inifinite capital.
 *     - The attacker performs a multi-block attack, and because of the design of Uniswap v3,
 *       it can keep the price for up to 5 blocks (1 minute) in the most extreme tick.
 *
 *     The best case scenario for the attacker is when no TEA has been minted before him, and so he is the receiver of all apes' losses.
 *     There exist two scenarios, let's tackle them separately. In the first case, the vault operates in the power zone,
 *     and in the second case it operates in the saturation zone.
 *
 *     Power Zone
 *     ──────────
 *     In the power zone, the apes' reserves follow
 *          A' = (p'/p)^(l-1)A
 *     where l>1. The attacker deposits a total of L to mint TEA and manipulates the price down so that apes lose
 *          Attacker wins = A-A' = A-A/g^(l-1) = A(1-1/g^(l-1))
 *     The cost of this attack are the fees paid when minting/burning TEA. In order to
 *     to operate in the power zone, we know L ≥ (l-1)A. Two cases:
 *          1) Attacker loses = L'*fmaam = (L+A-A')*fmaam ≥ L*fmaam ≥ (l-1)A*fmaam
 *          2) Attacker loses = L*fmaam ≥ (l-1)A*fmaam
 *     To ensure the attacker is not profitable, we must enforce:
 *          (l-1)A*fmaam ≥ A(1-1/g^(l-1))
 *     We know by Taylor series that 1/g^(l-1) ≥ 1+(l-1)(1/g-1) around g≈1, and so a tighter condition is
 *          (l-1)A*fmaam ≥ A(l-1)(1-1/g)
 *     Which results in the following equivalent conditions:
 *          fmaam ≥ 1-1/g      OR      g ≤ 1/(1-fmaam)      G ≤ -log_1.0001(1-fmaam)
 *
 *     For example,
 *          fmaam=0.01 (1% charged upon burning TEA) |=> G ≤ 100.5 tick/min
 *          fmaam=0.001 (0.1%) |=> G ≤ 10.0 tick/min
 *
 *     Saturation Zone
 *     ───────────────
 *     In the saturation zone, the LP reserve follows
 *          L' = (p/p')L
 *     The attacker deposits a total of L to mint TEA and manipulates the price down so that apes lose
 *          Attacker wins = L'-L = L(g-1)
 *     The attacker pays some fees proportional to L' to withdraw his collateral:
 *          1) Attacker loses = L'*fmaam = g*L*fmaam
 *          2) Attacker loses = L*fmaam = L*fmaam
 *     Thus, the condition for an unprofitable attack is
 *          g*L*fmaam ≥ L(g-1)  OR  L*fmaam ≥ L(g-1)
 *     Which results in the same conditions than the previous section.
 *
 *
 *     ANALYSIS OF 5-BLOCK ORACLE ATTACK WHERE ATTACKERS MINTS AND BURNS APE
 *
 *     Sequence of actions of the attacker:
 *     1. Attacker mints APE
 *     2. Attacker moves oracle price to its highest tick for 5 consecutive blocks, moving the TWAP price up,
 *        and consequently, causing apes to win over the LPers.
 *     3. Attacker burns APE getting more collateral in return.
 *     4. Attacker returns price to market price.
 *
 *     We assume the price is in the power zone where it increases polynomially,
 *          A' = (p'/p)^(l-1)A
 *     where l>1 and A is minted by the attacker.
 *          Attacker wins = A'-A = A*g^(l-1)-A = A(g^(l-1)-1)
 *     The cost of this attack are the fees paid upon minting and burning APE.
 *          Attacker loses = (A'+A)(l-1)fbase = A((g^(l-1)+1))(l-1)fbase
 *     To ensure the attacker is not profitable, we must enforce:
 *          A((g^(l-1)+1))(l-1)fbase ≥ A(g^(l-1)-1)
 *     Given that g^(l-1)≈1+(l-1)(g-1), the condition simplifies to
 *          fbase ≥ (g-1) / [2+(l-1)(g-1)]
 *     where l,g>1. A simpler sufficient condition is
 *          fbase ≥ (g-1)/2
 *     which is easily satisfied given that the values we are contemplating are around g=0.5 (50%)
 *
 *     ABOUT PRICE CALCULATION ACROSS FEE TIERS
 *
 *     A TWAP weighted across pools of different liquidity is just as weak as the weakest pool (pool with least liquiity).
 *     For this reason, we select the best pool acrooss all fee tiers with the highest liquidity by tick weighted by fee, because as
 *     shown in the previous section, the fee has a direct impact on the price manipulation cost.
 */

contract Oracle {
    error NoFeeTiers();
    error UniswapFeeTierIndexOutOfBounds();
    error OracleAlreadyInitialized();
    error OracleNotInitialized();

    event UniswapFeeTierAdded(uint24 indexed fee);
    event UniswapOracleProbed(
        address indexed tokenA,
        address indexed tokenB,
        uint24 indexed fee,
        int56 aggPriceTick,
        uint160 avLiquidity,
        uint40 period,
        uint16 cardinalityToIncrease
    );
    event OracleInitialized(
        address indexed token0,
        address indexed token1,
        uint24 indexed feeTierSelected,
        uint160 avLiquidity,
        uint40 period
    );
    event OracleFeeTierChanged(
        address indexed token0,
        address indexed token1,
        uint24 indexed feeTierPrevious,
        uint24 feeTierSelected
    );
    event PriceUpdated(address indexed token0, address indexed token1, bool indexed priceTruncated, int64 priceTickX42);

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
        IUniswapV3Pool uniswapPool; // Uniswap v3 pool
        int56 aggPriceTick; // Aggregated log price over the period
        uint160 avLiquidity; // Aggregated in-range liquidity over period. Non-initialized fee tier => avLiquidity = 0, else avLiquidity > 0
        uint40 period; // Duration of the current TWAP
        uint16 cardinalityToIncrease; // Cardinality suggested for increase
    }

    struct OracleState {
        int64 tickPriceX42; // Last stored price. Q21.42
        uint40 timeStampPrice; // Timestamp of the last stored price
        uint8 indexFeeTier; // Uniswap v3 fee tier currently being used as oracle
        uint8 indexFeeTierProbeNext; // Uniswap v3 fee tier to probe next
        uint40 timeStampFeeTier; // Timestamp of the last probed fee tier
        bool initialized; // Whether the oracle has been initialized
        UniswapFeeTier uniswapFeeTier; // Uniswap v3 fee tier currently being used as oracle
    }

    /**
     * Constants
     */
    uint256 internal constant DURATION_UPDATE_FEE_TIER = 1 hours; // No need to test if there is a better fee tier more often than this
    int64 internal constant MAX_TICK_INC_PER_SEC = 1 << 42;
    uint40 internal constant TWAP_DELTA = 1 minutes; // When a new fee tier has larger liquidity, the TWAP array is increased in intervals of TWAP_DELTA.
    uint16 internal constant CARDINALITY_DELTA = uint16((TWAP_DELTA - 1) / (12 seconds)) + 1;
    uint40 public constant TWAP_DURATION = 30 minutes;

    /**
     * State variables
     */
    mapping(address token0 => mapping(address token1 => OracleState)) public state;
    uint private _uniswapExtraFeeTiers; // Least significant 8 bits represent the length of this tightly packed array, 48 bits for each extra fee tier

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    function getUniswapFeeTiers() public view returns (UniswapFeeTier[] memory uniswapFeeTiers) {
        // Find out # of all possible fee tiers
        uint uniswapExtraFeeTiers_ = _uniswapExtraFeeTiers;
        uint numUniswapExtraFeeTiers = uint(uint8(uniswapExtraFeeTiers_));

        uniswapFeeTiers = new UniswapFeeTier[](4 + numUniswapExtraFeeTiers);
        uniswapFeeTiers[0] = UniswapFeeTier(100, 1);
        uniswapFeeTiers[1] = UniswapFeeTier(500, 10);
        uniswapFeeTiers[2] = UniswapFeeTier(3000, 60);
        uniswapFeeTiers[3] = UniswapFeeTier(10000, 200);

        // Extra fee tiers
        if (numUniswapExtraFeeTiers > 0) {
            uniswapExtraFeeTiers_ >>= 8;
            for (uint i = 0; i < numUniswapExtraFeeTiers; i++) {
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
    function getPrice(address collateralToken, address debtToken) external view returns (int64) {
        (address token0, address token1) = _orderTokens(collateralToken, debtToken);

        // Get oracle state
        OracleState memory oracleState = state[token0][token1];
        if (!oracleState.initialized) revert OracleNotInitialized();

        // Get latest price if not stored
        if (oracleState.timeStampPrice != block.timestamp) {
            // Update price
            UniswapOracleData memory oracleData = _uniswapOracleData(token0, token1, oracleState.uniswapFeeTier.fee);

            if (oracleData.period == 0) {
                /** If the fee tier has been updated this block
                    AND the cardinality of the selected fee tier is 1,
                    THEN the price is unavailable as TWAP.
                */
                (, int24 tick, , , , , ) = oracleData.uniswapPool.slot0();
                oracleData.aggPriceTick = tick;
            }

            _updatePrice(oracleState, oracleData);
        }

        // Invert price if necessary
        if (collateralToken == token1) return -oracleState.tickPriceX42;
        return oracleState.tickPriceX42;
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the oracleState for the pair of tokens
     * @notice The order of the tokens does not matter
     */
    function initialize(address tokenA, address tokenB) external {
        (tokenA, tokenB) = _orderTokens(tokenA, tokenB);

        // Get oracle state
        OracleState memory oracleState = state[tokenA][tokenB];
        if (oracleState.initialized) return; // No-op return because reverting would cause SIR to fail creating new vaults

        // Get all fee tiers
        UniswapFeeTier[] memory uniswapFeeTiers = getUniswapFeeTiers();

        // Find the best fee tier by weighted liquidity
        uint256 score;
        UniswapOracleData memory oracleData;
        UniswapOracleData memory bestOracleData;
        // console.log("----CONTRACT intermediate scores----");
        for (uint i = 0; i < uniswapFeeTiers.length; i++) {
            // Retrieve average liquidity
            oracleData = _uniswapOracleData(tokenA, tokenB, uniswapFeeTiers[i].fee);
            emit UniswapOracleProbed(
                tokenA,
                tokenB,
                uniswapFeeTiers[i].fee,
                oracleData.aggPriceTick,
                oracleData.avLiquidity,
                oracleData.period,
                oracleData.cardinalityToIncrease
            );

            if (oracleData.avLiquidity > 0) {
                /** Compute scores.
                    We weight the average liquidity by the duration of the TWAP because
                    we do not want to select a fee tier whose liquidity is easy manipulated.
                        avLiquidity * period = aggregate Liquidity
                 */
                uint256 scoreTemp = oracleData.period == 0
                    ? 1
                    : _feeTierScore(uint256(oracleData.avLiquidity) * oracleData.period, uniswapFeeTiers[i]);
                // if (oracleData.period != 0)
                // console.log("liquidity:", oracleData.avLiquidity, "| period:", oracleData.period);
                // console.log("CONTRACT tempScore is ", scoreTemp, " for fee ", uniswapFeeTiers[i].fee);

                // Update best score
                if (scoreTemp > score) {
                    oracleState.indexFeeTier = uint8(i);
                    bestOracleData = oracleData;
                    score = scoreTemp;
                }
            }
        }

        if (score == 0) revert NoFeeTiers();
        oracleState.indexFeeTierProbeNext = (oracleState.indexFeeTier + 1) % uint8(uniswapFeeTiers.length);
        oracleState.initialized = true;
        oracleState.uniswapFeeTier = uniswapFeeTiers[oracleState.indexFeeTier];

        // We increase the cardinality of the selected tier if necessary
        if (bestOracleData.cardinalityToIncrease > 0)
            bestOracleData.uniswapPool.increaseObservationCardinalityNext(bestOracleData.cardinalityToIncrease);

        // Update oracle state
        state[tokenA][tokenB] = oracleState;

        // console.log("Oracle chose fee tier", oracleState.uniswapFeeTier.fee, "with a score of", score);
        emit OracleInitialized(
            tokenA,
            tokenB,
            oracleState.uniswapFeeTier.fee,
            bestOracleData.avLiquidity,
            bestOracleData.period
        );
    }

    // Anyone can let the SIR factory know that a new fee tier exists in Uniswap V3
    function newUniswapFeeTier(uint24 fee) external {
        require(fee > 0);

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
            (uint(fee) | (uint(uint24(tickSpacing)) << 24)) <<
            (8 + 48 * (uniswapFeeTiers.length - 4));

        // Increase count
        uint numUniswapExtraFeeTiers = uint(uint8(_uniswapExtraFeeTiers));
        _uniswapExtraFeeTiers &= (2 ** 240 - 1) << 8;
        _uniswapExtraFeeTiers |= numUniswapExtraFeeTiers + 1;

        emit UniswapFeeTierAdded(fee);
    }

    /**
     * @return the TWAP price of the pair of tokens
     * @notice Update the oracle state for the pair of tokens
     * @notice The order of the tokens does not matter for updating the oracle state, it only matters if we need to retrie the price
     */
    function updateOracleState(address collateralToken, address debtToken) external returns (int64) {
        (address token0, address token1) = _orderTokens(collateralToken, debtToken);

        // Get oracle state
        OracleState memory oracleState = state[token0][token1];
        if (!oracleState.initialized) revert OracleNotInitialized();

        // Price is updated once per block at most
        if (oracleState.timeStampPrice != block.timestamp) {
            // Update price
            UniswapOracleData memory oracleData = _uniswapOracleData(token0, token1, oracleState.uniswapFeeTier.fee);
            emit UniswapOracleProbed(
                token0,
                token1,
                oracleState.uniswapFeeTier.fee,
                oracleData.aggPriceTick,
                oracleData.avLiquidity,
                oracleData.period,
                oracleData.cardinalityToIncrease
            );

            if (oracleData.period == 0) {
                /** If the fee tier has been updated this block
                    AND the cardinality of the selected fee tier is 1,
                    THEN the price is unavailable as TWAP.
                */
                (, int24 tick, , , , , ) = oracleData.uniswapPool.slot0();
                oracleData.aggPriceTick = tick;
            }

            // Updates price and emits event
            bool priceTruncated = _updatePrice(oracleState, oracleData);
            emit PriceUpdated(token0, token1, priceTruncated, oracleState.tickPriceX42);

            // Update timestamp
            oracleState.timeStampPrice = uint40(block.timestamp);

            // Fee tier is updated once per DURATION_UPDATE_FEE_TIER at most
            if (block.timestamp >= oracleState.timeStampFeeTier + DURATION_UPDATE_FEE_TIER) {
                bool checkCardinalityCurrentFeeTier;
                if (oracleData.period > 0 && oracleState.indexFeeTier != oracleState.indexFeeTierProbeNext) {
                    /** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** /
                     ** ** THIS SECTION PROBES OTHER FEE TIERS IN CASE THEIR PRICE IS MORE RELIABLE THAN THE CURRENT ONE ** ** **
                     ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** */

                    // Get current fee tier and the one we wish to probe
                    UniswapFeeTier memory uniswapFeeTierProbed = _uniswapFeeTier(oracleState.indexFeeTierProbeNext);

                    // Retrieve oracle data
                    UniswapOracleData memory oracleDataProbed = _uniswapOracleData(
                        token0,
                        token1,
                        uniswapFeeTierProbed.fee
                    );
                    emit UniswapOracleProbed(
                        token0,
                        token1,
                        uniswapFeeTierProbed.fee,
                        oracleDataProbed.aggPriceTick,
                        oracleDataProbed.avLiquidity,
                        oracleDataProbed.period,
                        oracleDataProbed.cardinalityToIncrease
                    );

                    if (oracleDataProbed.avLiquidity > 0) {
                        /** Compute scores.
                
                            Check the scores for the current fee tier and the probed one.
                            We do now weight the average liquidity by the duration of the TWAP because
                            we do not want to discard fee tiers with short TWAPs.

                            This is different than done in initialize() because a fee tier will not be selected until
                            its average liquidity is the best AND the TWAP is fully initialized.
                        */
                        uint256 score = _feeTierScore(oracleData.avLiquidity, oracleState.uniswapFeeTier);
                        uint256 scoreProbed = oracleDataProbed.period <= 1
                            ? type(uint256).max // Increase cardinality if it has never been increased
                            : _feeTierScore(oracleDataProbed.avLiquidity, uniswapFeeTierProbed);

                        if (scoreProbed > score) {
                            // If the probed fee tier is better than the current one, then we increase its cardinality if necessary
                            if (oracleDataProbed.cardinalityToIncrease > 0) {
                                oracleDataProbed.uniswapPool.increaseObservationCardinalityNext(
                                    oracleDataProbed.cardinalityToIncrease
                                );
                            }
                            // If the probed fee tier is better than the current one AND the cardinality is sufficient, switch to the probed tier
                            else if (oracleDataProbed.period >= TWAP_DURATION) {
                                oracleState.indexFeeTier = oracleState.indexFeeTierProbeNext;
                                emit OracleFeeTierChanged(
                                    token0,
                                    token1,
                                    oracleState.uniswapFeeTier.fee,
                                    uniswapFeeTierProbed.fee
                                );
                                oracleState.uniswapFeeTier = uniswapFeeTierProbed;
                            }
                        } else {
                            // If the current tier is still better, then we increase its cardinality if necessary
                            checkCardinalityCurrentFeeTier = true;
                        }
                    } else if (oracleData.cardinalityToIncrease > 0) {
                        // If the probed tier is not even initialized, then we increase the cardinality of the current tier if necessary
                        checkCardinalityCurrentFeeTier = true;
                    }
                } else {
                    checkCardinalityCurrentFeeTier = true;
                }

                if (checkCardinalityCurrentFeeTier && oracleData.cardinalityToIncrease > 0) {
                    // We increase the cardinality of the current tier if necessary
                    oracleData.uniswapPool.increaseObservationCardinalityNext(oracleData.cardinalityToIncrease);
                }

                // Point to the next fee tier to probe
                uint numUniswapFeeTiers = 4 + uint8(_uniswapExtraFeeTiers);
                oracleState.indexFeeTierProbeNext = (oracleState.indexFeeTierProbeNext + 1) % uint8(numUniswapFeeTiers);

                // Update timestamp
                oracleState.timeStampFeeTier = uint40(block.timestamp);
            }

            // Save new oracle state to storage
            state[token0][token1] = oracleState;
        }

        // Invert price if necessary
        if (collateralToken == token1) return -oracleState.tickPriceX42;
        return oracleState.tickPriceX42;
    }

    /*////////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _uniswapOracleData(
        address token0,
        address token1,
        uint24 fee
    ) private view returns (UniswapOracleData memory oracleData) {
        // Retrieve Uniswap pool
        oracleData.uniswapPool = _getUniswapPool(token0, token1, fee);

        // If pool does not exist, no-op, return all parameters 0.
        if (address(oracleData.uniswapPool).code.length == 0) return oracleData;

        // Retrieve oracle info from Uniswap v3
        uint32[] memory interval = new uint32[](2);
        interval[0] = uint32(TWAP_DURATION);
        interval[1] = 0;
        int56[] memory tickCumulatives;
        uint160[] memory liquidityCumulatives;

        try oracleData.uniswapPool.observe(interval) returns (
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

            /** About Uni v3 Cardinality
                "cardinalityNow" is the current oracle array length with populated price information
                "cardinalityNext" is the future cardinality
                The oracle array is updated circularly.
                The array's cardinality is not bumped to cardinalityNext until the last element in the array
                (of length cardinalityNow) is updated just before a mint/swap/burn.
             */
            (, , uint16 observationIndex, uint16 cardinalityNow, uint16 cardinalityNext, , ) = oracleData
                .uniswapPool
                .slot0();

            // Get oracle data at the current timestamp
            (tickCumulatives, liquidityCumulatives) = oracleData.uniswapPool.observe(new uint32[](1)); // It should never fail
            int56 tickCumulative_ = tickCumulatives[0];
            uint160 liquidityCumulative_ = liquidityCumulatives[0];

            // Exand arrays to two slots
            tickCumulatives = new int56[](2);
            liquidityCumulatives = new uint160[](2);
            tickCumulatives[1] = tickCumulative_;
            liquidityCumulatives[1] = liquidityCumulative_;

            // Get oracle data for the oldest observation possible
            uint32 blockTimestampOldest;
            bool initialized;
            if (cardinalityNow > 1) {
                // If cardinalityNow is 1, oldest (and newest) observations are at index 0.
                (blockTimestampOldest, tickCumulative_, liquidityCumulative_, initialized) = oracleData
                    .uniswapPool
                    .observations((observationIndex + 1) % cardinalityNow);
            }

            /** The next index might not be populated if the cardinality is in the process of increasing.
                In this case the oldest observation is always in index 0.
                Observation at index 0 is always initialized.
             */
            if (!initialized) {
                (blockTimestampOldest, tickCumulative_, liquidityCumulative_, ) = oracleData.uniswapPool.observations(
                    0
                );
                cardinalityNow = observationIndex + 1;
                // The 1st element of observations is always initialized
            }

            // Current TWAP duration
            interval[0] = uint32(block.timestamp - blockTimestampOldest);

            // This can only occur if the fee tier has cardinality 1
            if (interval[0] == 0) {
                // We set avLiquidity to 1, so that a fee tier with cardinality 1 is still considered a candidate.
                oracleData.cardinalityToIncrease = cardinalityNext + CARDINALITY_DELTA;
                oracleData.avLiquidity = 1;
                return oracleData;
            }

            /**
             * Check if cardinality must increase,
             * ...and if so, increment by CARDINALITY_DELTA.
             */
            uint256 cardinalityNeeded = (uint256(cardinalityNow) * TWAP_DURATION - 1) / interval[0] + 1; // Estimate necessary length of the oracle if we want it to be TWAP_DURATION long
            if (cardinalityNeeded > cardinalityNext)
                oracleData.cardinalityToIncrease = cardinalityNext + CARDINALITY_DELTA;

            tickCumulatives[0] = tickCumulative_;
            liquidityCumulatives[0] = liquidityCumulative_;
        }

        // Compute average liquidity
        // Liquidity is always >=1
        oracleData.avLiquidity = (uint160(interval[0]) << 128) / (liquidityCumulatives[1] - liquidityCumulatives[0]);

        // Aggregated price from Uniswap v3 are given as token1/token0
        oracleData.aggPriceTick = tickCumulatives[1] - tickCumulatives[0];

        // Duration of the observation
        oracleData.period = interval[0];
    }

    /**
     * @notice Updates price
     */
    function _updatePrice(
        OracleState memory oracleState,
        UniswapOracleData memory oracleData
    ) internal view returns (bool truncated) {
        unchecked {
            // Compute price (buy operating with int256 we do not need to check for of/uf)
            int256 tickPriceX42 = (int256(oracleData.aggPriceTick) << 42);

            /** When period==0, aggPriceTick is in fact the instantaneous price
                When period==1, dividing by period does not change tickPriceX42
             */
            if (oracleData.period > 1) tickPriceX42 /= int256(uint256(oracleData.period));

            if (oracleState.timeStampPrice == 0) oracleState.tickPriceX42 = int64(tickPriceX42);
            else {
                // Truncate price if necessary
                int256 tickMaxIncrement = MAX_TICK_INC_PER_SEC *
                    int256((uint256(block.timestamp) - uint256(oracleState.timeStampPrice)));
                if (tickPriceX42 > int256(oracleState.tickPriceX42) + tickMaxIncrement) {
                    oracleState.tickPriceX42 += int64(tickMaxIncrement);
                    truncated = true;
                } else if (tickPriceX42 + tickMaxIncrement < int256(oracleState.tickPriceX42)) {
                    oracleState.tickPriceX42 -= int64(tickMaxIncrement);
                    truncated = true;
                } else oracleState.tickPriceX42 = int64(tickPriceX42);
            }
        }
    }

    function _uniswapFeeTier(uint8 indexFeeTier) internal view returns (UniswapFeeTier memory uniswapFeeTier) {
        if (indexFeeTier == 0) return UniswapFeeTier(100, 1);
        if (indexFeeTier == 1) return UniswapFeeTier(500, 10);
        if (indexFeeTier == 2) return UniswapFeeTier(3000, 60);
        if (indexFeeTier == 3) return UniswapFeeTier(10000, 200);
        else {
            // Extra fee tiers
            uint uniswapExtraFeeTiers_ = _uniswapExtraFeeTiers;
            uint numUniswapExtraFeeTiers = uint(uint8(uniswapExtraFeeTiers_));
            if (indexFeeTier >= numUniswapExtraFeeTiers + 4) revert UniswapFeeTierIndexOutOfBounds();

            uniswapExtraFeeTiers_ >>= 8 + 48 * (indexFeeTier - 4);
            return UniswapFeeTier(uint24(uniswapExtraFeeTiers_), int24(uint24(uniswapExtraFeeTiers_ >> 24)));
        }
    }

    /**
        The tick TVL (liquidity in Uniswap v3) is a good criteria for selecting the best pool.
        We use the time-weighted tickTVL to score fee tiers.
        However, fee tiers with small weighting period are more susceptible to manipulation.
        Thus, instead we weight the time-weighted tickTVL by the weighting period:
            twTickTVL * period * feeTier = avLiquidity
        
        However, it may be a good idea to weight the score by the fee tier, because it is harder to move the
        price of a pool with higher fee tier. The square of the feeTier^2*tickTVL is a good predictor of
        volume (https://twitter.com/guil_lambert/status/1679971498361081856).

     */
    function _feeTierScore(
        uint256 aggOrAvLiquidity,
        UniswapFeeTier memory uniswapFeeTier
    ) private pure returns (uint256) {
        // The score is rounded up to ensure it is always >1 if aggOrAvLiquidity>0
        // console.log((((aggOrAvLiquidity * uniswapFeeTier.fee) << 72) - 1) / uint24(uniswapFeeTier.tickSpacing) + 1);
        return (((aggOrAvLiquidity * uniswapFeeTier.fee) << 72) - 1) / uint24(uniswapFeeTier.tickSpacing) + 1;
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

    function _orderTokens(address tokenA, address tokenB) private pure returns (address, address) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return (tokenA, tokenB);
    }
}
