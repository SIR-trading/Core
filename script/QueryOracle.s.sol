// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
// import "forge-std/console.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {AddressesSepolia} from "src/libraries/AddressesSepolia.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Oracle} from "src/Oracle.sol";
import {Vault} from "src/Vault.sol";
import {IERC20} from "v2-core/interfaces/IERC20.sol";
import {ABDKMath64x64} from "abdk/ABDKMath64x64.sol";
import {UniswapPoolAddress} from "src/libraries/UniswapPoolAddress.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

/** @dev cli for local testnet:  forge script script/QueryOracle.s.sol --rpc-url tarp_testnet --broadcast --legacy
    @dev cli for Sepolia:        forge script script/QueryOracle.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract QueryOracle is Script {
    using ABDKMath64x64 for int128;
    int128 log2TickBase;

    uint256 privateKey;

    Vault vault;
    Oracle oracle;

    uint48 vaultId = 2;
    uint24 feeTier = 100;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        oracle = Oracle(vm.envAddress("ORACLE"));
        vault = Vault(vm.envAddress("VAULT"));

        log2TickBase = ABDKMath64x64.divu(10001, 10000).log_2(); // log_2(1.0001)
    }

    function run() public {
        vm.startBroadcast(privateKey);

        SirStructs.VaultParameters memory vaultParams = vault.paramsById(vaultId);
        int64 tickPriceX42 = -oracle.getPrice(vaultParams.collateralToken, vaultParams.debtToken);
        console.log("Price (getPrice function) [\u2030]:", _tickToPricePerMille(vaultParams, tickPriceX42));

        // Get Uniswap pool
        IUniswapV3Pool pool = IUniswapV3Pool(
            UniswapPoolAddress.computeAddress(
                block.chainid == 1 ? Addresses.ADDR_UNISWAPV3_FACTORY : AddressesSepolia.ADDR_UNISWAPV3_FACTORY,
                UniswapPoolAddress.getPoolKey(vaultParams.collateralToken, vaultParams.debtToken, feeTier)
            )
        );

        (uint160 sqrtPriceX96, , , uint16 cardinalityNow, uint16 cardinalityNext, , ) = pool.slot0();

        uint256 pricePerMilleInstant = ABDKMath64x64
            .divu(sqrtPriceX96, 2 ** 96)
            .pow(2)
            .mul(
                ABDKMath64x64.fromUInt(
                    10 ** (IERC20(vaultParams.collateralToken).decimals() - IERC20(vaultParams.debtToken).decimals())
                )
            )
            .mul(ABDKMath64x64.fromUInt(1000))
            .toUInt();
        console.log("Price instant [\u2030]:", pricePerMilleInstant);

        // Retrieve oracle info from Uniswap v3
        uint32[] memory interval = new uint32[](2);
        interval[0] = uint32(30 minutes);
        interval[1] = 0;

        try pool.observe(interval) returns (int56[] memory tickCumulatives, uint160[] memory) {
            tickPriceX42 = int64((int256(tickCumulatives[1] - tickCumulatives[0]) << 42) / 30 minutes);
            console.log(tickPriceX42);
            console.log("Price (from pool) [\u2030]:", _tickToPricePerMille(vaultParams, tickPriceX42));
        } catch Error(string memory reason) {
            if (keccak256(bytes(reason)) == keccak256(bytes("OLD")))
                console.log("Price (from pool) [\u2030]: TWAP too short");
            else console.log("Price (from pool) [\u2030]: unknown error");
        }

        // Get cardinality
        console.log("Cardinality now:", cardinalityNow);
        console.log("Cardinality next:", cardinalityNext);
    }

    function _tickToPricePerMille(
        SirStructs.VaultParameters memory vaultParams,
        int64 tickPriceX42
    ) internal view returns (uint256) {
        return
            ABDKMath64x64
                .divi(tickPriceX42, 2 ** 42)
                .mul(log2TickBase)
                .exp_2()
                .mul(
                    ABDKMath64x64.fromUInt(
                        10 **
                            (IERC20(vaultParams.collateralToken).decimals() - IERC20(vaultParams.debtToken).decimals())
                    )
                )
                .mul(ABDKMath64x64.fromUInt(1000))
                .toUInt();
    }
}
