// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Contributors {
    /** @dev This library is generated by the script `generate-contributors.js`.
        @dev An allocation of type(uint56).max means 100% of the issuance reserved for contributors. 
        @dev Sum of all allocations should be equal to type(uint56).max or less.
    */
    function getAllocation(address contributor) internal pure returns (uint56) {
        if (contributor == address(0x90F79bf6EB2c4f870365E785982E1f101E93b906)) return 22912059411461612;
        else if (contributor == address(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65)) return 68736178234384;
        else if (contributor == address(0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc)) return 22912059411461;
        else if (contributor == address(0x976EA74026E726554dB657fA54763abd0C3a0aa9)) return 11456029705730806;
        else if (contributor == address(0x14dC79964da2C08b23698B3D3cc7Ca32193d9955)) return 1583223305331997;
        else if (contributor == address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC)) return 16507345909750544;
        else if (contributor == address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)) return 1500560574462087;
        else if (contributor == address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8)) return 18006726893545044;
        
        return 0;
    }
}
