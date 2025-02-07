// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Contributors {
    /** @dev Total contributor allocation: 31.87%
        @dev LP allocation: 68.13%
        @dev Sum of all allocations must be equal to type(uint56).max.
     */
    function getAllocation(address contributor) internal pure returns (uint56) {
        if (contributor == address(0xFe202706E36F31aFBaf4b4543C2A8bBa4ddB2deE)) return 1016805183978287;
        else if (contributor == address(0xEdA726014938d2E6Ed51c7d5A53193cf9713cdF7)) return 474509085856534;
        else if (contributor == address(0xE19618C08F74b7e80278Ec14b63797419dACCDf8)) return 451913415101461;
        else if (contributor == address(0x0000000000000000000000000000000000000002)) return 5648917688768261;
        else if (contributor == address(0x8D2a097607da5E2E3d599c72EC50FD0704a4D37f)) return 949018171713068;
        else if (contributor == address(0xde3697dDA384ce178d04D8879F7a66423F72A326)) return 361530732081169;
        else if (contributor == address(0x3424cd7D170949636C300e62674a3DFB7706Fc35)) return 881231159447849;
        else if (contributor == address(0x0000000000000000000000000000000000000005)) return 338935061326096;
        else if (contributor == address(0x30E14c4b4768F9B5F520a2F6214d2cCc21255fDa)) return 2937437198159496;
        else if (contributor == address(0x0000000000000000000000000000000000000001)) return 18076536604058435;
        else if (contributor == address(0x241F1A461Da47Ccd40B48c38340896A9948A4725)) return 316339390571023;
        else if (contributor == address(0x32cf4d1df6fb7bB173183CF8b51EF9499c803634)) return 316339390571023;
        else if (contributor == address(0xa485B739e99334f4B92B04da2122e2923a054688)) return 293743719815950;
        else if (contributor == address(0x1ff241abaD54DEcB967Bd0f57c2a584C7d1ca8BD)) return 271148049060877;
        else if (contributor == address(0x7DF76FDEedE91d3cB80e4a86158dD9f6D206c98E)) return 248552378305804;
        else if (contributor == address(0xBA5EDc0d2Ae493C9574328d77dc36eEF19F699e2)) return 225956707550731;
        else if (contributor == address(0x0000000000000000000000000000000000000007)) return 225956707550730;
        else if (contributor == address(0x36D11126eBc59cb962AE8ddD3bcD0741b4e337Dc)) return 5400365310462457;
        else if (contributor == address(0x0e52b591Cbc9AB81c806F303DE8d9a3B0Dc4ea5C)) return 2259567075507304;
        else if (contributor == address(0xfdcc69463b0106888D1CA07CE118A64AdF9fe458)) return 2259567075507304;
        else if (contributor == address(0xA6f4fa9840Aa6825446c820aF6d5eCcf9f78BA05)) return 158169695285511;
        else if (contributor == address(0x18e17dd452Ef58F91E45fD20Eb2F839ac13AA648)) return 677870122652191;
        else if (contributor == address(0x1234567890123456789000000000000000000000)) return 22595670755073043;
        else if (contributor == address(0xa233f74638Bd28A24CC2Ce23475eea7dC76881AC)) return 112978353775365;
        else if (contributor == address(0x0000000000000000000000000000000000000008)) return 112978353775365;
        else if (contributor == address(0x0000000000000000000000000000000000000009)) return 112978353775365;
        else if (contributor == address(0x16fD74300dcDc02E9b1E594f293c6EfFB299a3fc)) return 112978353775365;
        else if (contributor == address(0xbe1E110f4A2fD54622CD516e86b29f619ad994bF)) return 112978353775365;
        else if (contributor == address(0xdF58360e945F6a302FFFB012D114C9e2bE2F212a)) return 90382683020292;
        else if (contributor == address(0x65a831D9fB2CC87A7956eB8E4720956f6bfC6eeA)) return 90382683020292;
        else if (contributor == address(0x6422D607CA13457589A1f2dbf0ec63d5Adf87BFB)) return 90382683020292;
        else if (contributor == address(0x26610e89A8B825F23E89e58879cE97D791aD4438)) return 1129783537753652;
        else if (contributor == address(0x0D5f69C67DAE06ce606246A8bd88B552d1DdE140)) return 67787012265219;
        else if (contributor == address(0xF613cfD07af6D011fD671F98064214aB5B2942CF)) return 67787012265219;
        else if (contributor == address(0xc4Ab0e3F12309f37A5cdf3A4b3B7C70A53eeBBa9)) return 67787012265219;
        else if (contributor == address(0xAacc079965F0F9473BF4299d930eF639690a9792)) return 67787012265219;
        else if (contributor == address(0x81B55FBe66C5FFbb8468328E924AF96a84438F14)) return 67787012265219;
        else if (contributor == address(0xb1f55485d7ebA772F0d454Ceb0EA9a27586Ad86f)) return 45191341510146;
        else if (contributor == address(0x1C5EB68630cCd90C3152FB9Dee3a1C2A7201631D)) return 45191341510146;
        else if (contributor == address(0xe4F047C5DEB2659f3659057fe5cAFB5bC6bD4307)) return 22595670755073;
        else if (contributor == address(0x07bfeB5488ad97aA3920cf241E59d2A817054eA3)) return 22595670755073;
        else if (contributor == address(0xC3632CD03BEd246719965bB74279af79bE4bd813)) return 22595670755073;
        else if (contributor == address(0x0C0aB132F5a8d0988e88997cb2604F494052BDEF)) return 22595670755073;
        else if (contributor == address(0x78086Ad810f8F99A0B6c92a9A6c8857d3c665622)) return 542296098121753;
        else if (contributor == address(0x79C1134a1dFdF7e0d58E58caFC84a514991372e6)) return 1061996525488433;
        else if (contributor == address(0xC58D3aE892A104D663B01194f2EE325CfB5187f2)) return 1581696952855113;
        
        return 0;
    }
}