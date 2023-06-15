// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Oracle.sol";

library AddressOracle {
    // Caller must ensure that tokenA < tokenB
    function get(address factory, address tokenA, address tokenB) internal pure returns (address) {
        // Order addresses
        if (tokenA > tokenB) {
            address addrTemp = tokenB;
            tokenB = tokenA;
            tokenA = addrTemp;
        }

        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            factory,
                            bytes32(0), // Salt
                            keccak256(abi.encodePacked(type(Oracle).creationCode, abi.encode(tokenA, tokenB)))
                        )
                    )
                )
            )
        );
    }
}
