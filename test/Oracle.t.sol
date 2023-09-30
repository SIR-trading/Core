// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungibleTokenPositionDescriptor.sol";
import {UniswapPoolAddress} from "src/libraries/UniswapPoolAddress.sol";
import {Oracle} from "src/Oracle.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {MockERC20} from "src/test/MockERC20.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {Tick} from "v3-core/libraries/Tick.sol";

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

    function test_InitializeBNBAndWETH() public {
        vm.expectEmit(true, true, false, false, address(_oracle));
        emit OracleInitialized(Addresses._ADDR_BNB, Addresses._ADDR_WETH, 0, 0, 0);
        _oracle.initialize(Addresses._ADDR_WETH, Addresses._ADDR_BNB);

        _oracle.initialize(Addresses._ADDR_BNB, Addresses._ADDR_WETH); // No-op
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
            int24 tickSpacking = IUniswapV3Pool(pool).tickSpacing();
            int24 minTick = (TickMath.MIN_TICK / tickSpacking) * tickSpacking;
            int24 maxTick = (TickMath.MAX_TICK / tickSpacking) * tickSpacking;

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
