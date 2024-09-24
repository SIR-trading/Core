// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungibleTokenPositionDescriptor.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {UniswapPoolAddress} from "src/libraries/UniswapPoolAddress.sol";
import {SepoliaERC20} from "src/test/SepoliaERC20.sol";

/** @dev cli for local testnet:   forge script script/AddLiquidity.s.sol --rpc-url tarp_testnet --broadcast--legacy
    @dev cli for Sepolia:        forge script script/AddLiquidity.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract AddLiquidity is Script {
    uint256 privateKey;

    SepoliaERC20 public tokenA = SepoliaERC20(0x7Aef48AdbFDc1262161e71Baf205b47316430067);
    SepoliaERC20 public tokenB = SepoliaERC20(0x3ED05DE92879a5D47a3c8cc402DD5259219505aD);
    INonfungiblePositionManager public positionManager;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
            positionManager = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
            positionManager = INonfungiblePositionManager(0x1238536071E1c677A632429e3655c799b22cDA52);
        } else {
            revert("Network not supported");
        }
    }

    function run() public {
        vm.startBroadcast(privateKey);

        // Approve tokens
        tokenA.approve(address(positionManager), 10000 * 10 ** tokenA.decimals());
        tokenB.approve(address(positionManager), 10000 * 10 ** tokenB.decimals());

        // Create pool
        UniswapPoolAddress.PoolKey memory poolKey = UniswapPoolAddress.getPoolKey(
            address(tokenA),
            address(tokenB),
            100
        );
        address pool = positionManager.createAndInitializePoolIfNecessary(poolKey.token0, poolKey.token1, 100, 2 ** 96);
        console.log("Pool created at ", vm.toString(pool));

        // Add liquidity
        positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: poolKey.token0,
                token1: poolKey.token1,
                fee: 100,
                tickLower: TickMath.MIN_TICK,
                tickUpper: TickMath.MAX_TICK,
                amount0Desired: 10000 * 10 ** SepoliaERC20(poolKey.token0).decimals(),
                amount1Desired: 10000 * 10 ** SepoliaERC20(poolKey.token1).decimals(),
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 5 minutes
            })
        );

        vm.stopBroadcast();
    }
}
