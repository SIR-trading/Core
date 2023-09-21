// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "src/test/INonfungiblePositionManager.sol";
import {UniswapPoolAddress} from "src/libraries/UniswapPoolAddress.sol";
import {Oracle} from "src/Oracle.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {MockERC20} from "src/test/MockERC20.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";

contract OracleNewFeeTiersTest is Test {
    event UniswapFeeTierAdded(uint24 indexed fee);

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

contract OracleInitializeTest is Test {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    event OracleInitialized(
        address indexed tokenA,
        address indexed tokenB,
        uint24 indexed feeTierSelected,
        uint40 periodTWAP
    );
    event UniswapOracleDataRetrieved(
        address indexed tokenA,
        address indexed tokenB,
        uint24 indexed fee,
        int56 aggLogPrice,
        uint160 avLiquidity,
        uint40 period,
        uint16 cardinalityToIncrease
    );
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
        vm.expectRevert(abi.encodeWithSelector(Oracle.UniswapV3NotReady.selector, 4, 0, 0));
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializeNoPoolOfBNBAndUSDT() public {
        vm.expectRevert(abi.encodeWithSelector(Oracle.UniswapV3NotReady.selector, 4, 0, 0));
        _oracle.initialize(Addresses._ADDR_BNB, Addresses._ADDR_USDT);
    }

    function test_InitializePoolNotInitialized() public {
        uint24 fee = 100;
        _preparePoolNoInitialization(fee);

        vm.expectRevert(abi.encodeWithSelector(Oracle.UniswapV3NotReady.selector, 4, 0, 0));
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializePoolNoLiquidity() public {
        uint24 fee = 100;
        uint40 duration = 12 seconds;
        _preparePoolNoLiquidity(fee, duration);

        vm.expectRevert(abi.encodeWithSelector(Oracle.UniswapV3NotReady.selector, 3, 1, 0));
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializeCardinalityIs1() public {
        uint24 fee = 100;
        uint128 liquidity = 2 ** 64;
        _preparePoolNoTWAP(fee, liquidity);

        vm.expectRevert(abi.encodeWithSelector(Oracle.UniswapV3NotReady.selector, 3, 0, 1));
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializeTwapNotReady() public {
        uint24 fee = 100;
        uint128 liquidity = 2 ** 64;
        _preparePoolCardinalityNotExtendedYet(fee, liquidity);

        vm.expectRevert(abi.encodeWithSelector(Oracle.UniswapV3NotReady.selector, 3, 1, 0));
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_Initialize() public {
        uint24 fee = 100;
        uint128 liquidity = 2 ** 64;
        uint40 duration = 12 seconds;
        UniswapPoolAddress.PoolKey memory poolKey = _preparePool(100, liquidity, duration);

        // vm.expectRevert();
        vm.expectEmit(address(_oracle));
        emit OracleInitialized(poolKey.token0, poolKey.token1, fee, duration);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    function test_InitializeBNBAndWETH() public {
        vm.expectEmit(true, true, false, false, address(_oracle));
        emit OracleInitialized(Addresses._ADDR_BNB, Addresses._ADDR_WETH, 0, 0);
        _oracle.initialize(Addresses._ADDR_WETH, Addresses._ADDR_BNB);

        _oracle.initialize(Addresses._ADDR_BNB, Addresses._ADDR_WETH); // No-op
    }

    function test_InitializeWithMultipleFeeTiers(uint128[9] calldata liquidity, uint32[9] calldata duration) public {
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
        IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(
            uniswapFeeTiers[4].fee,
            uniswapFeeTiers[4].tickSpacing
        );
        IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(
            uniswapFeeTiers[5].fee,
            uniswapFeeTiers[5].tickSpacing
        );
        IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(
            uniswapFeeTiers[6].fee,
            uniswapFeeTiers[6].tickSpacing
        );
        IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(
            uniswapFeeTiers[7].fee,
            uniswapFeeTiers[7].tickSpacing
        );
        IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).enableFeeAmount(
            uniswapFeeTiers[8].fee,
            uniswapFeeTiers[8].tickSpacing
        );
        vm.stopPrank();

        // Add them the oracle
        for (uint256 i = 5; i < 9; i++) {
            _oracle.newUniswapFeeTier(uniswapFeeTiers[4].fee);
            _oracle.newUniswapFeeTier(uniswapFeeTiers[5].fee);
            _oracle.newUniswapFeeTier(uniswapFeeTiers[6].fee);
            _oracle.newUniswapFeeTier(uniswapFeeTiers[7].fee);
            _oracle.newUniswapFeeTier(uniswapFeeTiers[8].fee);
        }

        // Deploy fee tiers and score them
        UniswapPoolAddress.PoolKey memory bestPoolKey;
        UniswapPoolAddress.PoolKey memory poolKey;
        uint256 bestScore;
        uint256 bestIndex;
        uint40 TWAP_DURATION = _oracle.TWAP_DURATION();
        for (uint256 i = 0; i < 9; i++) {
            if (liquidity[i] == 0 && duration[0] == 0) _preparePoolNoInitialization(uniswapFeeTiers[i].fee);
            else if (liquidity[i] == 0) poolKey = _preparePoolNoLiquidity(uniswapFeeTiers[i].fee, duration[i]);
            else if (duration[i] == 0) (, poolKey) = _preparePoolNoTWAP(uniswapFeeTiers[i].fee, liquidity[i]);
            else poolKey = _preparePool(uniswapFeeTiers[i].fee, liquidity[i], duration[i]);

            uint256 tempScore = ((uint256(liquidity[i]) *
                (TWAP_DURATION < duration[i] ? TWAP_DURATION : duration[i]) *
                uniswapFeeTiers[i].fee) << 72) / uint24(uniswapFeeTiers[i].tickSpacing);

            if (bestScore > tempScore) {
                bestIndex = 0;
                bestScore = tempScore;
                bestPoolKey = poolKey;
            }
        }

        // Check the correct fee tier is selected
        vm.expectEmit(address(_oracle));
        emit OracleInitialized(
            poolKey.token0,
            poolKey.token1,
            uniswapFeeTiers[bestIndex].fee,
            TWAP_DURATION < duration[bestIndex] ? TWAP_DURATION : duration[bestIndex]
        );
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
        UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
            address(_tokenA),
            address(_tokenB),
            fee
        );
        positionManager.createAndInitializePoolIfNecessary(poolKey.token0, poolKey.token1, fee, sqrtPriceX96);

        // Increase oracle cardinality
        address pool = UniswapPoolAddress.computeAddress(Addresses._ADDR_UNISWAPV3_FACTORY, poolKey);
        vm.expectEmit(pool);
        emit IncreaseObservationCardinalityNext(1, 2);
        IUniswapV3Pool(pool).increaseObservationCardinalityNext(2);

        // Increase time
        skip(duration);

        poolKey = UniswapPoolAddress.getPoolKey(address(_tokenA), address(_tokenB), fee);
    }

    function _preparePoolNoTWAP(
        uint24 fee,
        uint128 liquidity
    ) private returns (uint256 tokenId, UniswapPoolAddress.PoolKey memory poolKey) {
        uint256 amount = 10 ** 12;

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

        // Mint mock tokens
        _tokenA.mint(amount0);
        _tokenB.mint(amount1);

        // Approve tokens
        _tokenA.approve(address(positionManager), amount0);
        _tokenB.approve(address(positionManager), amount1);

        // Add liquidity
        (tokenId, , , ) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: poolKey.token0,
                token1: poolKey.token1,
                fee: fee,
                tickLower: TickMath.MIN_TICK,
                tickUpper: TickMath.MAX_TICK,
                amount0Desired: amount,
                amount1Desired: amount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    function _preparePoolCardinalityNotExtendedYet(
        uint24 fee,
        uint128 liquidity
    ) private returns (uint256 tokenId, UniswapPoolAddress.PoolKey memory poolKey) {
        (tokenId, poolKey) = _preparePoolNoTWAP(fee, liquidity);

        // Increase oracle cardinality
        address pool = UniswapPoolAddress.computeAddress(Addresses._ADDR_UNISWAPV3_FACTORY, poolKey);
        vm.expectEmit(pool);
        emit IncreaseObservationCardinalityNext(1, 2);
        IUniswapV3Pool(pool).increaseObservationCardinalityNext(2);
    }

    function _preparePool(
        uint24 fee,
        uint128 liquidity,
        uint40 duration
    ) private returns (UniswapPoolAddress.PoolKey memory) {
        (uint256 tokenId, UniswapPoolAddress.PoolKey memory poolKey) = _preparePoolCardinalityNotExtendedYet(
            fee,
            liquidity
        );

        // Increase time
        skip(duration);

        // Update oracle by burning LP position
        positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidity, 0, 0, block.timestamp)
        );

        return poolKey;
    }
}
