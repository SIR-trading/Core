// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library AddressClone {
    /// @dev Hash of the `_CREATE3_PROXY_BYTECODE`.
    /// Equivalent to `keccak256(abi.encodePacked(hex"67363d3d37363d34f03d5260086018f3"))`.
    bytes32 private constant _CREATE3_PROXY_BYTECODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    function getAddress(address deployer, uint256 vaultId) internal pure returns (address clone) {
        /// @solidity memory-safe-assembly
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Cache the free memory pointer.
            let m := mload(0x40)
            // Store `address(this)`.
            mstore(0x00, deployer)
            // Store the prefix.
            mstore8(0x0b, 0xff)
            // Store the salt.
            mstore(0x20, vaultId)
            // Store the bytecode hash.
            mstore(0x40, _CREATE3_PROXY_BYTECODE_HASH)

            // Store the proxy's address.
            mstore(0x14, keccak256(0x0b, 0x55))
            // Restore the free memory pointer.
            mstore(0x40, m)
            // 0xd6 = 0xc0 (short RLP prefix) + 0x16 (length of: 0x94 ++ proxy ++ 0x01).
            // 0x94 = 0x80 + 0x14 (0x14 = the length of an address, 20 bytes, in hex).
            mstore(0x00, 0xd694)
            // Nonce of the proxy contract (1).
            mstore8(0x34, 0x01)

            clone := and(keccak256(0x1e, 0x17), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
