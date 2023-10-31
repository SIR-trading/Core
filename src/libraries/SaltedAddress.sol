// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {APE} from "../APE.sol";

library SaltedAddress {
    bytes32 private constant _HASH_CREATION_CODE_APE = keccak256(type(APE).creationCode);

    function getAddress(uint256 vaultId) internal view returns (address) {
        return
            address(
                uint160(
                    uint(
                        keccak256(
                            abi.encodePacked(bytes1(0xff), address(this), bytes32(vaultId), _HASH_CREATION_CODE_APE)
                        )
                    )
                )
            );
    }
}
