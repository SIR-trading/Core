// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library SaltedAddress {
    function getSalt(uint256 vaultId) internal pure returns (bytes32 saltAPE) {
        /**
            DUMMY IMPLEMENTATION
            I WANT TO GET MINED SALTS THAT RETURN ADDRESSES WITH PREFIXES a9e 
         */
        saltAPE = bytes32(vaultId);
    }

    function getAddress(uint256 vaultId, bytes32 hashCreationCodeAPE) internal view returns (address) {
        bytes32 salt = getSalt(vaultId);

        return
            address(uint160(uint(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hashCreationCodeAPE)))));
    }
}
