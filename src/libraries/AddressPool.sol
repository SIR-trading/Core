// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Pool.sol";

library AddressPool {
    // Returns address of a pair
    // leverage ratio = 1+2^leverageTier
    // collateralization ratio = 1+2^-leverageTier
    function get(
        address addrFactory,
        address addrDebtToken,
        address addrCollateralToken,
        int256 leverageTier,
        address oracle,
        address poolLogic
    ) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            addrFactory,
                            bytes32(0), // Salt
                            keccak256(
                                abi.encodePacked(
                                    type(Pool).creationCode,
                                    abi.encode(addrDebtToken, addrCollateralToken, leverageTier, oracle, poolLogic)
                                )
                            )
                        )
                    )
                )
            )
        );
    }
}
