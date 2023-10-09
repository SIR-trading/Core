// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungibleTokenPositionDescriptor.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {UniswapPoolAddress} from "src/libraries/UniswapPoolAddress.sol";
import {Oracle} from "src/Oracle.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {MockERC20} from "src/test/MockERC20.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {Tick} from "v3-core/libraries/Tick.sol";
import {ABDKMath64x64} from "abdk/ABDKMath64x64.sol";
import {IWETH9} from "v3-periphery/interfaces/external/IWETH9.sol";

contract OracleNewFeeTiersTest is Test, Oracle {
    Oracle private _oracle;

    constructor() {
        vm.createSelectFork("mainnet", 18128102);

        _oracle = new Oracle();
    }

    function test_GetUniswapFeeTiers() public {
        Oracle.UniswapFeeTier[] memory uniswapFeeTiers = _oracle.getUniswapFeeTiers();

        IUniswapV3Factory uniswapFactory = IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY);

        assertEq(uniswapFeeTiers[0].fee, 100);
        assertEq(uniswapFeeTiers[0].tickSpacing, uniswapFactory.feeAmountTickSpacing(100));
        assertEq(uniswapFeeTiers[1].fee, 500);
        assertEq(uniswapFeeTiers[1].tickSpacing, uniswapFactory.feeAmountTickSpacing(500));
        assertEq(uniswapFeeTiers[2].fee, 3000);
        assertEq(uniswapFeeTiers[2].tickSpacing, uniswapFactory.feeAmountTickSpacing(3000));
        assertEq(uniswapFeeTiers[3].fee, 10000);
        assertEq(uniswapFeeTiers[3].tickSpacing, uniswapFactory.feeAmountTickSpacing(10000));

        for (uint256 i = 4; i < uniswapFeeTiers.length; i++) {
            assertEq(uniswapFeeTiers[i].tickSpacing, uniswapFactory.feeAmountTickSpacing(uniswapFeeTiers[i].fee));
        }
    }

    function testFailFuzz_NewUniswapFeeTier(uint24 fee) public {
        _oracle.newUniswapFeeTier(fee);
    }

    function test_NewUniswapFeeTier() public {
        uint24 fee = 42;
        int24 tickSpacing = 69;
        vm.prank(Addresses._ADDR_UNISWAPV3_OWNER);
        IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(fee, tickSpacing);

        vm.expectEmit(address(_oracle));
        emit UniswapFeeTierAdded(fee);
        _oracle.newUniswapFeeTier(fee);

        test_GetUniswapFeeTiers();
    }

    function test_5NewUniswapFeeTiers() public {
        uint24 fee = 42;
        int24 tickSpacing = 69;
        vm.startPrank(Addresses._ADDR_UNISWAPV3_OWNER);
        for (uint24 i = 0; i < 5; i++) {
            IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(fee + i, tickSpacing + int24(i));
        }

        vm.stopPrank();
        for (uint24 i = 0; i < 5; i++) {
            vm.expectEmit(address(_oracle));
            emit UniswapFeeTierAdded(fee + i);
            _oracle.newUniswapFeeTier(fee + i);
        }

        test_GetUniswapFeeTiers();
    }

    function testFail_6NewUniswapFeeTiers() public {
        uint24 fee = 42;
        int24 tickSpacing = 69;
        vm.startPrank(Addresses._ADDR_UNISWAPV3_OWNER);
        for (uint24 i = 0; i < 6; i++) {
            IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(fee + i, tickSpacing + int24(i));
        }

        vm.stopPrank();
        for (uint24 i = 0; i < 6; i++) {
            vm.expectEmit(address(_oracle));
            emit UniswapFeeTierAdded(fee + i);
            _oracle.newUniswapFeeTier(fee + i);
        }
    }
}

contract OracleInitializeTest is Test, Oracle {
    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint24 indexed fee,
        int24 tickSpacing,
        address pool
    );
    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew
    );

    INonfungiblePositionManager positionManager =
        INonfungiblePositionManager(Addresses._ADDR_UNISWAPV3_POSITION_MANAGER);
    Oracle private _oracle;
    MockERC20 private _tokenA;
    MockERC20 private _tokenB;

    constructor() {
        vm.createSelectFork("mainnet", 18128102);

        _oracle = new Oracle();
        _tokenA = new MockERC20("Mock Token A", "MTA", 18);
        _tokenB = new MockERC20("Mock Token B", "MTA", 6);
    }

    function test_InitializeNoPool() public {
        vm.expectRevert(Oracle.NoFeeTiers.selector);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializeNoPoolOfBNBAndUSDT() public {
        vm.expectRevert(Oracle.NoFeeTiers.selector);
        _oracle.initialize(Addresses._ADDR_BNB, Addresses._ADDR_USDT);
    }

    function test_InitializePoolNotInitialized() public {
        uint24 fee = 100;
        _preparePoolNoInitialization(fee);

        vm.expectRevert(Oracle.NoFeeTiers.selector);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializePoolNoLiquidity() public {
        uint24 fee = 100;
        uint40 duration = 12 seconds;
        (, UniswapPoolAddress.PoolKey memory poolKey) = _preparePool(fee, 0, duration);

        vm.expectEmit(false, false, false, false);
        emit IncreaseObservationCardinalityNext(0, 0);
        vm.expectEmit(address(_oracle));
        emit OracleInitialized(poolKey.token0, poolKey.token1, fee, 1, duration);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializeTwapCardinality0() public {
        uint24 fee = 100;
        uint128 liquidity = 2 ** 64;
        (, UniswapPoolAddress.PoolKey memory poolKey) = _preparePool(fee, liquidity, 0);

        vm.expectEmit(false, false, false, false);
        emit IncreaseObservationCardinalityNext(0, 0);
        vm.expectEmit(address(_oracle));
        emit OracleInitialized(poolKey.token0, poolKey.token1, fee, 1, 0);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_Initialize() public {
        uint24 fee = 100;
        uint128 liquidity = 2 ** 64;
        uint40 duration = 12 seconds;
        UniswapPoolAddress.PoolKey memory poolKey;
        (liquidity, poolKey) = _preparePool(fee, liquidity, duration);

        vm.expectEmit(false, false, false, false);
        emit IncreaseObservationCardinalityNext(0, 0);
        vm.expectEmit(address(_oracle));
        emit OracleInitialized(poolKey.token0, poolKey.token1, fee, liquidity, duration);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializeUSDTAndWETH() public {
        vm.expectEmit(true, true, false, false, address(_oracle));
        emit OracleInitialized(Addresses._ADDR_WETH, Addresses._ADDR_USDT, 0, 0, 0);
        _oracle.initialize(Addresses._ADDR_USDT, Addresses._ADDR_WETH);

        _oracle.initialize(Addresses._ADDR_USDT, Addresses._ADDR_WETH); // No-op
    }

    function testFuzz_InitializeWithMultipleFeeTiers(
        uint128[9] memory liquidity,
        uint32[9] memory period,
        uint256 seed
    ) public {
        {
            // Conditions on liqudity parameters to avoid test failures due to rounding errors
            bool noRoundingConfusion = true;
            for (uint256 i = 0; i < 9 && noRoundingConfusion; i++) {
                // We limit the value of period to avoid overflows
                period[i] = uint32(bound(period[i], 0, 2 ^ 25));

                if (liquidity[i] == 0) continue;
                liquidity[i] = uint128(bound(liquidity[i], 0, 2 ** 100)); // To avoid exceeding max liquidity per tick

                // Check liquidity is sufficiently apart that rounding errors cause the oracle selection diverge in the test
                (uint128 min, uint128 max) = _safeRange(liquidity[i], period[i]);
                for (uint256 j = 0; j < 9; j++) {
                    if (liquidity[j] == 0 || i == j) continue;
                    if (liquidity[j] > min && liquidity[j] < max) {
                        noRoundingConfusion = false;
                        break;
                    }
                }
            }
            vm.assume(noRoundingConfusion);
        }

        // for (uint256 i = 0; i < 9; i++) {
        //     vm.writeLine("./log.log", vm.toString(liquidity[i]));
        // }
        // vm.writeLine("./log.log", "");

        // Maximize the number of fee tiers to test stress the initialization
        Oracle.UniswapFeeTier[] memory uniswapFeeTiers = new Oracle.UniswapFeeTier[](9);

        // Existing fee tiers
        uniswapFeeTiers[0] = Oracle.UniswapFeeTier(100, 1);
        uniswapFeeTiers[1] = Oracle.UniswapFeeTier(500, 10);
        uniswapFeeTiers[2] = Oracle.UniswapFeeTier(3000, 60);
        uniswapFeeTiers[3] = Oracle.UniswapFeeTier(10000, 200);

        // Made up fee tiers
        uniswapFeeTiers[4] = Oracle.UniswapFeeTier(42, 7);
        uniswapFeeTiers[5] = Oracle.UniswapFeeTier(69, 99);
        uniswapFeeTiers[6] = Oracle.UniswapFeeTier(300, 6);
        uniswapFeeTiers[7] = Oracle.UniswapFeeTier(9999, 199);
        uniswapFeeTiers[8] = Oracle.UniswapFeeTier(100000, 1);

        // Add them to Uniswap v3
        vm.startPrank(Addresses._ADDR_UNISWAPV3_OWNER);
        for (uint256 i = 4; i < 9; i++) {
            IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(
                uniswapFeeTiers[i].fee,
                uniswapFeeTiers[i].tickSpacing
            );
        }
        vm.stopPrank();

        // Add them the oracle
        for (uint256 i = 4; i < 9; i++) {
            _oracle.newUniswapFeeTier(uniswapFeeTiers[i].fee);
        }

        // Deploy fee tiers in random order
        UniswapPoolAddress.PoolKey memory poolKey;
        uint8[9] memory order = _shuffle1To9(seed);
        uint256[9] memory timeInc;
        for (uint256 i = 0; i < 9; i++) {
            uint j = order[i];

            if (liquidity[j] == 0 && period[j] == 0) {
                _preparePoolNoInitialization(uniswapFeeTiers[j].fee);
            } else {
                (liquidity[j], poolKey) = _preparePool(uniswapFeeTiers[j].fee, liquidity[j], uint32(period[j]));
                if (liquidity[j] == 0) liquidity[j] = 1;
            }

            for (j = 0; j <= i; j++) {
                timeInc[order[j]] += period[order[i]];
            }
        }

        // Score fee tiers
        uint256 bestScore;
        uint256 iBest;
        UniswapPoolAddress.PoolKey memory bestPoolKey;
        for (uint256 i = 0; i < 9; i++) {
            period[i] = TWAP_DURATION < timeInc[i] ? uint32(TWAP_DURATION) : uint32(timeInc[i]);

            uint256 aggLiquidity = liquidity[i] * period[i];
            uint256 tempScore = aggLiquidity == 0
                ? 0
                : (((aggLiquidity * uniswapFeeTiers[i].fee) << 72) - 1) / uint24(uniswapFeeTiers[i].tickSpacing) + 1;

            if (tempScore >= bestScore) {
                iBest = i;
                bestScore = tempScore;
                bestPoolKey = poolKey;
            }
        }

        // Check the correct fee tier is selected
        if (bestScore == 0) {
            vm.expectRevert();
        } else {
            vm.expectEmit(true, true, true, false, address(_oracle));
            emit OracleInitialized(
                poolKey.token0,
                poolKey.token1,
                uniswapFeeTiers[iBest].fee,
                0, // Rounding errors make it almost impossible to test this
                uint40(period[iBest])
            );
        }

        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    // Test when pool exists but not initialized, or TWAP is not old enough
    // Check the event that shows the liquidity and other parameters

    /*////////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _preparePoolNoInitialization(uint24 fee) private returns (UniswapPoolAddress.PoolKey memory poolKey) {
        // Deploy Uniswap v3 pool
        UniswapPoolAddress.getPoolKey(address(_tokenA), address(_tokenB), fee);
        IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).createPool(address(_tokenA), address(_tokenB), fee);

        poolKey = UniswapPoolAddress.getPoolKey(address(_tokenA), address(_tokenB), fee);
    }

    function _preparePool(
        uint24 fee,
        uint128 liquidity,
        uint40 duration
    ) private returns (uint128 liquidityAdj, UniswapPoolAddress.PoolKey memory poolKey) {
        // Start at price = 1
        uint160 sqrtPriceX96 = 2 ** 96;

        // Create and initialize Uniswap v3 pool
        poolKey = UniswapPoolAddress.getPoolKey(address(_tokenA), address(_tokenB), fee);
        positionManager.createAndInitializePoolIfNecessary(poolKey.token0, poolKey.token1, fee, sqrtPriceX96);

        if (liquidity > 0) {
            // Compute min and max tick
            address pool = UniswapPoolAddress.computeAddress(Addresses._ADDR_UNISWAPV3_FACTORY, poolKey);
            int24 tickSpac = IUniswapV3Pool(pool).tickSpacing();
            int24 minTick = (TickMath.MIN_TICK / tickSpac) * tickSpac;
            int24 maxTick = (TickMath.MAX_TICK / tickSpac) * tickSpac;

            // Compute amounts
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(minTick),
                TickMath.getSqrtRatioAtTick(maxTick),
                liquidity
            );

            if (amount0 != 0 || amount1 != 0) {
                {
                    // Reorder tokens
                    MockERC20 token0 = MockERC20(poolKey.token0);
                    MockERC20 token1 = MockERC20(poolKey.token1);

                    // Mint mock tokens
                    token0.mint(amount0);
                    token1.mint(amount1);

                    // Approve tokens
                    token0.approve(address(positionManager), amount0);
                    token1.approve(address(positionManager), amount1);
                }

                // Add liquidity
                (, liquidityAdj, , ) = positionManager.mint(
                    INonfungiblePositionManager.MintParams({
                        token0: poolKey.token0,
                        token1: poolKey.token1,
                        fee: fee,
                        tickLower: minTick,
                        tickUpper: maxTick,
                        amount0Desired: amount0,
                        amount1Desired: amount1,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: address(this),
                        deadline: block.timestamp
                    })
                );
            }
        }

        /** Price: The uniswap oracle extrapolates the price for the most recent observations by simply assuming
                it's the same price as the last observation. So it suffices to just skip the duration of the TWAP.

                Liquidity: The uniswap oracle extrapolaes the liquidity for the most recent observations by simply
                taking the last observation AND assuming the liquidity since the last observation is the value
                store in the variable 'liquidity'. Notice this is different than the price. So it is important to
                keep in mind the liquidity at the beginning of the transaction.

                In conclusion, 1 single slot (all oracles are initialized with 1 slot) is enough to test the oracle.
            */
        skip(duration);
    }

    function _safeRange(uint128 liquidity, uint32 period) private pure returns (uint128 min, uint128 max) {
        if (liquidity == 0 || period == 0) return (liquidity, liquidity);

        // This approximation error is based on how the Uniswap oracle computes the liquidity cumulatives
        uint128 delta = uint128((((uint256(liquidity) ** 2) - 1) >> 128) / uint256(period) + 1);
        min = liquidity - delta;
        max = liquidity + delta;
    }

    function _shuffle1To9(uint256 seed) public pure returns (uint8[9] memory) {
        uint8[9] memory sequence;

        // Initialize the array with values 1 to 9
        for (uint8 i = 1; i < 9; i++) {
            sequence[i] = i;
        }

        // Shuffle using the Fisher-Yates algorithm
        for (uint8 i = uint8(sequence.length) - 1; i > 0 && i < 9; ) {
            uint8 j = uint8((uint256(keccak256(abi.encodePacked(seed, i))) % (i + 1)));

            // Swap sequence[i] with sequence[j]
            (sequence[i], sequence[j]) = (sequence[j], sequence[i]);

            unchecked {
                i--;
            }
        }

        return sequence;
    }
}

contract OracleGetPrice is Test, Oracle {
    using ABDKMath64x64 for int128;

    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew
    );

    INonfungiblePositionManager positionManager =
        INonfungiblePositionManager(Addresses._ADDR_UNISWAPV3_POSITION_MANAGER);
    ISwapRouter swapRouter = ISwapRouter(Addresses._ADDR_UNISWAPV3_SWAP_ROUTER);
    Oracle private _oracle;
    MockERC20 private _tokenA;
    MockERC20 private _tokenB;
    UniswapPoolAddress.PoolKey private _poolKey;

    uint256 immutable forkId;

    constructor() {
        // We fork after this tx because it allows us to test a 0-TWAP.
        forkId = vm.createSelectFork("mainnet", 18149275);

        _oracle = new Oracle();

        _tokenA = new MockERC20("Mock Token A", "MTA", 18);
        _tokenB = new MockERC20("Mock Token B", "MTA", 6);

        uint24 feeTier = 100;
        uint128 liquidity = 2 ** 10; // Small liquidity to push the price easily
        (, _poolKey) = _preparePool(feeTier, liquidity);

        vm.expectEmit();
        emit IncreaseObservationCardinalityNext(1, 1 + CARDINALITY_DELTA);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    // function setUp() public {
    //     vm.selectFork(forkId);
    // }

    function test_getPriceNotInitialized() public {
        vm.expectRevert(Oracle.OracleNotInitialized.selector);
        _oracle.getPrice(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    }

    function test_updateOracleStateNotInitialized() public {
        vm.expectRevert(Oracle.OracleNotInitialized.selector);
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    }

    function test_getPriceNoTWAP() public returns (int64 tickPriceX42) {
        // At block 18149275 the FRAX-alUSD oracle is updated.

        // The time of the mainnet fork is suitable chosen to
        vm.expectEmit();
        emit IncreaseObservationCardinalityNext(1, 1 + CARDINALITY_DELTA);
        _oracle.initialize(Addresses._ADDR_FRAX, Addresses._ADDR_ALUSD);

        tickPriceX42 = _oracle.getPrice(Addresses._ADDR_FRAX, Addresses._ADDR_ALUSD);

        UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
            Addresses._ADDR_FRAX,
            Addresses._ADDR_ALUSD,
            500
        );
        address uniswapPool = UniswapPoolAddress.computeAddress(Addresses._ADDR_UNISWAPV3_FACTORY, poolKey);
        (, int24 tick, uint16 observationIndex, uint16 observationCardinality, , , ) = IUniswapV3Pool(uniswapPool)
            .slot0();
        (uint32 blockTimestampOldest, , , ) = IUniswapV3Pool(uniswapPool).observations(observationIndex);

        assertEq(tickPriceX42, int256(tick) << 42);
        assertEq(observationIndex, 0);
        assertEq(observationCardinality, 1);
        assertEq(blockTimestampOldest, block.timestamp);
    }

    function test_updateOracleStateNoTWAP() public {
        // At block 18149275 the FRAX-alUSD oracle is updated.

        // The time of the mainnet fork is suitable chosen to
        vm.expectEmit();
        emit IncreaseObservationCardinalityNext(1, 1 + CARDINALITY_DELTA);
        _oracle.initialize(Addresses._ADDR_FRAX, Addresses._ADDR_ALUSD);

        int64 tickPriceX42 = _oracle.updateOracleState(Addresses._ADDR_FRAX, Addresses._ADDR_ALUSD);

        assertEq(tickPriceX42, _oracle.getPrice(Addresses._ADDR_FRAX, Addresses._ADDR_ALUSD));
    }

    function test_getPriceUSDCAndWETH() public {
        _oracle.initialize(Addresses._ADDR_WETH, Addresses._ADDR_USDC);

        int64 tickPriceX42 = _oracle.getPrice(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
        assertEq(tickPriceX42, _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC));

        /** Notice that to compute the actual price of ETH/USDC we would do
                1 Eth = 10^18 * 1.0001^(tickPriceX42/2^42) * 10^-6 USDC
            because of the decimals.
         */
        int128 log2TickBase = ABDKMath64x64.divu(10001, 10000).log_2(); // log_2(1.0001)
        int128 tickPriceX64 = ABDKMath64x64.divi(tickPriceX42, 2 ** 42);
        uint ETHdivUSDC = tickPriceX64.mul(log2TickBase).exp_2().mul(ABDKMath64x64.fromUInt(10 ** 12)).toUInt();

        assertEq((ETHdivUSDC / 100) * 100, 1600); // Price of ETH on Sep-13-2023 rounded to 2 digits
    }

    function test_getPriceUSDTAndWETH() public {
        _oracle.initialize(Addresses._ADDR_WETH, Addresses._ADDR_USDT);

        int64 tickPriceX42 = _oracle.getPrice(Addresses._ADDR_WETH, Addresses._ADDR_USDT);
        assertEq(tickPriceX42, _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDT));

        /** Notice that to compute the actual price of ETH/USDT we would do
                1 Eth = 10^18 * 1.0001^(tickPriceX42/2^42) * 10^-6 USDT
            because of the decimals.
         */
        int128 log2TickBase = ABDKMath64x64.divu(10001, 10000).log_2(); // log_2(1.0001)
        int128 tickPriceX64 = ABDKMath64x64.divi(tickPriceX42, 2 ** 42);
        uint ETHdivUSDT = tickPriceX64.mul(log2TickBase).exp_2().mul(ABDKMath64x64.fromUInt(10 ** 12)).toUInt();

        assertEq((ETHdivUSDT / 100) * 100, 1600); // Price of ETH on Sep-13-2023 rounded to 2 digits
    }

    function testFuzz_getPriceTruncated(uint16 periodTick0) public {
        uint256 maxPeriodTick0 = TWAP_DURATION -
            (uint256(TWAP_DURATION) ** 2 * uint64(MAX_TICK_INC_PER_SEC)) /
            (uint256(887271) << 42) -
            1;
        periodTick0 = uint16(bound(periodTick0, 0, maxPeriodTick0));

        // Store price in the oracle
        int64 tickPriceX42 = _oracle.updateOracleState(address(_tokenA), address(_tokenB));
        assertEq(tickPriceX42, 0);

        // Skip ahead so Uni v3 oracle can be update in the new positions
        skip(periodTick0);

        // Move price to tick = 887271
        _swap(_poolKey.fee, false, 10 ** 30);

        // Skip ahead so oracle can be manipulated with the extreme tick
        skip(TWAP_DURATION - periodTick0);

        tickPriceX42 = _oracle.getPrice(address(_tokenA), address(_tokenB));
        assertEq(tickPriceX42, -int40(TWAP_DURATION) * MAX_TICK_INC_PER_SEC);

        vm.expectEmit();
        emit PriceUpdated(
            _poolKey.token0,
            _poolKey.token1,
            true,
            address(_tokenA) == _poolKey.token0 ? tickPriceX42 : -tickPriceX42
        );
        tickPriceX42 = _oracle.updateOracleState(address(_tokenA), address(_tokenB));
        assertEq(tickPriceX42, -int40(TWAP_DURATION) * MAX_TICK_INC_PER_SEC);
    }

    function testFuzz_getPriceNotTruncated(uint16 periodTick0) public {
        uint256 minPeriodTick0 = TWAP_DURATION -
            (uint256(TWAP_DURATION) ** 2 * uint64(MAX_TICK_INC_PER_SEC)) /
            (uint256(887271) << 42);
        periodTick0 = uint16(bound(periodTick0, minPeriodTick0, TWAP_DURATION));

        // Store price in the oracle
        int64 tickPriceX42 = _oracle.updateOracleState(address(_tokenA), address(_tokenB));
        assertEq(tickPriceX42, 0);

        // Skip ahead so Uni v3 oracle can be update in the new positions
        skip(periodTick0);

        // Move price to tick = 887271
        _swap(_poolKey.fee, false, 10 ** 30);

        // Skip ahead so oracle can be manipulated with the extreme tick
        skip(TWAP_DURATION - periodTick0);

        int64 expTickPriceX42 = int64(
            ((int256(887271) << 42) * int40(TWAP_DURATION - periodTick0)) / int40(TWAP_DURATION)
        );
        tickPriceX42 = _oracle.getPrice(address(_tokenA), address(_tokenB));
        if (address(_tokenA) == _poolKey.token0) assertEq(tickPriceX42, expTickPriceX42);
        else assertEq(tickPriceX42, -expTickPriceX42);

        vm.expectEmit();
        emit PriceUpdated(_poolKey.token0, _poolKey.token1, false, expTickPriceX42);
        tickPriceX42 = _oracle.updateOracleState(address(_tokenA), address(_tokenB));
        if (address(_tokenA) == _poolKey.token0) assertEq(tickPriceX42, expTickPriceX42);
        else assertEq(tickPriceX42, -expTickPriceX42);
    }

    /*////////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _preparePool(
        uint24 fee,
        uint128 liquidity
    ) private returns (uint128 liquidityAdj, UniswapPoolAddress.PoolKey memory poolKey) {
        // Start at price = 1 or tick = 0
        uint160 sqrtPriceX96 = 2 ** 96;

        // Create and initialize Uniswap v3 pool
        poolKey = UniswapPoolAddress.getPoolKey(address(_tokenA), address(_tokenB), fee);
        positionManager.createAndInitializePoolIfNecessary(poolKey.token0, poolKey.token1, fee, sqrtPriceX96);

        if (liquidity > 0) {
            // Compute min and max tick
            address pool = UniswapPoolAddress.computeAddress(Addresses._ADDR_UNISWAPV3_FACTORY, poolKey);
            int24 tickSpac = IUniswapV3Pool(pool).tickSpacing();
            int24 minTick = (TickMath.MIN_TICK / tickSpac) * tickSpac;
            int24 maxTick = (TickMath.MAX_TICK / tickSpac) * tickSpac;

            // Compute amounts
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(minTick),
                TickMath.getSqrtRatioAtTick(maxTick),
                liquidity
            );

            if (amount0 != 0 || amount1 != 0) {
                {
                    // Reorder tokens
                    MockERC20 token0 = MockERC20(poolKey.token0);
                    MockERC20 token1 = MockERC20(poolKey.token1);

                    // Mint mock tokens
                    token0.mint(amount0);
                    token1.mint(amount1);

                    // Approve tokens
                    token0.approve(address(positionManager), amount0);
                    token1.approve(address(positionManager), amount1);
                }

                // Add liquidity
                (, liquidityAdj, , ) = positionManager.mint(
                    INonfungiblePositionManager.MintParams({
                        token0: poolKey.token0,
                        token1: poolKey.token1,
                        fee: fee,
                        tickLower: minTick,
                        tickUpper: maxTick,
                        amount0Desired: amount0,
                        amount1Desired: amount1,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: address(this),
                        deadline: block.timestamp
                    })
                );
            }
        }
    }

    function _swap(uint24 feeTier, bool buyTokenA, uint256 amountIn) private returns (uint256 amountOut) {
        // Mint mock tokens
        MockERC20 tokenIn;
        MockERC20 tokenOut;
        if (buyTokenA) {
            tokenIn = _tokenB;
            tokenOut = _tokenA;
        } else {
            tokenIn = _tokenA;
            tokenOut = _tokenB;
        }

        // Mint and approve tokens
        tokenIn.mint(amountIn);
        tokenIn.approve(address(swapRouter), amountIn);

        UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
            address(tokenIn),
            address(tokenOut),
            feeTier
        );
        address pool = UniswapPoolAddress.computeAddress(Addresses._ADDR_UNISWAPV3_FACTORY, poolKey);
        (, int24 tick, , , , , ) = IUniswapV3Pool(pool).slot0();

        // Swap
        amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: feeTier,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        (, tick, , , , , ) = IUniswapV3Pool(pool).slot0();
    }
}

contract OracleProbingFeeTiers is Test, Oracle {
    INonfungiblePositionManager positionManager =
        INonfungiblePositionManager(Addresses._ADDR_UNISWAPV3_POSITION_MANAGER);
    ISwapRouter swapRouter = ISwapRouter(Addresses._ADDR_UNISWAPV3_SWAP_ROUTER);
    Oracle private _oracle;
    MockERC20 private usdc = MockERC20(Addresses._ADDR_USDC);
    IWETH9 private weth = IWETH9(Addresses._ADDR_WETH);

    uint256 immutable forkId;

    constructor() {
        // We fork after this tx because it allows us to test a 0-TWAP.
        forkId = vm.createSelectFork("mainnet", 18149275);

        _oracle = new Oracle();
        _oracle.initialize(Addresses._ADDR_WETH, Addresses._ADDR_USDC); // It picks feeTier = 500
    }

    function test_nextFeeTierNotProbed() public {
        // Retrieve/store price
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 500, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 3000, 0, 0, 0, 0);
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);

        // Hugely increase liquidity rest of fee tiers
        _addLiquidity(100, 2 ** 70);
        _addLiquidity(3000, 2 ** 70);
        _addLiquidity(10000, 2 ** 70);

        skip(DURATION_UPDATE_FEE_TIER - 1);

        // Retrieve/store price but do NOT PROBE tier
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 500, 0, 0, 0, 0);
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    }

    /// @dev This test in combination with the previous one tests that an event is NOT emitted.
    function testFail_nextFeeTierNotProbed() public {
        test_nextFeeTierNotProbed();

        // Retrieve/store price but do NOT PROBE tier
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 500, 0, 0, 0, 0);

        // This one should fail because not enough time has elapsed to probe a new tier.
        vm.expectEmit(false, false, false, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 10000, 0, 0, 0, 0);
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    }

    function test_nextFeeTierProbedAndSwitched() public {
        // Retrieve/store price
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 500, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 3000, 0, 0, 0, 0);
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);

        // Hugely increase liquidity rest of fee tiers
        _addLiquidity(100, 2 ** 70);
        _addLiquidity(3000, 2 ** 70);
        _addLiquidity(10000, 2 ** 70);

        skip(DURATION_UPDATE_FEE_TIER);

        // Retrieve/store price but do NOT PROBE tier
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 500, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 10000, 0, 0, 0, 0);
        vm.expectEmit();
        emit OracleFeeTierChanged(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 500, 10000);
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    }

    function test_newFeeTierProbedAndNotSwitched() public {
        // Create new fee tier
        uint24 newFeeTier = 69;
        int24 newTickSpacing = 4;

        // Enable it in Uniswap v3
        vm.startPrank(Addresses._ADDR_UNISWAPV3_OWNER);
        IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(newFeeTier, newTickSpacing);
        vm.stopPrank();

        // Enable it in the oracle
        _oracle.newUniswapFeeTier(newFeeTier);

        // Probe tier 3000
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
        skip(DURATION_UPDATE_FEE_TIER);

        // Probe tier 10000 (last tier in the list)
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
        skip(DURATION_UPDATE_FEE_TIER);

        // Create pool and add liquidity
        _preparePool(newFeeTier, 2 ** 70);
        skip(TWAP_DURATION - 1); // So that TWAP is not old enough to be selected

        // Probe new tier
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, newFeeTier, 0, 0, 0, 0);
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    }

    function testFail_newFeeTierProbedAndNotSwitched() public {
        // Create new fee tier
        uint24 newFeeTier = 69;
        int24 newTickSpacing = 4;

        // Enable it in Uniswap v3
        vm.startPrank(Addresses._ADDR_UNISWAPV3_OWNER);
        IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(newFeeTier, newTickSpacing);
        vm.stopPrank();

        // Enable it in the oracle
        _oracle.newUniswapFeeTier(newFeeTier);

        // Probe tier 3000
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
        skip(DURATION_UPDATE_FEE_TIER);

        // Probe tier 10000 (last tier in the list)
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
        skip(DURATION_UPDATE_FEE_TIER);

        // Create pool and add liquidity
        _preparePool(newFeeTier, 2 ** 70);
        skip(TWAP_DURATION - 1); // So that TWAP is not old enough to be selected

        // Probe new tier
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, newFeeTier, 0, 0, 0, 0);
        vm.expectEmit(false, false, false, false);
        emit OracleFeeTierChanged(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 500, newFeeTier);
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    }

    function test_newFeeTierProbedAndSwitched() public {
        // Create new fee tier
        uint24 newFeeTier = 69;
        int24 newTickSpacing = 4;

        // Enable it in Uniswap v3
        vm.startPrank(Addresses._ADDR_UNISWAPV3_OWNER);
        IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(newFeeTier, newTickSpacing);
        vm.stopPrank();

        // Enable it in the oracle
        _oracle.newUniswapFeeTier(newFeeTier);

        // Probe tier 3000
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
        skip(DURATION_UPDATE_FEE_TIER);

        // Probe tier 10000 (last tier in the list)
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
        skip(DURATION_UPDATE_FEE_TIER);

        // Create pool and add liquidity
        _preparePool(newFeeTier, 2 ** 70);
        skip(TWAP_DURATION); // TWAP is old enough to be selected

        // Probe new tier
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, newFeeTier, 0, 0, 0, 0);
        vm.expectEmit();
        emit OracleFeeTierChanged(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 500, newFeeTier);
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    }

    function test_newFeeTierProbedAndSwitchedAndNextProbedTierIsCorrect() public {
        test_newFeeTierProbedAndSwitched();

        skip(DURATION_UPDATE_FEE_TIER);

        // Probe 1st tier (100 bp) again
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 69, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 100, 0, 0, 0, 0);
        _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    }

    // function test_newFeeTierProbedAndCardinalityIncreased() public {
    //     // Create new fee tier
    //     uint24 newFeeTier = 69;
    //     int24 newTickSpacing = 4;

    //     // Enable it in Uniswap v3
    //     vm.startPrank(Addresses._ADDR_UNISWAPV3_OWNER);
    //     IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(newFeeTier, newTickSpacing);
    //     vm.stopPrank();

    //     // Enable it in the oracle
    //     _oracle.newUniswapFeeTier(newFeeTier);

    //     // Probe tier 3000
    //     _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    //     skip(DURATION_UPDATE_FEE_TIER);

    //     // Probe tier 10000 (last tier in the list)
    //     _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    //     skip(DURATION_UPDATE_FEE_TIER);

    //     // Create pool and add liquidity
    //     uint256 tokenId = _preparePool(newFeeTier, 2 ** 70);
    //     // skip(TWAP_DURATION); // TWAP is old enough to be selected

    //     // // Probe new tier
    //     // vm.expectEmit(true, true, true, false);
    //     // emit UniswapOracleProbed(Addresses._ADDR_USDC, Addresses._ADDR_WETH, newFeeTier, 0, 0, 0, 0);
    //     // vm.expectEmit();
    //     // emit OracleFeeTierChanged(Addresses._ADDR_USDC, Addresses._ADDR_WETH, 500, newFeeTier);
    //     // _oracle.updateOracleState(Addresses._ADDR_WETH, Addresses._ADDR_USDC);
    // }

    /*////////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _addLiquidity(uint24 fee, uint128 liquidity) private returns (uint256 tokenId) {
        require(liquidity > 0, "liquidity must be > 0");

        // Get sqrtPriceX96
        UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
            Addresses._ADDR_WETH,
            Addresses._ADDR_USDC,
            fee
        );
        address pool = UniswapPoolAddress.computeAddress(Addresses._ADDR_UNISWAPV3_FACTORY, poolKey);
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = IUniswapV3Pool(pool).slot0();

        // Compute min and max tick
        int24 tickSpac = IUniswapV3Pool(pool).tickSpacing();
        int24 minTick = ((tick - 2 * tickSpac) / tickSpac) * tickSpac;
        int24 maxTick = ((tick + 2 * tickSpac) / tickSpac) * tickSpac;

        // Compute amounts
        (uint256 amountUSDC, uint256 amountWETH) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(minTick),
            TickMath.getSqrtRatioAtTick(maxTick),
            liquidity
        );

        if (amountUSDC != 0 || amountWETH != 0) {
            // Mint mock tokens
            if (amountUSDC != 0) {
                vm.prank(Addresses._ADDR_USDC_MINTER);
                usdc.mint(address(this), amountUSDC);
                usdc.approve(address(positionManager), amountUSDC);
            }

            if (amountWETH != 0) {
                vm.deal(address(this), amountWETH);
                weth.deposit{value: amountWETH}();
                weth.approve(address(positionManager), amountWETH);
            }

            // Add liquidity
            (tokenId, , , ) = positionManager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: address(usdc),
                    token1: address(weth),
                    fee: fee,
                    tickLower: minTick,
                    tickUpper: maxTick,
                    amount0Desired: amountUSDC,
                    amount1Desired: amountWETH,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );
        }
    }

    function _preparePool(uint24 fee, uint128 liquidity) private returns (uint256 tokenId) {
        // Start at price = 1 or tick = 0
        uint160 sqrtPriceX96 = 24721 * 2 ** 96;

        // Create and initialize Uniswap v3 pool
        UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
            Addresses._ADDR_WETH,
            Addresses._ADDR_USDC,
            fee
        );
        positionManager.createAndInitializePoolIfNecessary(poolKey.token0, poolKey.token1, fee, sqrtPriceX96);

        (tokenId) = _addLiquidity(fee, liquidity);
    }
}

// DO SOME INVARIANT TESTING HERE
