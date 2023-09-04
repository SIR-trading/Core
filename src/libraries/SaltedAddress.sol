// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library SaltedAddress {
    bytes32 private constant _HASH_CREATION_CODE_APE =
        0x36af10401bb78153f4e90dbeb1fad843a0704d3884a00ab6d41ebca444f24edd; // keccak256(abi.encodePacked(vm.getCode("APE.sol:APE")))

    function getSalt(uint256 vaultId) internal pure returns (bytes32 saltAPE) {
        /**
            DUMMY IMPLEMENTATION
            I WANT TO GET MINED SALTS THAT RETURN ADDRESSES WITH PREFIXES a9e 
         */
        saltAPE = bytes32(vaultId);
    }

    function getAddress(uint256 vaultId) internal view returns (address) {
        bytes32 salt = getSalt(vaultId);

        return
            address(
                uint160(uint(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, _HASH_CREATION_CODE_APE))))
            );
    }
}
