// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "openzeppelin/utils/math/Math.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

contract FindDifferentialSalts is Script {
    bytes32 private immutable _HASH_CREATION_CODE_APE;
    uint256 private constant _N_BITS_PER_SALT = 16;
    uint256 private constant _N_SALTS_PER_WORD = 256 / _N_BITS_PER_SALT;
    uint256 private constant _N_HITS = (24576 * 8) / _N_BITS_PER_SALT; // 24576 bytes in a contract / 2 bytes (16 bits) per salt

    constructor() {
        _HASH_CREATION_CODE_APE = keccak256(abi.encodePacked(vm.getCode("APE.sol:APE")));
    }

    function setUp() public {}

    /** It seems like 16 bits may be enough to store a large # of differential salts.
        Basically we could fill up a whole contract.
     */
    function run() public {
        vm.pauseGasMetering();
        vm.writeFile("saltsDiff.txt", "");

        bytes32 free_mem;
        assembly ("memory-safe") {
            free_mem := mload(0x40)
        }

        uint256 i;
        uint256 iLastHit;
        bytes2 firstThreeLetters;
        bytes32 salt;
        uint256 hits;
        uint256 diffSalt;
        uint256 maxDiffSalt;
        uint256 word;
        while (hits < _N_HITS) {
            salt = bytes32(i);
            firstThreeLetters = bytes2(
                uint16(
                    uint160(
                        uint(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, _HASH_CREATION_CODE_APE)))
                    ) >> (160 - 4 * 3)
                )
            );

            // a9e ≈ ape
            if (firstThreeLetters == 0x0a9e) {
                diffSalt = i - iLastHit;
                require(diffSalt < 2 ** _N_BITS_PER_SALT);
                // console.logBytes2(bytes2(uint16(diffSalt)));
                if (hits % _N_SALTS_PER_WORD == 0) {
                    if (hits > 0) vm.writeLine("saltsDiff.txt", Strings.toHexString(word, 32));
                    word = diffSalt;
                } else {
                    word |= diffSalt << ((hits % _N_SALTS_PER_WORD) * _N_BITS_PER_SALT);
                }
                if (diffSalt > maxDiffSalt) maxDiffSalt = diffSalt;

                // console.log(diffSalt);
                iLastHit = i;
                ++hits;
            }

            assembly ("memory-safe") {
                mstore(0x40, free_mem)
            }

            ++i;
        }

        console.log(_N_HITS, "salts");
        console.log("Maximum salt is", i - 1);
        console.log("Maximum differential salt is", maxDiffSalt);
    }
}
