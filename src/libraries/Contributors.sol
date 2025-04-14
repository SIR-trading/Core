// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Contributors {
    /** @dev Total contributor allocation: 31.87%
     *  LP allocation: 68.13%
     *  Sum of all allocations must be equal to type(uint56).max.
     */
    function getAllocation(address contributor) internal pure returns (uint56) {
        // -------- Presale Contributors --------
        if (contributor == address(0x36D11126eBc59cb962AE8ddD3bcD0741b4e337Dc)) return 5_411_195_906_070_626; // 2.3936%
        else if (contributor == address(0x30E14c4b4768F9B5F520a2F6214d2cCc21255fDa)) return 2_938_950_633_321_000; // 1.3000%
        else if (contributor == address(0x26610e89A8B825F23E89e58879cE97D791aD4438)) return 1_130_365_628_200_385; // 0.5000%
        else if (contributor == address(0x79C1134a1dFdF7e0d58E58caFC84a514991372e6)) return 1_061_548_968_755_546; // 0.4696%
        else if (contributor == address(0xFe202706E36F31aFBaf4b4543C2A8bBa4ddB2deE)) return 1_012_807_602_867_545; // 0.4480%
        else if (contributor == address(0x8D2a097607da5E2E3d599c72EC50FD0704a4D37f)) return 940_170_307_599_388; // 0.4159%
        else if (contributor == address(0x3424cd7D170949636C300e62674a3DFB7706Fc35)) return 881_685_189_996_300; // 0.3900%
        else if (contributor == address(0x18e17dd452Ef58F91E45fD20Eb2F839ac13AA648)) return 678_219_376_920_231; // 0.3000%
        else if (contributor == address(0x78086Ad810f8F99A0B6c92a9A6c8857d3c665622)) return 539_885_231_341_068; // 0.2388%
        else if (contributor == address(0xEdA726014938d2E6Ed51c7d5A53193cf9713cdF7)) return 471_362_466_959_561; // 0.2085%
        else if (contributor == address(0xE19618C08F74b7e80278Ec14b63797419dACCDf8)) return 452_146_251_280_154; // 0.2000%
        else if (contributor == address(0xde3697dDA384ce178d04D8879F7a66423F72A326)) return 355_906_921_695_174; // 0.1574%
        else if (contributor == address(0x32cf4d1df6fb7bB173183CF8b51EF9499c803634)) return 307_120_341_182_045; // 0.1359%
        else if (contributor == address(0xa485B739e99334f4B92B04da2122e2923a054688)) return 293_895_063_332_101; // 0.1300%
        else if (contributor == address(0x1ff241abaD54DEcB967Bd0f57c2a584C7d1ca8BD)) return 271_287_750_768_093; // 0.1200%
        else if (contributor == address(0x7DF76FDEedE91d3cB80e4a86158dD9f6D206c98E)) return 254_513_124_845_599; // 0.1126%
        else if (contributor == address(0xBA5EDc0d2Ae493C9574328d77dc36eEF19F699e2)) return 230_142_441_901_599; // 0.1018%
        else if (contributor == address(0xA6f4fa9840Aa6825446c820aF6d5eCcf9f78BA05)) return 162_998_723_586_496; // 0.0721%
        else if (contributor == address(0xa233f74638Bd28A24CC2Ce23475eea7dC76881AC)) return 117_662_018_970_635; // 0.0520%
        else if (contributor == address(0x16fD74300dcDc02E9b1E594f293c6EfFB299a3fc)) return 113_036_562_820_039; // 0.0500%
        else if (contributor == address(0xbe1E110f4A2fD54622CD516e86b29f619ad994bF)) return 107_859_488_242_881; // 0.0477%
        else if (contributor == address(0xdF58360e945F6a302FFFB012D114C9e2bE2F212a)) return 89_072_811_502_191; // 0.0394%
        else if (contributor == address(0x65a831D9fB2CC87A7956eB8E4720956f6bfC6eeA)) return 87_228_054_796_968; // 0.0386%
        else if (contributor == address(0x6422D607CA13457589A1f2dbf0ec63d5Adf87BFB)) return 81_838_471_481_708; // 0.0362%
        else if (contributor == address(0x0D5f69C67DAE06ce606246A8bd88B552d1DdE140)) return 67_821_937_692_024; // 0.0300%
        else if (contributor == address(0xF613cfD07af6D011fD671F98064214aB5B2942CF)) return 67_369_791_440_743; // 0.0298%
        else if (contributor == address(0xc4Ab0e3F12309f37A5cdf3A4b3B7C70A53eeBBa9)) return 63_024_665_965_941; // 0.0279%
        else if (contributor == address(0xAacc079965F0F9473BF4299d930eF639690a9792)) return 58_779_012_666_421; // 0.0260%
        else if (contributor == address(0x81B55FBe66C5FFbb8468328E924AF96a84438F14)) return 56_518_281_410_020; // 0.0250%
        else if (contributor == address(0xb1f55485d7ebA772F0d454Ceb0EA9a27586Ad86f)) return 53_353_257_651_059; // 0.0236%
        else if (contributor == address(0x1C5EB68630cCd90C3152FB9Dee3a1C2A7201631D)) return 37_980_285_107_533; // 0.0168%
        else if (contributor == address(0xe4F047C5DEB2659f3659057fe5cAFB5bC6bD4307)) return 28_033_067_579_370; // 0.0124%
        else if (contributor == address(0xC3632CD03BEd246719965bB74279af79bE4bd813)) return 23_963_751_317_849; // 0.0106%
        else if (contributor == address(0x07bfeB5488ad97aA3920cf241E59d2A817054eA3)) return 23_963_751_317_849; // 0.0106%
        else if (contributor == address(0x0C0aB132F5a8d0988e88997cb2604F494052BDEF)) return 22_607_312_564_008; // 0.0100%

        // -------- Spice Contributors --------
        if (contributor == address(0xa1a841D79758Bd4b06c9206e97343dFeBcBE200b)) return 18_085_850_051_206_153; // 8.0000%
        else if (contributor == address(0xd11f322ad85730Eab11ef61eE9100feE84b63739)) return 5_651_828_141_001_923; // 2.5000%
        else if (contributor == address(0xfdcc69463b0106888D1CA07CE118A64AdF9fe458)) return 2_260_731_256_400_770; // 1.0000%
        else if (contributor == address(0x0e52b591Cbc9AB81c806F303DE8d9a3B0Dc4ea5C)) return 2_260_731_256_400_770; // 1.0000%
        else if (contributor == address(0xC58D3aE892A104D663B01194f2EE325CfB5187f2)) return 1_582_511_879_480_539; // 0.7000%
        else if (contributor == address(0x65665e10EB86D72b02067863342277EA2DF78516)) return 339_109_688_460_116; // 0.1500%
        else if (contributor == address(0x241F1A461Da47Ccd40B48c38340896A9948A4725)) return 323_058_496_539_670; // 0.1429%
        else if (contributor == address(0xe59813A4a120288dbf42630C051e3921E5dAbCd8)) return 226_073_125_640_077; // 0.1000%
        else if (contributor == address(0x40FEfD52714f298b9EaD6760753aAA720438D4bB)) return 113_036_562_820_039; // 0.0500%
        else if (contributor == address(0x8D677d312F2CA04dF98eB22ce886bE8E7804280d)) return 113_036_562_820_039; // 0.0500%

        // -------- Treasury --------
        if (contributor == address(0x686748764c5C7Aa06FEc784E60D14b650bF79129)) return 22_607_312_564_007_689; // 10.0000%
        
        return 0;
    }
}