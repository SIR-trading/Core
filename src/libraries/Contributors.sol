// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Contributors {
    /** @dev Total contributor allocation: 31.87%
        @dev LP allocation: 68.13%
        @dev Sum of all allocations must be equal to type(uint56).max.
     */
    function getAllocation(address contributor) internal pure returns (uint56) {
        if (contributor == address(0xAacc079965F0F9473BF4299d930eF639690a9792)) return 58779012666421;
        else if (contributor == address(0xa485B739e99334f4B92B04da2122e2923a054688)) return 293895063332101;
        else if (contributor == address(0x1C5EB68630cCd90C3152FB9Dee3a1C2A7201631D)) return 37980285107534;
        else if (contributor == address(0x0e52b591Cbc9AB81c806F303DE8d9a3B0Dc4ea5C)) return 2260731256400770;
        else if (contributor == address(0xfdcc69463b0106888D1CA07CE118A64AdF9fe458)) return 2260731256400770;
        else if (contributor == address(0xF613cfD07af6D011fD671F98064214aB5B2942CF)) return 67369791440744;
        else if (contributor == address(0x3424cd7D170949636C300e62674a3DFB7706Fc35)) return 881685189996301;
        else if (contributor == address(0x0000000000000000000000000000000000000007)) return 226073125640078;
        else if (contributor == address(0x241F1A461Da47Ccd40B48c38340896A9948A4725)) return 323058496539671;
        else if (contributor == address(0x6422D607CA13457589A1f2dbf0ec63d5Adf87BFB)) return 81838471481709;
        else if (contributor == address(0xE19618C08F74b7e80278Ec14b63797419dACCDf8)) return 452146251280155;
        else if (contributor == address(0xbe1E110f4A2fD54622CD516e86b29f619ad994bF)) return 107859488242882;
        else if (contributor == address(0x30E14c4b4768F9B5F520a2F6214d2cCc21255fDa)) return 2938950633321001;
        else if (contributor == address(0x0C0aB132F5a8d0988e88997cb2604F494052BDEF)) return 22607312564009;
        else if (contributor == address(0x8D2a097607da5E2E3d599c72EC50FD0704a4D37f)) return 940170307599389;
        else if (contributor == address(0x78086Ad810f8F99A0B6c92a9A6c8857d3c665622)) return 539885231341069;
        else if (contributor == address(0x18e17dd452Ef58F91E45fD20Eb2F839ac13AA648)) return 678219376920232;
        else if (contributor == address(0xc4Ab0e3F12309f37A5cdf3A4b3B7C70A53eeBBa9)) return 63024665965942;
        else if (contributor == address(0xFe202706E36F31aFBaf4b4543C2A8bBa4ddB2deE)) return 1012807602867546;
        else if (contributor == address(0x7DF76FDEedE91d3cB80e4a86158dD9f6D206c98E)) return 254513124845600;
        else if (contributor == address(0xe4F047C5DEB2659f3659057fe5cAFB5bC6bD4307)) return 28033067579371;
        else if (contributor == address(0x26610e89A8B825F23E89e58879cE97D791aD4438)) return 1130365628200386;
        else if (contributor == address(0x32cf4d1df6fb7bB173183CF8b51EF9499c803634)) return 307120341182045;
        else if (contributor == address(0x0000000000000000000000000000000000000008)) return 113036562820039;
        else if (contributor == address(0x0000000000000000000000000000000000000009)) return 113036562820039;
        else if (contributor == address(0x16fD74300dcDc02E9b1E594f293c6EfFB299a3fc)) return 113036562820039;
        else if (contributor == address(0xa233f74638Bd28A24CC2Ce23475eea7dC76881AC)) return 117662018970635;
        else if (contributor == address(0xA6f4fa9840Aa6825446c820aF6d5eCcf9f78BA05)) return 162998723586496;
        else if (contributor == address(0x0000000000000000000000000000000000000001)) return 18085850051206152;
        else if (contributor == address(0xEdA726014938d2E6Ed51c7d5A53193cf9713cdF7)) return 471362466959560;
        else if (contributor == address(0x0000000000000000000000000000000000000005)) return 339109688460115;
        else if (contributor == address(0x0000000000000000000000000000000000000002)) return 5651828141001922;
        else if (contributor == address(0xdF58360e945F6a302FFFB012D114C9e2bE2F212a)) return 89072811502190;
        else if (contributor == address(0x65a831D9fB2CC87A7956eB8E4720956f6bfC6eeA)) return 87228054796967;
        else if (contributor == address(0xBA5EDc0d2Ae493C9574328d77dc36eEF19F699e2)) return 230142441901598;
        else if (contributor == address(0x1ff241abaD54DEcB967Bd0f57c2a584C7d1ca8BD)) return 271287750768092;
        else if (contributor == address(0x36D11126eBc59cb962AE8ddD3bcD0741b4e337Dc)) return 5411195906070625;
        else if (contributor == address(0x81B55FBe66C5FFbb8468328E924AF96a84438F14)) return 56518281410019;
        else if (contributor == address(0x1234567890123456789000000000000000000000)) return 22607312564007688;
        else if (contributor == address(0x07bfeB5488ad97aA3920cf241E59d2A817054eA3)) return 23963751317848;
        else if (contributor == address(0xC3632CD03BEd246719965bB74279af79bE4bd813)) return 23963751317848;
        else if (contributor == address(0xb1f55485d7ebA772F0d454Ceb0EA9a27586Ad86f)) return 53353257651058;
        else if (contributor == address(0xC58D3aE892A104D663B01194f2EE325CfB5187f2)) return 1582511879480538;
        else if (contributor == address(0x0D5f69C67DAE06ce606246A8bd88B552d1DdE140)) return 67821937692023;
        else if (contributor == address(0xde3697dDA384ce178d04D8879F7a66423F72A326)) return 355906921695173;
        else if (contributor == address(0x79C1134a1dFdF7e0d58E58caFC84a514991372e6)) return 1061548968755545;
        
        return 0;
    }
}