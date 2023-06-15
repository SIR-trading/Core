// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Libraries
import "./AddressOracle.sol";

// Contracts
import "../Oracle.sol";

library DeployerOfOracles {
    // Deploy oracle
    function deployOracle(
        address tokenA,
        address tokenB,
        Oracle.UniswapFeeTier[] memory uniswapFeeTiers
    ) external returns (address) {
        // Retrieve oracle address
        address addrOracle = AddressOracle.get(address(this), tokenA, tokenB);

        // Check if oracle has been instantiated
        if (addrOracle.code.length == 0) {
            // Instantiate oracle
            Oracle oracle = new Oracle{salt: hex"00"}(tokenA, tokenB);

            oracle.initialize(uniswapFeeTiers);

            return address(oracle);
        }

        return addrOracle;
    }

    function getAddress(
        address factory,
        address tokenA,
        address tokenB
    ) external pure returns (address) {
        return AddressOracle.get(factory, tokenA, tokenB);
    }
}
