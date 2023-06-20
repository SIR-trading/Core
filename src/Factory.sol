// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IUniswapV3Factory} from "uniswap-v3-core/interfaces/IUniswapV3Factory.sol";
import {Pool} from "./Pool.sol";

// Libraries
import {Addresses} from "./libraries/Addresses.sol";
import {DeployerOfOracles, Oracle} from "./libraries/DeployerOfOracles.sol";

contract Factory {
    address private immutable _POOL_LOGIC;

    // List of Uniswap v3 fee tiers
    Oracle.UniswapFeeTier[] public uniswapFeeTiers;

    address[] public poolsAddresses;

    struct PoolParameters {
        address debtToken;
        address collateralToken;
        address oracle;
        int8 leverageTier; // Only 4 bytes for efficient storage
    }

    mapping(address => PoolParameters) public poolsParameters;

    constructor(address poolLogic) {
        _POOL_LOGIC = poolLogic;
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    // Creates a pool
    function createPool(
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) public {
        // Create oracle if it does not exist
        address oracle = DeployerOfOracles.deployOracle(
            debtToken,
            collateralToken,
            uniswapFeeTiers
        );

        // Create pool
        address pool = address(
            new Pool{salt: bytes32(0)}(
                debtToken,
                collateralToken,
                leverageTier,
                oracle,
                _POOL_LOGIC
            )
        );

        // Store all parameters in an easy to access array
        poolsAddresses.push(pool);
        poolsParameters[pool] = PoolParameters({
            debtToken: debtToken,
            collateralToken: collateralToken,
            oracle: oracle,
            leverageTier: leverageTier
        });

        // Uniswap v3 fee tiers
        uniswapFeeTiers.push(Oracle.UniswapFeeTier(100, 1, 0));
        uniswapFeeTiers.push(Oracle.UniswapFeeTier(500, 10, 0));
        uniswapFeeTiers.push(Oracle.UniswapFeeTier(3000, 60, 0));
        uniswapFeeTiers.push(Oracle.UniswapFeeTier(10000, 200, 0));
    }

    // Anyone can let the SIR factory know that a new fee tier exists in Uniswap V3
    function newUniswapFeeTier(uint24 fee) external {
        // Check fee tier actually exists in Uniswap v3
        int24 tickSpacing = IUniswapV3Factory(Addresses.ADDR_UNISWAPV3_FACTORY)
            .feeAmountTickSpacing(fee);
        require(tickSpacing > 0);

        // Check fee tier has not been added yet
        for (uint256 i = 0; i < uniswapFeeTiers.length; i++) {
            require(fee != uniswapFeeTiers[i].fee);
        }

        uniswapFeeTiers.push(
            Oracle.UniswapFeeTier(fee, uint24(tickSpacing), 0)
        );
    }
}
