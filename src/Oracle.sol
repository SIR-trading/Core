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

import "forge-std/console.sol";

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
    error NoUniswapV3Pool();
    error UniswapFeeTierIndexOutOfBounds();
    error OracleAlreadyInitialized();
    error OracleNotInitialized();

    event UniswapFeeTierAdded(uint24 fee);
    event OracleInitialized(address tokenA, address tokenB, uint24 feeTier);
    event OracleFeeTierChanged(address tokenA, address tokenB, uint24 feeTier);
    event PriceUpdated(address tokenA, address tokenB, int64 priceTickX42);
    event PriceTruncated(address tokenA, address tokenB, int64 priceTickX42);

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
        int56 aggLogPrice; // Aggregated log price over the period
        uint160 avLiquidity; // Average in-range liquidity over the period
        uint40 period; // Duration of the current TWAP
        uint16 cardinalityToIncrease; // Cardinality suggested for increase
    }

    struct OracleState {
        int64 tickPriceX42; // Last stored price. Q21.42
        uint40 timeStampPrice; // Timestamp of the last stored price
        uint8 indexFeeTier; // Uniswap v3 fee tier currently being used as oracle
        uint8 indexFeeTierProbeNext; // Uniswap v3 fee tier to probe next
        uint40 timeStampTier; // Timestamp of the last stored price
        bool initialized; // Whether the oracle has been initialized
        UniswapFeeTier uniswapFeeTier; // Uniswap v3 fee tier currently being used as oracle
    }

    /**
     * Constants
     */
    uint256 private constant _DURATION_UPDATE_FEE_TIER = 1 hours; // No need to test if there is a better fee tier more often than this
    int256 private constant _MAX_TICK_INC_PER_SEC = 1 << 42;
    uint40 private constant _TWAP_DELTA = 1 minutes; // When a new fee tier has larger liquidity, the TWAP array is increased in intervals of _TWAP_DELTA.
    uint40 private constant _TWAP_DURATION = 30 minutes;

    /**
     * State variables
     */
    mapping(address tokenA => mapping(address tokenB => OracleState)) public oracleStates;
    uint private _uniswapExtraFeeTiers; // Least significant 8 bits represent the length of this tightly packed array, 48 bits for each extra fee tier

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    // USE THIS TO PICK THE BEST FEE TIER https://twitter.com/guil_lambert/status/1679971498361081856 ?????

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
    function getPrice(address collateralToken, address debtToken) external view returns (int64) {
        (address tokenA, address tokenB) = _orderTokens(collateralToken, debtToken);

        // Get oracle state
        OracleState memory oracleState = oracleStates[tokenA][tokenB];
        if (!oracleState.initialized) revert OracleNotInitialized();

        // Get latest price if not stored
        if (oracleState.timeStampPrice != block.timestamp) {
            // Update price
            UniswapOracleData memory oracleData = _uniswapOracleData(
                tokenA,
                tokenB,
                oracleState.uniswapFeeTier.fee,
                false
            );
            _updatePrice(oracleState, oracleData);
        }

        // Invert price if necessary
        if (collateralToken == tokenB) return -oracleState.tickPriceX42;
        return oracleState.tickPriceX42;
    }

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
        int24 tickSpacing = IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).feeAmountTickSpacing(fee);
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
        if (oracleState.initialized) return; // No-op return because reverting would cause SIR to fail creating new vaults

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
    function updateOracleState(address collateralToken, address debtToken) external returns (int64) {
        (address tokenA, address tokenB) = _orderTokens(collateralToken, debtToken);

        // Get oracle state
        OracleState memory oracleState = oracleStates[tokenA][tokenB];
        if (!oracleState.initialized) revert OracleNotInitialized();

        // Price is updated once per block at most
        if (oracleState.timeStampPrice != block.timestamp) {
            // Update price
            UniswapOracleData memory oracleData = _uniswapOracleData(
                tokenA,
                tokenB,
                oracleState.uniswapFeeTier.fee,
                false
            );
            if (_updatePrice(oracleState, oracleData)) emit PriceTruncated(tokenA, tokenB, oracleState.tickPriceX42);

            // Update timestamp
            oracleState.timeStampPrice = uint40(block.timestamp);

            // Fee tier is updated once per block at most
            if (oracleState.timeStampPrice >= block.timestamp + _DURATION_UPDATE_FEE_TIER) {
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
                    } else if (oracleDataProbed.period >= _TWAP_DURATION) {
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
                    oracleState.indexFeeTierProbeNext =
                        (oracleState.indexFeeTierProbeNext + 1) %
                        uint8(NuniswapFeeTiers);

                // Update timestamp
                oracleState.timeStampTier = uint40(block.timestamp);
            }

            // Save new oracle state to storage
            oracleStates[tokenA][tokenB] = oracleState;
            emit PriceUpdated(tokenA, tokenB, oracleState.tickPriceX42);
        }

        // Invert price if necessary
        if (collateralToken == tokenB) return -oracleState.tickPriceX42;
        return oracleState.tickPriceX42;
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
        unchecked {
            // Compute price (buy operating with int256 we do not need to check for of/uf)
            int256 tickPriceX42 = (int256(oracleData.aggLogPrice) << 42) / int256(uint256(oracleData.period));

            // Truncate price if necessary
            int256 tickMaxIncrement = _MAX_TICK_INC_PER_SEC *
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
                    Addresses._ADDR_UNISWAPV3_FACTORY,
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
        interval[0] = instantData ? 1 : uint32(_TWAP_DURATION);
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

            // Estimate necessary length of the oracle if we want it to be _TWAP_DURATION long
            uint256 cardinalityNeeded = (uint256(cardinalityNow) * _TWAP_DURATION - 1) / interval[0] + 1;

            /**
             * Check if cardinality must increase,
             * if so we add a _TWAP_DELTA increment taking into consideration that every block takes in average 12 seconds
             */
            if (cardinalityNeeded > cardinalityNext)
                oracleData.cardinalityToIncrease = cardinalityNext + uint16((_TWAP_DELTA - 1) / (12 seconds)) + 1;
        }

        // Compute average liquidity
        oracleData.avLiquidity = (uint160(interval[0]) << 128) / (liquidityCumulatives[1] - liquidityCumulatives[0]); // Liquidity is always >=1

        // Prices from Uniswap v3 are given as token1/token0
        oracleData.aggLogPrice = tickCumulatives[1] - tickCumulatives[0];

        // Duration of the observation
        oracleData.period = interval[0];
    }

    function _orderTokens(address tokenA, address tokenB) private pure returns (address, address) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return (tokenA, tokenB);
    }
}
