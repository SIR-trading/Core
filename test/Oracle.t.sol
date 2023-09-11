// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {UniswapV3Factory} from "uniswap-v3-core/UniswapV3Factory.sol";
import {NonfungiblePositionManager} from "v3-periphery/NonfungiblePositionManager.sol";
import {NonfungibleTokenPositionDescriptor} from "v3-periphery/NonfungibleTokenPositionDescriptor.sol";
import {SwapRouter} from "v3-periphery/SwapRouter.sol";
import {WETH9} from "lib/canonical-weth/contracts/WETH9.sol";
import {Oracle} from "src/Oracle.sol";
import {MockERC20} from "src/test/MockERC20.sol";

// import {UniswapInterfaceMulticall} from "v3-periphery/lens/UniswapInterfaceMulticall.sol";

contract OracleNotInitializedTest is Test {
    UniswapV3Factory private _uV3factory;
    WETH9 private _WETH9;
    NonfungiblePositionManager private _uV3positionManager;
    Oracle private _oracle;
    MockERC20 private _tokenA;
    MockERC20 private _tokenB;

    // SwapRouter private _uV3router;

    // UniswapInterfaceMulticall private _uV3multicall;

    constructor() {
        _uV3factory = new UniswapV3Factory();
        _uV3factory.enableFeeAmount(100, 1); // Add 1 bp fee tier

        _WETH9 = new WETH9();

        NonfungibleTokenPositionDescriptor uV3tokenDescriptor = new NonfungibleTokenPositionDescriptor(
            address(_WETH9),
            "ETH"
        );

        _uV3positionManager = new NonfungiblePositionManager(
            address(_uV3factory),
            address(_WETH9),
            address(uV3tokenDescriptor)
        ); // It has createAndInitializePoolIfNecessary

        _oracle = new Oracle();

        // _uV3router = new SwapRouter(address(_uV3factory), address(_WETH9));
        // _uV3multicall = new UniswapInterfaceMulticall();
    }

    function setUp() public {
        _tokenA = new MockERC20("Token A", "TKA", 18);
        _tokenB = new MockERC20("Token A", "TKA", 6);
    }

    function testFailFuzz_NewUniswapFeeTier(uint24 fee) public {
        _oracle.newUniswapFeeTier(fee);
    }
}
