// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Libraries
import "@openzeppelin/contracts/utils/Strings.sol";

library TokenNaming {
    function _generateSymbol(string memory symbolPrefix, address addr) internal pure returns (string memory) {
        return string(abi.encodePacked(symbolPrefix, Strings.toHexString(uint256(uint160(addr)), 5)));
    }
}
