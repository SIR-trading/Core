// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "src/test/INonfungiblePositionManager.sol";
import {UniswapPoolAddress} from "src/libraries/UniswapPoolAddress.sol";
import {Oracle} from "src/Oracle.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {MockERC20} from "src/test/MockERC20.sol";

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
            console.log(uniswapFeeTiers[i].fee, uint24(uniswapFeeTiers[i].tickSpacing));
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
    event OracleInitialized(address indexed tokenA, address indexed tokenB);
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

    Oracle private _oracle;
    MockERC20 private _tokenA;
    MockERC20 private _tokenB;

    constructor() {
        vm.createSelectFork("mainnet", 18128102);

        _oracle = new Oracle();
        _tokenA = new MockERC20("Mock Token A", "MTA", 18);
        _tokenB = new MockERC20("Mock Token B", "MTA", 6);
    }

    // function test_InitializeNoPool() public {
    //     vm.expectRevert(Oracle.NoUniswapV3Pool.selector);
    //     _oracle.initialize(address(_tokenA), address(_tokenB));
    // }

    // function test_InitializePoolNotInitialized() public {
    //     uint24 fee = 100;
    //     int24 tickSpacing = 1;

    //     // Deploy Uniswap v3 pool
    //     UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
    //         address(_tokenA),
    //         address(_tokenB),
    //         fee
    //     );
    //     vm.expectEmit(true, true, true, true, Addresses._ADDR_UNISWAPV3_FACTORY);
    //     emit PoolCreated(
    //         poolKey.token0,
    //         poolKey.token1,
    //         fee,
    //         tickSpacing,
    //         UniswapPoolAddress.computeAddress(Addresses._ADDR_UNISWAPV3_FACTORY, poolKey)
    //     );
    //     IUniswapV3Factory(Addresses._ADDR_UNISWAPV3_FACTORY).createPool(address(_tokenA), address(_tokenB), fee);

    //     vm.expectRevert(Oracle.NoUniswapV3Pool.selector);
    //     _oracle.initialize(address(_tokenA), address(_tokenB));
    // }

    function test_InitializePoolNoLiquidity() public {
        uint24 fee = 100;
        int24 tickSpacing = 1;

        // Start at price = 1
        uint160 sqrtPriceX96 = 2 ** 96;

        // Deploy Uniswap v3 pool
        UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
            address(_tokenA),
            address(_tokenB),
            fee
        );
        vm.expectEmit(true, true, true, true, Addresses._ADDR_UNISWAPV3_FACTORY);
        emit PoolCreated(
            poolKey.token0,
            poolKey.token1,
            fee,
            tickSpacing,
            UniswapPoolAddress.computeAddress(Addresses._ADDR_UNISWAPV3_FACTORY, poolKey)
        );
        INonfungiblePositionManager(Addresses._ADDR_UNISWAPV3_POSITION_MANAGER).createAndInitializePoolIfNecessary(
            poolKey.token0,
            poolKey.token1,
            fee,
            sqrtPriceX96
        );

        vm.expectRevert(Oracle.NoUniswapV3Pool.selector);
        _oracle.initialize(address(_tokenA), address(_tokenB));
    }

    // function test_InitializeNoPoolTokens() public {
    //     vm.expectRevert(Oracle.NoUniswapV3Pool.selector);
    //     _oracle.initialize(Addresses._ADDR_BNB, Addresses._ADDR_USDT);
    // }

    // function test_InitializeBNBAndWETH() public {
    //     vm.expectEmit(address(_oracle));
    //     emit OracleInitialized(Addresses._ADDR_BNB, Addresses._ADDR_WETH);
    //     _oracle.initialize(Addresses._ADDR_WETH, Addresses._ADDR_BNB);

    //     _oracle.initialize(Addresses._ADDR_BNB, Addresses._ADDR_WETH); // No-op
    // }

    // Test when pool exists but not initialized, or TWAP is not old enough
    // Check the event that shows the liquidity and other parameters
}
