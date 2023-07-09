// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../TEA.sol";

library AddressTEA {
    function get(address addrVault, address addrDebtToken, address addrCollateralToken, int256 leverageTier)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            addrVault,
                            bytes32(0), // Salt
                            keccak256(
                                abi.encodePacked(
                                    type(TEA).creationCode, abi.encode(addrDebtToken, addrCollateralToken, leverageTier)
                                )
                            )
                        )
                    )
                )
            )
        );
    }
}
