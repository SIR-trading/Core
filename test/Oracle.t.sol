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
import {SwapMath} from "v3-core/libraries/SwapMath.sol";
import {ABDKMath64x64} from "abdk/ABDKMath64x64.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";

contract OracleNewFeeTiersTest is Test, Oracle {
    Oracle private _oracle;

    constructor() Oracle(Addresses.ADDR_UNISWAPV3_FACTORY) {
        vm.createSelectFork("mainnet", 18128102);

        _oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);
    }

    function test_GetUniswapFeeTiers() public view {
        SirStructs.UniswapFeeTier[] memory uniswapFeeTiers = _oracle.getUniswapFeeTiers();

        IUniswapV3Factory uniswapFactory = IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY);

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
        vm.prank(Addresses.ADDR_UNISWAPV3_OWNER);
        IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY).enableFeeAmount(fee, tickSpacing);

        vm.expectEmit(address(_oracle));
        emit UniswapFeeTierAdded(fee);
        _oracle.newUniswapFeeTier(fee);

        test_GetUniswapFeeTiers();
    }

    function test_5NewUniswapFeeTiers() public {
        uint24 fee = 42;
        int24 tickSpacing = 69;
        vm.startPrank(Addresses.ADDR_UNISWAPV3_OWNER);
        for (uint24 i = 0; i < 5; i++) {
            IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY).enableFeeAmount(fee + i, tickSpacing + int24(i));
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
        vm.startPrank(Addresses.ADDR_UNISWAPV3_OWNER);
        for (uint24 i = 0; i < 6; i++) {
            IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY).enableFeeAmount(fee + i, tickSpacing + int24(i));
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
        INonfungiblePositionManager(Addresses.ADDR_UNISWAPV3_POSITION_MANAGER);
    Oracle private _oracle;
    MockERC20 private _tokenA;
    MockERC20 private _tokenB;

    constructor() Oracle(Addresses.ADDR_UNISWAPV3_FACTORY) {
        vm.createSelectFork("mainnet", 18128102);

        _oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);
        _tokenA = new MockERC20("Mock Token A", "MTA", 18);
        _tokenB = new MockERC20("Mock Token B", "MTA", 6);
    }

    function test_InitializeNoPool() public {
        vm.expectRevert(Oracle.NoUniswapPool.selector);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializeNoPoolOfBNBAndUSDT() public {
        vm.expectRevert(Oracle.NoUniswapPool.selector);
        _oracle.initialize(Addresses.ADDR_BNB, Addresses.ADDR_USDT);
    }

    function test_InitializePoolNotInitialized() public {
        uint24 fee = 100;
        _preparePoolNoInitialization(fee);

        vm.expectRevert(Oracle.NoUniswapPool.selector);
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
        UniswapPoolAddress.PoolKey memory poolKey;
        (liquidity, poolKey) = _preparePool(fee, liquidity, 0);

        vm.expectEmit(false, false, false, false);
        emit IncreaseObservationCardinalityNext(0, 0);
        vm.expectEmit(address(_oracle));
        console.log(poolKey.token0, poolKey.token1, fee, 1);
        emit OracleInitialized(poolKey.token0, poolKey.token1, fee, liquidity, 1);
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
        emit OracleInitialized(Addresses.ADDR_WETH, Addresses.ADDR_USDT, 0, 0, 0);
        _oracle.initialize(Addresses.ADDR_USDT, Addresses.ADDR_WETH);

        _oracle.initialize(Addresses.ADDR_USDT, Addresses.ADDR_WETH); // No-op
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
                period[i] = uint32(_bound(period[i], 0, 2 ^ 25));

                if (liquidity[i] == 0) continue;
                liquidity[i] = uint128(_bound(liquidity[i], 0, 2 ** 100)); // To avoid exceeding max liquidity per tick

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
        SirStructs.UniswapFeeTier[] memory uniswapFeeTiers = new SirStructs.UniswapFeeTier[](9);

        // Existing fee tiers
        uniswapFeeTiers[0] = SirStructs.UniswapFeeTier(100, 1);
        uniswapFeeTiers[1] = SirStructs.UniswapFeeTier(500, 10);
        uniswapFeeTiers[2] = SirStructs.UniswapFeeTier(3000, 60);
        uniswapFeeTiers[3] = SirStructs.UniswapFeeTier(10000, 200);

        // Made up fee tiers
        uniswapFeeTiers[4] = SirStructs.UniswapFeeTier(42, 7);
        uniswapFeeTiers[5] = SirStructs.UniswapFeeTier(69, 99);
        uniswapFeeTiers[6] = SirStructs.UniswapFeeTier(300, 6);
        uniswapFeeTiers[7] = SirStructs.UniswapFeeTier(9999, 199);
        uniswapFeeTiers[8] = SirStructs.UniswapFeeTier(100000, 1);

        // Add them to Uniswap v3
        vm.startPrank(Addresses.ADDR_UNISWAPV3_OWNER);
        for (uint256 i = 4; i < 9; i++) {
            IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY).enableFeeAmount(
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
        uint256[9] memory timeInc;
        {
            uint8[9] memory order = _shuffle1To9(seed);
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
        }

        // Score fee tiers
        uint256 bestScore;
        bool unreliableWinner; // Liquidity estimates from Uniswap manager vary by 3 units
        uint256 iBest;
        UniswapPoolAddress.PoolKey memory bestPoolKey;
        {
            uint256 errorTolerance;
            // console.log("------TEST intermediate scores------");
            for (uint256 i = 0; i < 9; i++) {
                period[i] = TWAP_DURATION < timeInc[i] ? uint32(TWAP_DURATION) : uint32(timeInc[i]);
                if (period[i] == 0) period[i] = 1;

                console.log("TEST, params:", uniswapFeeTiers[i].fee, liquidity[i], period[i]);
                uint256 tempScore;
                {
                    uint256 aggLiquidity = liquidity[i] * period[i];
                    tempScore = aggLiquidity == 0
                        ? 0
                        : (((aggLiquidity * uniswapFeeTiers[i].fee) << 72) - 1) /
                            uint24(uniswapFeeTiers[i].tickSpacing) +
                            1;
                    if (aggLiquidity != 0) {
                        console.log("TEST, fee tier:", uniswapFeeTiers[i].fee, ", score:", tempScore);
                    }
                }

                if (tempScore > bestScore) {
                    iBest = i;
                    bestPoolKey = poolKey;
                    errorTolerance =
                        ((uint256(3) * period[i] * uniswapFeeTiers[i].fee) << 72) /
                        uint24(uniswapFeeTiers[i].tickSpacing);

                    if (tempScore - bestScore <= errorTolerance) unreliableWinner = true;
                    else unreliableWinner = false;

                    bestScore = tempScore;
                } else if (bestScore != 0 && bestScore - tempScore <= errorTolerance) {
                    unreliableWinner = true;
                }
            }
        }

        // Check the event that shows the liquidity and other parameters
        if (unreliableWinner) {
            // console.log("WARNING: The winner is unreliable");
            return;
        } else if (bestScore == 0) {
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
        IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY).createPool(address(_tokenA), address(_tokenB), fee);

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
            address pool = UniswapPoolAddress.computeAddress(Addresses.ADDR_UNISWAPV3_FACTORY, poolKey);
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
        INonfungiblePositionManager(Addresses.ADDR_UNISWAPV3_POSITION_MANAGER);
    ISwapRouter swapRouter = ISwapRouter(Addresses.ADDR_UNISWAPV3_SWAP_ROUTER);
    Oracle private _oracle;
    MockERC20 private _tokenA;
    MockERC20 private _tokenB;
    UniswapPoolAddress.PoolKey private _poolKey;

    constructor() Oracle(Addresses.ADDR_UNISWAPV3_FACTORY) {}

    function setUp() public {
        // We fork after this tx because it allows us to test a 0-TWAP.
        vm.createSelectFork("mainnet", 18149275);

        _oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);

        _tokenA = new MockERC20("Mock Token A", "MTA", 18);
        _tokenB = new MockERC20("Mock Token B", "MTA", 6);

        // Order tokens
        if (address(_tokenA) < address(_tokenB)) (_tokenA, _tokenB) = (_tokenB, _tokenA);

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
        _oracle.getPrice(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
    }

    function test_updateOracleStateNotInitialized() public {
        vm.expectRevert(Oracle.OracleNotInitialized.selector);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
    }

    function test_getPriceNoTWAP() public returns (int64 tickPriceX42) {
        // At block 18149275 the FRAX-alUSD oracle is updated.

        // The time of the mainnet fork is suitable chosen to
        vm.expectEmit();
        emit IncreaseObservationCardinalityNext(1, 1 + CARDINALITY_DELTA);
        _oracle.initialize(Addresses.ADDR_FRAX, Addresses.ADDR_ALUSD);

        tickPriceX42 = _oracle.getPrice(Addresses.ADDR_FRAX, Addresses.ADDR_ALUSD);

        UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
            Addresses.ADDR_FRAX,
            Addresses.ADDR_ALUSD,
            500
        );
        address uniswapPool = UniswapPoolAddress.computeAddress(Addresses.ADDR_UNISWAPV3_FACTORY, poolKey);
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
        _oracle.initialize(Addresses.ADDR_FRAX, Addresses.ADDR_ALUSD);

        int64 tickPriceX42 = _oracle.updateOracleState(Addresses.ADDR_FRAX, Addresses.ADDR_ALUSD);

        assertEq(tickPriceX42, _oracle.getPrice(Addresses.ADDR_FRAX, Addresses.ADDR_ALUSD));
    }

    function test_getPriceUSDCAndWETH() public {
        _oracle.initialize(Addresses.ADDR_WETH, Addresses.ADDR_USDC);

        int64 tickPriceX42 = _oracle.getPrice(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
        assertEq(tickPriceX42, _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC));

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
        _oracle.initialize(Addresses.ADDR_WETH, Addresses.ADDR_USDT);

        int64 tickPriceX42 = _oracle.getPrice(Addresses.ADDR_WETH, Addresses.ADDR_USDT);
        assertEq(tickPriceX42, _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDT));

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
        periodTick0 = uint16(_bound(periodTick0, 0, maxPeriodTick0));

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
        periodTick0 = uint16(_bound(periodTick0, minPeriodTick0, TWAP_DURATION));

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

        assertEq(tickPriceX42, address(_tokenA) == _poolKey.token0 ? expTickPriceX42 : -expTickPriceX42);

        vm.expectEmit();
        emit PriceUpdated(_poolKey.token0, _poolKey.token1, false, expTickPriceX42);
        tickPriceX42 = _oracle.updateOracleState(address(_tokenA), address(_tokenB));

        assertEq(tickPriceX42, address(_tokenA) == _poolKey.token0 ? expTickPriceX42 : -expTickPriceX42);
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
            address pool = UniswapPoolAddress.computeAddress(Addresses.ADDR_UNISWAPV3_FACTORY, poolKey);
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
        address pool = UniswapPoolAddress.computeAddress(Addresses.ADDR_UNISWAPV3_FACTORY, poolKey);
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
    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew
    );

    INonfungiblePositionManager positionManager =
        INonfungiblePositionManager(Addresses.ADDR_UNISWAPV3_POSITION_MANAGER);
    ISwapRouter swapRouter = ISwapRouter(Addresses.ADDR_UNISWAPV3_SWAP_ROUTER);
    Oracle private _oracle;
    MockERC20 private usdc = MockERC20(Addresses.ADDR_USDC);
    IWETH9 private weth = IWETH9(Addresses.ADDR_WETH);

    uint24 newFeeTier = 69;

    constructor() Oracle(Addresses.ADDR_UNISWAPV3_FACTORY) {}

    function setUp() public {
        // We fork after this tx because it allows us to test a 0-TWAP.
        vm.createSelectFork("mainnet", 18149275);

        _oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);
        _oracle.initialize(Addresses.ADDR_WETH, Addresses.ADDR_USDC); // It picks feeTier = 500
    }

    function test_nextFeeTierNotProbed() public {
        // Hugely increase liquidity rest of fee tiers
        _addLiquidity(100, 2 ** 70);
        _addLiquidity(3000, 2 ** 70);
        _addLiquidity(10000, 2 ** 70);

        skip(DURATION_UPDATE_FEE_TIER - 1);

        // Retrieve/store price but do NOT PROBE tier
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(500, 0, 0, 0, 0);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
    }

    /// @dev This test in combination with the previous one tests that an event is NOT emitted.
    function testFail_nextFeeTierNotProbed() public {
        test_nextFeeTierNotProbed();

        // Retrieve/store price but do NOT PROBE tier
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(500, 0, 0, 0, 0);

        // This one should fail because not enough time has elapsed to probe a new tier.
        vm.expectEmit(false, false, false, false);
        emit UniswapOracleProbed(10000, 0, 0, 0, 0);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
    }

    function test_nextFeeTierProbedAndSwitched() public {
        // Hugely increase liquidity rest of fee tiers
        _addLiquidity(100, 2 ** 70);
        _addLiquidity(3000, 2 ** 70);
        _addLiquidity(10000, 2 ** 70);

        skip(DURATION_UPDATE_FEE_TIER);

        // Retrieve/store price but do NOT PROBE tier
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(500, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(3000, 0, 0, 0, 0);
        vm.expectEmit();
        emit OracleFeeTierChanged(500, 3000);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
    }

    function test_newFeeTierProbedAndNotSwitched() public {
        // Prepare new fee tier
        _prepareNewFeeTier();
        skip(TWAP_DURATION - 1); // So that TWAP is not old enough to be selected

        // Probe new tier
        console.log("--------------");
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(newFeeTier, 0, 0, 0, 0);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
    }

    function testFail_newFeeTierProbedAndNotSwitched() public {
        // Prepare new fee tier
        _prepareNewFeeTier();
        skip(TWAP_DURATION - 1); // So that TWAP is not old enough to be selected

        // Probe new tier
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(newFeeTier, 0, 0, 0, 0);
        vm.expectEmit(false, false, false, false);
        emit OracleFeeTierChanged(500, newFeeTier);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
    }

    function test_newFeeTierProbedAndSwitched() public {
        // Prepare new fee tier
        _prepareNewFeeTier();
        skip(TWAP_DURATION); // TWAP is old enough to be selected

        // Probe new tier
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(newFeeTier, 0, 0, 0, 0);
        vm.expectEmit();
        emit OracleFeeTierChanged(500, newFeeTier);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
    }

    function test_newFeeTierProbedAndSwitchedAndNextProbedTierIsCorrect() public {
        test_newFeeTierProbedAndSwitched();

        skip(DURATION_UPDATE_FEE_TIER);

        // Probe 1st tier (100 bp) again
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(69, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(100, 0, 0, 0, 0);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
    }

    function test_newFeeTierProbedAndCardinalityIncreased() public returns (uint256 tokenId, uint128 liquidity) {
        // Prepare new fee tier
        (tokenId, liquidity) = _prepareNewFeeTier();

        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(500, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(newFeeTier, 0, 0, 0, 0);
        vm.expectEmit();
        emit IncreaseObservationCardinalityNext(1, 1 + CARDINALITY_DELTA);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC); // Probe new fee tier
    }

    function testFail_newFeeTierProbedAndCardinalityNotIncreased() public {
        // Prepare new fee tier
        _prepareNewFeeTier();

        skip(TWAP_DURATION); // Skip enough time to have a full TWAP

        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(500, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, false);
        emit UniswapOracleProbed(newFeeTier, 0, 0, 0, 0);
        vm.expectEmit(false, false, false, false);
        emit IncreaseObservationCardinalityNext(1, 1 + CARDINALITY_DELTA);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
    }

    function test_newFeeTierProbedAndCardinalityIncreasedAgain() public {
        (uint256 tokenId, uint128 liquidity) = test_newFeeTierProbedAndCardinalityIncreased();

        // Cycle through all fee tiers until we are back to newFeeTier
        skip(DURATION_UPDATE_FEE_TIER);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC); // Probe tier 100
        skip(DURATION_UPDATE_FEE_TIER);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC); // Probe current tier 500
        skip(DURATION_UPDATE_FEE_TIER);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC); // Probe tier 3000
        skip(DURATION_UPDATE_FEE_TIER);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC); // Probe tier 10000
        skip(DURATION_UPDATE_FEE_TIER);

        // Refresh entire TWAP memory
        for (uint i = 0; i < 1 + CARDINALITY_DELTA; i++) {
            positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidity, 0, 0, block.timestamp)
            );
            (tokenId, liquidity) = _addLiquidity(newFeeTier, liquidity); // Update Uniswap TWAP
            skip(12 seconds); // Increase time to enable more TWAP updates
        }

        vm.expectEmit();
        emit IncreaseObservationCardinalityNext(1 + 1 * CARDINALITY_DELTA, 1 + 2 * CARDINALITY_DELTA);
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
    }

    /*////////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _addLiquidity(uint24 fee, uint128 liquidity) private returns (uint256 tokenId, uint128 liquidityAdj) {
        require(liquidity > 0, "liquidity must be > 0");

        uint160 sqrtPriceX96;
        int24 minTick;
        int24 maxTick;
        {
            // Get sqrtPriceX96
            UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
                Addresses.ADDR_WETH,
                Addresses.ADDR_USDC,
                fee
            );
            address pool = UniswapPoolAddress.computeAddress(Addresses.ADDR_UNISWAPV3_FACTORY, poolKey);
            int24 tick;
            (sqrtPriceX96, tick, , , , , ) = IUniswapV3Pool(pool).slot0();

            // Compute min and max tick
            int24 tickSpac = IUniswapV3Pool(pool).tickSpacing();
            minTick = ((tick - 2 * tickSpac) / tickSpac) * tickSpac;
            maxTick = ((tick + 2 * tickSpac) / tickSpac) * tickSpac;
        }

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
                uint256 balanceUSDC = usdc.balanceOf(address(this));
                vm.prank(Addresses.ADDR_USDC_MINTER);
                usdc.mint(address(this), balanceUSDC < amountUSDC ? amountUSDC - balanceUSDC : 0);
                usdc.approve(address(positionManager), amountUSDC);
            }

            if (amountWETH != 0) {
                vm.deal(address(this), amountWETH);
                weth.deposit{value: amountWETH}();
                weth.approve(address(positionManager), amountWETH);
            }

            // Add liquidity
            (tokenId, liquidityAdj, , ) = positionManager.mint(
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

    function _preparePool(uint24 fee, uint128 liquidity) private returns (uint256 tokenId, uint128 liquidityAdj) {
        // Start at price = 1 or tick = 0
        uint160 sqrtPriceX96 = 24721 * 2 ** 96;

        // Create and initialize Uniswap v3 pool
        UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
            Addresses.ADDR_WETH,
            Addresses.ADDR_USDC,
            fee
        );
        positionManager.createAndInitializePoolIfNecessary(poolKey.token0, poolKey.token1, fee, sqrtPriceX96);

        (tokenId, liquidityAdj) = _addLiquidity(fee, liquidity);
    }

    function _prepareNewFeeTier() private returns (uint256 tokenId, uint128 liquidityAdj) {
        // Create new fee tier
        int24 newTickSpacing = 4;
        uint128 liquidity = 2 ** 70;

        // Enable it in Uniswap v3
        vm.startPrank(Addresses.ADDR_UNISWAPV3_OWNER);
        IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY).enableFeeAmount(newFeeTier, newTickSpacing);
        vm.stopPrank();

        // Enable it in the oracle
        _oracle.newUniswapFeeTier(newFeeTier);
        skip(DURATION_UPDATE_FEE_TIER);

        console.log("--------------");
        // Probe tier 3000
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
        skip(DURATION_UPDATE_FEE_TIER);

        console.log("--------------");
        // Probe tier 10000 (last tier in the list)
        _oracle.updateOracleState(Addresses.ADDR_WETH, Addresses.ADDR_USDC);
        skip(DURATION_UPDATE_FEE_TIER);

        // Create pool and add liquidity
        (tokenId, liquidityAdj) = _preparePool(newFeeTier, liquidity);
    }
}

///////////////////////////////////////////////
//// I N V A R I A N T //// T E S T I N G ////
/////////////////////////////////////////////

contract UniswapHandler is Test {
    IUniswapV3Factory private constant _uniswapFactory = IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY);
    INonfungiblePositionManager private constant _positionManager =
        INonfungiblePositionManager(Addresses.ADDR_UNISWAPV3_POSITION_MANAGER);
    ISwapRouter private constant _swapRouter = ISwapRouter(Addresses.ADDR_UNISWAPV3_SWAP_ROUTER);
    MockERC20 private immutable _tokenA;
    MockERC20 private immutable _tokenB;

    IOracleInvariantTest private immutable _oracleInvariantTest;

    mapping(uint24 => uint256[]) _tokenIds;
    uint24[] internal feeTiers = [100, 500, 3000, 10000];
    uint24[] public initializedFeeTiers = new uint24[](0);

    function getFeeTiers() external view returns (uint24[] memory) {
        return feeTiers;
    }

    constructor(MockERC20 tokenA_, MockERC20 tokenB_) {
        assert(address(tokenA_) < address(tokenB_));
        _tokenA = tokenA_;
        _tokenB = tokenB_;

        _oracleInvariantTest = IOracleInvariantTest(msg.sender);

        // Add 1 pool so that we can run all functions
        instantiatePool(0, 0, 2 ** 96); // Tier 100 bps and price = 1
    }

    function increaseCardinality(uint24 timeSkip, uint256 feeTierIndex, uint16 observationCardinalityNext) external {
        _oracleInvariantTest.skip(timeSkip);

        uint24 feeTier = _getInitializedFeeTier(feeTierIndex);

        UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
            address(_tokenA),
            address(_tokenB),
            feeTier
        );
        address pool = UniswapPoolAddress.computeAddress(Addresses.ADDR_UNISWAPV3_FACTORY, poolKey);
        IUniswapV3Pool(pool).increaseObservationCardinalityNext(observationCardinalityNext);
    }

    function enableFeeTier(uint24 timeSkip, uint24 fee, int24 tickSpacingUint) external {
        _oracleInvariantTest.skip(timeSkip);

        fee = uint24(_bound(fee, 1, 1000000 - 1));
        if (_uniswapFactory.feeAmountTickSpacing(fee) != 0) return; // already enabled

        int24 tickSpacing = int24(_bound(tickSpacingUint, 1, 16384 - 1));

        vm.prank(Addresses.ADDR_UNISWAPV3_OWNER);
        _uniswapFactory.enableFeeAmount(fee, tickSpacing);

        feeTiers.push(fee);
    }

    function instantiatePool(uint24 timeSkip, uint256 feeTierIndex, uint160 sqrtPriceX96) public {
        _oracleInvariantTest.skip(timeSkip);

        uint24 feeTier = _getFeeTier(feeTierIndex);

        UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
            address(_tokenA),
            address(_tokenB),
            feeTier
        );
        address pool = UniswapPoolAddress.computeAddress(Addresses.ADDR_UNISWAPV3_FACTORY, poolKey);
        if (pool.code.length > 0) return; // already instantiated

        sqrtPriceX96 = uint160(_bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        // Create and initialize Uniswap v3 pool
        _positionManager.createAndInitializePoolIfNecessary(address(_tokenA), address(_tokenB), feeTier, sqrtPriceX96);

        initializedFeeTiers.push(feeTier);
    }

    function addLiquidity(uint24 timeSkip, uint256 feeTierIndex, uint96 liquidity) external {
        _oracleInvariantTest.skip(timeSkip);

        uint24 feeTier = _getInitializedFeeTier(feeTierIndex);
        liquidity = uint96(_bound(liquidity, 1, type(uint96).max));

        uint160 sqrtPriceX96;
        int24 minTick;
        int24 maxTick;
        {
            // Get sqrtPriceX96
            UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
                address(_tokenA),
                address(_tokenB),
                feeTier
            );
            address pool = UniswapPoolAddress.computeAddress(Addresses.ADDR_UNISWAPV3_FACTORY, poolKey);
            (sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
            int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

            // Compute min and max tick
            int24 tickSpac = IUniswapV3Pool(pool).tickSpacing();
            minTick = ((tick - 2 * tickSpac) / tickSpac) * tickSpac;
            if (minTick < TickMath.MIN_TICK) minTick = (TickMath.MIN_TICK / tickSpac) * tickSpac;
            maxTick = ((tick + 2 * tickSpac) / tickSpac) * tickSpac;
            if (maxTick > TickMath.MAX_TICK) maxTick = (TickMath.MAX_TICK / tickSpac) * tickSpac;
        }

        // Compute amounts
        (uint256 amountA, uint256 amountB) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(minTick),
            TickMath.getSqrtRatioAtTick(maxTick),
            liquidity
        );

        if (
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(minTick),
                TickMath.getSqrtRatioAtTick(maxTick),
                amountA,
                amountB
            ) == 0
        ) return;

        if (amountA == 0 && amountB == 0) return;

        // Mint mock tokens
        if (amountA != 0) {
            uint256 balanceA = _tokenA.balanceOf(address(this));
            _tokenA.mint(balanceA < amountA ? amountA - balanceA : 0);
            _tokenA.approve(address(_positionManager), amountA);
        }
        if (amountB != 0) {
            uint256 balanceB = _tokenB.balanceOf(address(this));
            _tokenB.mint(balanceB < amountB ? amountB - balanceB : 0);
            _tokenB.approve(address(_positionManager), amountB);
        }

        // Add liquidity
        (uint256 tokenId, , , ) = _positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(_tokenA),
                token1: address(_tokenB),
                fee: feeTier,
                tickLower: minTick,
                tickUpper: maxTick,
                amount0Desired: amountA,
                amount1Desired: amountB,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        _tokenIds[feeTier].push(tokenId);
    }

    function rmvLiquidity(uint24 timeSkip, uint256 feeTierIndex, uint96 liquidity) external {
        _oracleInvariantTest.skip(timeSkip);

        uint24 feeTier = _getInitializedFeeTier(feeTierIndex);
        liquidity = uint96(_bound(liquidity, 1, type(uint96).max));

        while (liquidity > 0 && _tokenIds[feeTier].length > 0) {
            uint256 tokenId = _tokenIds[feeTier][_tokenIds[feeTier].length - 1];
            _tokenIds[feeTier].pop();
            (, , , , , , , uint128 liquidityPos, , , , ) = _positionManager.positions(tokenId);
            if (liquidityPos > liquidity) {
                _positionManager.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidity, 0, 0, block.timestamp)
                );
                liquidity = 0;
            } else {
                _positionManager.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidityPos, 0, 0, block.timestamp)
                );
                liquidity -= uint96(liquidityPos);
            }
        }
    }

    function swap(uint24 timeSkip, uint256 feeTierIndex, bool swapDirection, uint128 amountIn) external {
        _oracleInvariantTest.skip(timeSkip);

        uint24 feeTier = _getInitializedFeeTier(feeTierIndex);
        amountIn = uint128(_bound(amountIn, 1, type(uint128).max));
        // If amountIn is too large for the entire pool liquidity, the remainer will be returned.

        // Mint mock tokens
        MockERC20 tokenIn;
        MockERC20 tokenOut;
        if (swapDirection) {
            tokenIn = _tokenB;
            tokenOut = _tokenA;
        } else {
            tokenIn = _tokenA;
            tokenOut = _tokenB;
        }

        // Mint and approve tokens
        uint256 balanceIn = tokenIn.balanceOf(address(this));
        tokenIn.mint(balanceIn < amountIn ? amountIn - balanceIn : 0);
        tokenIn.approve(address(_swapRouter), amountIn);

        // Swap
        try
            _swapRouter.exactInputSingle(
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
            )
        returns (uint256) {
            // Do nothing if it goes through
            // console.log("SUCCESSFUL swap");
        } catch {
            // Do nothing if it fails
            // console.log("FAILED swap");
        }
    }

    function _getFeeTier(uint256 feeTierIndex) private view returns (uint24 feeTier) {
        feeTier = feeTiers[_bound(feeTierIndex, 0, feeTiers.length - 1)];
    }

    function _getInitializedFeeTier(uint256 feeTierIndex) private view returns (uint24 feeTier) {
        feeTier = initializedFeeTiers[_bound(feeTierIndex, 0, initializedFeeTiers.length - 1)];
    }
}

contract SirOracleHandler is Test {
    MockERC20 private immutable _tokenA;
    MockERC20 private immutable _tokenB;

    UniswapHandler private immutable _uniswapHandler;
    Oracle public immutable oracle;
    IOracleInvariantTest private immutable _oracleInvariantTest;

    constructor(MockERC20 tokenA_, MockERC20 tokenB_, UniswapHandler uniswapHandler_) {
        assert(address(tokenA_) < address(tokenB_));
        _tokenA = tokenA_;
        _tokenB = tokenB_;

        _oracleInvariantTest = IOracleInvariantTest(msg.sender);
        _uniswapHandler = uniswapHandler_;
        oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);
        oracle.initialize(address(tokenA_), address(tokenB_));
    }

    function newUniswapFeeTier(uint24 timeSkip, uint256 feeTierIndex) external {
        _oracleInvariantTest.skip(timeSkip);

        uint24[] memory feeTiers = _uniswapHandler.getFeeTiers();
        if (feeTiers.length >= 9) return; // already 9 fee tiers
        uint24 feeTier = feeTiers[_bound(feeTierIndex, 0, feeTiers.length - 1)];

        // Check it has not been added yet
        SirStructs.UniswapFeeTier[] memory uniswapFeeTiers = oracle.getUniswapFeeTiers();
        for (uint256 i = 0; i < uniswapFeeTiers.length; i++) {
            if (feeTier == uniswapFeeTiers[i].fee) return; // already added
        }

        oracle.newUniswapFeeTier(feeTier);
    }

    function updateOracleState(uint24 timeSkip, bool direction) external {
        _oracleInvariantTest.skip(timeSkip);

        (address collateralToken, address debtToken) = direction
            ? (address(_tokenA), address(_tokenB))
            : (address(_tokenB), address(_tokenA));

        oracle.updateOracleState(collateralToken, debtToken);
    }
}

interface IOracleInvariantTest {
    function skip(uint40 timeSkip) external;
}

contract OracleInvariantTest is Test, Oracle {
    SirOracleHandler private _oracleHandler;
    Oracle private _oracle;

    MockERC20 private _tokenA;
    MockERC20 private _tokenB;

    uint40 private _currentTime; // Necessary because Forge invariant testing does not keep track block.timestamp

    constructor() Oracle(Addresses.ADDR_UNISWAPV3_FACTORY) {}

    function setUp() public {
        vm.createSelectFork("mainnet", 18149275);
        _currentTime = uint40(block.timestamp);

        _tokenA = new MockERC20("Mock Token A", "MTA", 18);
        _tokenB = new MockERC20("Mock Token B", "MTA", 6);

        // Order tokens
        if (address(_tokenA) > address(_tokenB)) (_tokenA, _tokenB) = (_tokenB, _tokenA);

        UniswapHandler uniswapHandler = new UniswapHandler(_tokenA, _tokenB);
        _oracleHandler = new SirOracleHandler(_tokenA, _tokenB, uniswapHandler);
        _oracle = Oracle(_oracleHandler.oracle());

        targetContract(address(uniswapHandler));
        targetContract(address(_oracleHandler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = uniswapHandler.increaseCardinality.selector;
        selectors[1] = uniswapHandler.enableFeeTier.selector;
        selectors[2] = uniswapHandler.instantiatePool.selector;
        selectors[3] = uniswapHandler.addLiquidity.selector;
        selectors[4] = uniswapHandler.rmvLiquidity.selector;
        selectors[5] = uniswapHandler.swap.selector;
        targetSelector(FuzzSelector({addr: address(uniswapHandler), selectors: selectors}));

        selectors = new bytes4[](2);
        selectors[0] = _oracleHandler.newUniswapFeeTier.selector;
        selectors[1] = _oracleHandler.updateOracleState.selector;
        targetSelector(FuzzSelector({addr: address(_oracleHandler), selectors: selectors}));
    }

    function skip(uint40 timeSkip) external {
        _currentTime += timeSkip;
        vm.warp(_currentTime);
    }

    function invariant_priceMaxDivergence() public {
        vm.warp(_currentTime);

        SirStructs.OracleState memory state = _oracle.state(address(_tokenA), address(_tokenB));
        int64 tickPriceX42 = _oracle.getPrice(address(_tokenA), address(_tokenB));

        uint256 tickPriceDiff = state.tickPriceX42 > tickPriceX42
            ? uint64(state.tickPriceX42 - tickPriceX42)
            : uint64(tickPriceX42 - state.tickPriceX42);

        assertLe(tickPriceDiff, uint256(uint64(MAX_TICK_INC_PER_SEC)) * (block.timestamp - state.timeStampPrice));
    }
}
