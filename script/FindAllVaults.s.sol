// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
// import "forge-std/console.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {IERC20} from "v2-core/interfaces/IERC20.sol";
import {AddressClone} from "src/libraries/AddressClone.sol";

/** @dev cli for local testnet:  forge script script/FindAllVaults.s.sol --rpc-url tarp_testnet --broadcast --legacy
    @dev cli for Sepolia:        forge script script/FindAllVaults.s.sol --rpc-url sepolia --chain sepolia --broadcast --slow
*/
contract FindAllVaults is Script {
    uint256 privateKey;

    Vault vault;

    function setUp() public {
        if (block.chainid == 1) {
            privateKey = vm.envUint("TARP_TESTNET_PRIVATE_KEY");
        } else if (block.chainid == 11155111) {
            privateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else {
            revert("Network not supported");
        }

        vault = Vault(vm.envAddress("VAULT"));
    }

    function run() public {
        vm.startBroadcast(privateKey);

        console.log("Vault bytecode length:", address(vault).code.length);

        uint256 Nvaults = vault.numberOfVaults();
        console.log("Number of vaults: ", Nvaults);

        console.log("");
        console.log("");
        console.log("------ WETH Total Reserves ------");
        console.log("");
        uint256 wethReserves = vault.totalReserves(Addresses.ADDR_WETH);
        console.log("WETH reserves:", wethReserves);
        console.log("WETH fees:", IERC20(Addresses.ADDR_WETH).balanceOf(address(vault)) - wethReserves);

        // Check vaults
        for (uint48 i = 1; i <= Nvaults; i++) {
            console.log("");
            console.log("");
            console.log("------ Vault ID: ", i, " ------");
            console.log("");
            SirStructs.VaultParameters memory vaultParams = vault.paramsById(i);
            console.log("debtToken:", vaultParams.debtToken);
            console.log("collateralToken:", vaultParams.collateralToken);
            address ape = AddressClone.getAddress(address(vault), i);
            console.log("ape token:", ape);
            console.log("leverageTier:", vm.toString(vaultParams.leverageTier));
            console.log("");

            SirStructs.Reserves memory reserves = vault.getReserves(vaultParams);
            string memory collateralSymbol = IERC20(vaultParams.collateralToken).symbol();
            uint256 teaTotalSupply = vault.totalSupply(i);
            console.log("Supply of TEA:", teaTotalSupply);
            console.log("Supply of APE:", IERC20(ape).totalSupply());
            console.log("LP reserve:", reserves.reserveLPers, collateralSymbol);
            console.log("Apes reserve:", reserves.reserveApes, collateralSymbol);
            console.log("Reserve:", reserves.reserveLPers + reserves.reserveApes, collateralSymbol);
            console.log(
                "Reserve (in human units):",
                (reserves.reserveLPers + reserves.reserveApes) / 10 ** IERC20(vaultParams.collateralToken).decimals(),
                collateralSymbol
            );
            console.log("");

            uint256 teaBalanceOfVault = vault.balanceOf(address(vault), i);
            console.log("Vault TEA balance:", teaBalanceOfVault);
            console.log("POL:", teaTotalSupply == 0 ? 0 : (teaBalanceOfVault * 100) / teaTotalSupply, "%");
            console.log("");

            uint256 minReserveLPers = vaultParams.leverageTier >= 0
                ? uint256(reserves.reserveApes) << uint256(int256(vaultParams.leverageTier))
                : uint256(reserves.reserveApes) >> uint256(int256(-vaultParams.leverageTier));

            if (minReserveLPers != 0) {
                console.log("G =", (uint256(reserves.reserveLPers) * 100) / minReserveLPers, "% of Gmin");
                uint256 GRatio = (uint256(reserves.reserveLPers) * 2 ** 112) / minReserveLPers;
                console.log(
                    "Apes:",
                    GRatio >= 1.25 * 2 ** 112 ? "Healthy, more than enough liquidity" : GRatio >= 2 ** 112
                        ? "Borderline, just enough liquidity"
                        : "Degraded, insufficient liquidity for constant leverage. Real leverage:",
                    ((uint256(reserves.reserveApes) + reserves.reserveLPers) * 100) / reserves.reserveApes,
                    "%x"
                );
                console.log(
                    "Gentlemen:",
                    GRatio >= 1.25 * 2 ** 112 ? "Minimally profitable" : GRatio >= 2 ** 112
                        ? "Moderately profitable"
                        : "Highly profitable"
                );
            } else {
                console.log("Apes: Healthy, more than enough liquidity");
                console.log("Gentlemen: Highly profitable");
            }

            // SIR rewards?
            uint8 tax = vault.vaultTax(i);
            SirStructs.SystemParameters memory systemParams = vault.systemParams();
            console.log(
                "Rewards for the first 3 years:",
                (uint256(tax) * 1 days * SystemConstants.LP_ISSUANCE_FIRST_3_YEARS) /
                    systemParams.cumulativeTax /
                    10 ** (SystemConstants.SIR_DECIMALS),
                "SIR/day"
            );
            console.log(
                "Rewards after the first 3 years:",
                (uint256(tax) * 1 days * SystemConstants.ISSUANCE) /
                    systemParams.cumulativeTax /
                    10 ** (SystemConstants.SIR_DECIMALS),
                "SIR/day"
            );
        }
    }
}
