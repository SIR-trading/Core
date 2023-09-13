// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import {UniswapV3Factory} from "v3-core/UniswapV3Factory.sol";
import {NonfungibleTokenPositionDescriptor} from "v3-periphery/NonfungibleTokenPositionDescriptor.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {NonfungiblePositionManager} from "v3-periphery/NonfungiblePositionManager.sol";

/** I used this to generate artifacts of contracts in lib/ folder .
 */
contract GenerateArtifactUniswapV3Factory {
    UniswapV3Factory public factory;
    NonfungibleTokenPositionDescriptor public descriptor;
    INonfungiblePositionManager public positionManagerInterface;
    NonfungiblePositionManager public positionManager;

    constructor() {
        factory = new UniswapV3Factory();
        descriptor = new NonfungibleTokenPositionDescriptor(address(0), bytes32(0));
        positionManager = new NonfungiblePositionManager(address(0), address(0), address(0));
        positionManagerInterface = INonfungiblePositionManager(address(positionManager));
    }
}
