// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "src/test/INonfungiblePositionManager.sol";
// import {SwapRouter} from "v3-periphery/SwapRouter.sol";
import {Oracle} from "src/Oracle.sol";
import {MockERC20} from "src/test/MockERC20.sol";

// import {UniswapInterfaceMulticall} from "v3-periphery/lens/UniswapInterfaceMulticall.sol";

contract OracleTest is Test {
    // IUniswapV3Factory private _uV3factory;
    // INonfungiblePositionManager private _uV3positionManager;
    Oracle private _oracle;
    MockERC20 private _tokenA;
    MockERC20 private _tokenB;

    // SwapRouter private _uV3router;

    // UniswapInterfaceMulticall private _uV3multicall;

    constructor() {
        vm.createSelectFork("mainnet", 18128102);

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
