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
        UniswapPoolAddress.PoolKey memory poolKey = _preparePoolNoLiquidity(fee, duration);

        vm.expectEmit(false, false, false, false);
        emit IncreaseObservationCardinalityNext(0, 0);
        vm.expectEmit(address(_oracle));
        emit OracleInitialized(poolKey.token0, poolKey.token1, fee, 1, duration);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializeTwapCardinality0() public {
        uint24 fee = 100;
        uint128 liquidity = 2 ** 64;
        (, , UniswapPoolAddress.PoolKey memory poolKey) = _preparePoolTwapCardinality0(fee, liquidity);

        vm.expectEmit(false, false, false, false);
        emit IncreaseObservationCardinalityNext(0, 0);
        vm.expectEmit(address(_oracle));
        emit OracleInitialized(poolKey.token0, poolKey.token1, fee, 1, 0);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializeTwapCardinality1() public {
        uint24 fee = 100;
        uint128 liquidity = 2 ** 64;
        uint40 duration = 12 seconds;
        UniswapPoolAddress.PoolKey memory poolKey;
        (, liquidity, poolKey) = _preparePoolTwapCardinality1(fee, liquidity, duration);

        vm.expectEmit(false, false, false, false);
        emit IncreaseObservationCardinalityNext(0, 0);
        vm.expectEmit(address(_oracle));
        emit OracleInitialized(poolKey.token0, poolKey.token1, fee, liquidity, duration);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_Initialize() public {
        uint24 fee = 100;
        uint128 liquidity = 2 ** 64;
        uint40 duration = 12 seconds;
        UniswapPoolAddress.PoolKey memory poolKey;
        (liquidity, poolKey) = _preparePool(100, liquidity, duration);

        // vm.expectRevert();
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

    function test_InitializeWithMultipleFeeTiers(uint128[9] memory liquidity, uint256[9] memory timeInc) public {
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

        // Deploy fee tiers
        UniswapPoolAddress.PoolKey memory poolKey;
        for (uint256 i = 0; i < 9; i++) {
            // Bound timeInc to 32 bits
            timeInc[i] = bound(timeInc[i], 0, type(uint32).max);

            if (liquidity[i] == 0 && timeInc[i] == 0) {
                _preparePoolNoInitialization(uniswapFeeTiers[i].fee);
            } else if (liquidity[i] == 0) {
                liquidity[i] = 1; // Uniswap assumes liquidity == 1 when no liquidity is provided
                poolKey = _preparePoolNoLiquidity(uniswapFeeTiers[i].fee, uint32(timeInc[i]));
            } else if (timeInc[i] == 0) {
                (, liquidity[i], poolKey) = _preparePoolTwapCardinality0(uniswapFeeTiers[i].fee, liquidity[i]);
            } else {
                (liquidity[i], poolKey) = _preparePool(uniswapFeeTiers[i].fee, liquidity[i], uint32(timeInc[i]));
            }
        }

        // Score fee tiers
        UniswapPoolAddress.PoolKey memory bestPoolKey;
        uint256 bestScore;
        uint256 iBest;
        for (uint256 i = 8; i >= 0 && i < 9; ) {
            // Time increments accumulate
            if (i < 8) timeInc[i] += timeInc[i + 1];

            timeInc[i] = TWAP_DURATION < timeInc[i] ? TWAP_DURATION : timeInc[i];
            uint256 aggLiquidity = liquidity[i] * timeInc[i];
            // if (uniswapFeeTiers[i].fee == 100000) {
            // console.log("----------Test : %s", uniswapFeeTiers[i].fee, "----------");
            // console.log("avLiquidity: %s", liquidity[i] == 0 ? 1 : liquidity[i]);
            // console.log("aggLiquidity: %s", aggLiquidity == 0 ? 1 : aggLiquidity);
            // console.log("period: %s", timeInc[i]);
            // console.log("tickSpacing: %s", uint24(uniswapFeeTiers[i].tickSpacing));
            // }
            uint256 tempScore = aggLiquidity == 0
                ? 1
                : (((aggLiquidity * uniswapFeeTiers[i].fee) << 72) - 1) / uint24(uniswapFeeTiers[i].tickSpacing) + 1;

            if (tempScore >= bestScore) {
                iBest = i;
                bestScore = tempScore;
                bestPoolKey = poolKey;
            }
            console.log("fee %s", uniswapFeeTiers[i].fee, "score: %s", uint(tempScore));

            unchecked {
                i--;
            }
        }

        // Check the correct fee tier is selected
        if (bestScore == 0) {
            vm.expectRevert();
        } else {
            // Account for rounding error in Uniswap
            liquidity[iBest] = uint128((timeInc[iBest] << 128) / ((timeInc[iBest] << 128) / liquidity[iBest]));

            vm.expectEmit(address(_oracle));
            emit OracleInitialized(
                poolKey.token0,
                poolKey.token1,
                uniswapFeeTiers[iBest].fee,
                liquidity[iBest],
                uint40(timeInc[iBest])
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

    function _preparePoolNoLiquidity(
        uint24 fee,
        uint40 duration
    ) private returns (UniswapPoolAddress.PoolKey memory poolKey) {
        // Start at price = 1
        uint160 sqrtPriceX96 = 2 ** 96;

        // Create and initialize Uniswap v3 pool
        poolKey = UniswapPoolAddress.getPoolKey(address(_tokenA), address(_tokenB), fee);
        positionManager.createAndInitializePoolIfNecessary(poolKey.token0, poolKey.token1, fee, sqrtPriceX96);

        // Increase oracle cardinality
        address pool = UniswapPoolAddress.computeAddress(Addresses._ADDR_UNISWAPV3_FACTORY, poolKey);
        vm.expectEmit(pool);
        emit IncreaseObservationCardinalityNext(1, 2);
        IUniswapV3Pool(pool).increaseObservationCardinalityNext(2);

        // Increase time
        skip(duration);
    }

    function _preparePoolTwapCardinality0(
        uint24 fee,
        uint128 liquidity
    ) private returns (uint256 tokenId, uint128 liquidityAdj, UniswapPoolAddress.PoolKey memory poolKey) {
        // Start at price = 1
        uint160 sqrtPriceX96 = 2 ** 96;

        // Create and initialize Uniswap v3 pool
        poolKey = UniswapPoolAddress.getPoolKey(address(_tokenA), address(_tokenB), fee);
        positionManager.createAndInitializePoolIfNecessary(poolKey.token0, poolKey.token1, fee, sqrtPriceX96);

        // Compute amounts
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.MIN_SQRT_RATIO,
            TickMath.MAX_SQRT_RATIO,
            liquidity
        );

        // Reorder tokens
        MockERC20 token0 = MockERC20(poolKey.token0);
        MockERC20 token1 = MockERC20(poolKey.token1);

        // Mint mock tokens
        token0.mint(amount0);
        token1.mint(amount1);

        // Approve tokens
        // console.log("approve", address(positionManager), "to TKA", amount0);
        // console.log("approve", address(positionManager), "to TKB", amount1);
        // console.log("msg.sender", msg.sender);
        token0.approve(address(positionManager), amount0);
        token1.approve(address(positionManager), amount1);

        // Add liquidity
        (tokenId, liquidityAdj, , ) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: poolKey.token0,
                token1: poolKey.token1,
                fee: fee,
                tickLower: TickMath.MIN_TICK,
                tickUpper: TickMath.MAX_TICK,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    function _preparePoolTwapCardinality1(
        uint24 fee,
        uint128 liquidity,
        uint40 duration
    ) private returns (uint256 tokenId, uint128 liquidityAdj, UniswapPoolAddress.PoolKey memory poolKey) {
        (tokenId, liquidityAdj, poolKey) = _preparePoolTwapCardinality0(fee, liquidity);

        // Increase time
        skip(duration);
    }

    function _preparePool(
        uint24 fee,
        uint128 liquidity,
        uint40 duration
    ) private returns (uint128, UniswapPoolAddress.PoolKey memory) {
        (
            uint256 tokenId,
            uint128 liquidityAdj,
            UniswapPoolAddress.PoolKey memory poolKey
        ) = _preparePoolTwapCardinality0(fee, liquidity);

        // Increase oracle cardinality
        address pool = UniswapPoolAddress.computeAddress(Addresses._ADDR_UNISWAPV3_FACTORY, poolKey);
        vm.expectEmit(pool);
        emit IncreaseObservationCardinalityNext(1, 1000);
        IUniswapV3Pool(pool).increaseObservationCardinalityNext(1000);

        // Increase time
        skip(duration);

        // Update oracle by burning LP position
        positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidityAdj, 0, 0, block.timestamp)
        );

        return (liquidityAdj, poolKey);
    }
}
