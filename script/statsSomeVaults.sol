// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
// import "forge-std/console.sol";

import {Addresses} from "src/libraries/Addresses.sol";
import {AddressesSepolia} from "src/libraries/AddressesSepolia.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {IERC20} from "v2-core/interfaces/IERC20.sol";
import {AddressClone} from "src/libraries/AddressClone.sol";

/** @dev cli for local testnet:  forge script script/statsSomeVaults.s.sol --rpc-url mainnet --chain 1 --broadcast
    @dev cli for Sepolia:        forge script script/statsSomeVaults.s.sol --rpc-url sepolia --chain sepolia --broadcast
*/
contract statsSomeVaults is Script {
    uint48[4] vaultsIds = [1, 2, 8, 10];
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

        // Check vaults
        for (uint48 i = 0; i < vaultsIds.length; i++) {
            uint48 vaultId = vaultsIds[i];

            console.log("");
            console.log("");
            console.log("------ Vault ID: ", vaultId, " ------");
            console.log("");
            SirStructs.VaultParameters memory vaultParams = vault.paramsById(vaultId);
            console.log("debtToken:", vaultParams.debtToken);
            console.log("collateralToken:", vaultParams.collateralToken);
            address ape = AddressClone.getAddress(address(vault), vaultId);
            console.log("ape token:", ape);
            console.log("leverageTier:", vm.toString(vaultParams.leverageTier));
            console.log("");

            SirStructs.Reserves memory reserves = vault.getReserves(vaultParams);
            string memory collateralSymbol = IERC20(vaultParams.collateralToken).symbol();
            uint256 teaTotalSupply = vault.totalSupply(vaultId);
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

            uint256 teaBalanceOfVault = vault.balanceOf(address(vault), vaultId);
            console.log("Vault TEA balance:", teaBalanceOfVault);
            console.log("POL:", teaTotalSupply == 0 ? 0 : (teaBalanceOfVault * 100) / teaTotalSupply, "%");
            console.log("");

            uint256 minReserveLPers = vaultParams.leverageTier >= 0
                ? uint256(reserves.reserveApes) << uint256(int256(vaultParams.leverageTier))
                : uint256(reserves.reserveApes) >> uint256(int256(-vaultParams.leverageTier));

            console.log("Gmin =", minReserveLPers);
            if (minReserveLPers != 0) {
                console.log("G =", (uint256(reserves.reserveLPers) * 100) / minReserveLPers, "% of Gmin");
                uint256 GRatio = (uint256(reserves.reserveLPers) * 2 ** 112) / minReserveLPers;
                console.log(
                    "Apes:",
                    GRatio >= 1.25 * 2 ** 112
                        ? "Healthy, more than enough liquidity"
                        : GRatio >= 2 ** 112
                            ? "Borderline, just enough liquidity"
                            : "Degraded, insufficient liquidity for constant leverage. Real leverage:",
                    ((uint256(reserves.reserveApes) + reserves.reserveLPers) * 100) / reserves.reserveApes,
                    "%x"
                );
                console.log("Gentlemen:", GRatio >= 1.25 * 2 ** 112 ? "Moderately profitable" : "Highly profitable");
            } else if (reserves.reserveLPers == 0) {
                console.log("Apes: Degraded, insufficient liquidity for constant leverage");
                console.log("Gentlemen: Moderately profitable");
            } else {
                console.log("Apes: Healthy, more than enough liquidity");
                console.log("Gentlemen: Moderately profitable");
            }

            // SIR rewards?
            uint8 tax = vault.vaultTax(vaultId);
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
