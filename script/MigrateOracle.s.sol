// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {Oracle} from "src/Oracle.sol";
import {SystemControl} from "src/SystemControl.sol";
import {Vault} from "src/Vault.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";

/**
 * @title MigrateOracle
 * @notice Script to migrate the SIR protocol to a new Oracle pointing to a different Uniswap V3 instance.
 * @dev This script performs the following steps:
 *      1. Deploys a new Oracle contract with the new Uniswap V3 factory address
 *      2. Initializes all existing token pairs in the new Oracle
 *      3. Switches the Vault to use the new Oracle via SystemControl
 *
 * Prerequisites:
 *      - The system must NOT be in Unstoppable mode
 *      - The caller must be the owner of SystemControl
 *      - The new Uniswap V3 factory must have pools for all existing token pairs
 *
 * Usage:
 *      Set environment variables:
 *          export SYSTEM_CONTROL=<address>
 *          export NEW_UNISWAP_FACTORY=<address>
 *          export NEW_POOL_INIT_CODE_HASH=<bytes32>
 *
 *      For MegaETH testnet:
 *          forge script script/MigrateOracle.s.sol:MigrateOracle --rpc-url megatest --broadcast --ledger --hd-paths $HD_PATH
 *
 *      For dry-run (simulation):
 *          forge script script/MigrateOracle.s.sol:MigrateOracle --rpc-url megatest
 */
contract MigrateOracle is Script {
    function run() public {
        // Read addresses from environment
        address systemControlAddr = vm.envAddress("SYSTEM_CONTROL");
        address newUniswapFactory = vm.envAddress("NEW_UNISWAP_FACTORY");
        bytes32 newPoolInitCodeHash = vm.envBytes32("NEW_POOL_INIT_CODE_HASH");

        SystemControl systemControl = SystemControl(systemControlAddr);
        Vault vault = systemControl.vault();

        console.log("=== Oracle Migration Script ===");
        console.log("SystemControl:", systemControlAddr);
        console.log("Vault:", address(vault));
        console.log("New Uniswap V3 Factory:", newUniswapFactory);

        // Check system status
        SystemControl.SystemStatus status = systemControl.systemStatus();
        require(
            status != SystemControl.SystemStatus.Unstoppable,
            "Cannot migrate Oracle when system is in Unstoppable mode"
        );
        console.log("System status check passed (not Unstoppable)");

        // Get current Oracle for reference
        Oracle currentOracle = vault.ORACLE();
        console.log("Current Oracle:", address(currentOracle));

        // Get number of vaults
        uint48 numVaults = vault.numberOfVaults();
        console.log("Number of vaults to migrate:", numVaults);

        vm.startBroadcast();

        // Step 1: Deploy new Oracle
        console.log("\n--- Step 1: Deploying new Oracle ---");
        Oracle newOracle = new Oracle(newUniswapFactory, newPoolInitCodeHash);
        console.log("New Oracle deployed at:", address(newOracle));

        // Step 2: Initialize all token pairs in the new Oracle
        console.log("\n--- Step 2: Initializing token pairs ---");
        uint256 initializedCount = 0;
        uint256 failedCount = 0;

        for (uint48 vaultId = 1; vaultId <= numVaults; vaultId++) {
            SirStructs.VaultParameters memory params = vault.paramsById(vaultId);

            // Try to initialize the oracle for this pair
            // Note: initialize() is a no-op if already initialized for this pair
            try newOracle.initialize(params.debtToken, params.collateralToken) {
                initializedCount++;
                console.log(
                    "Initialized vault %d - debt: %s, collateral: %s",
                    vaultId,
                    params.debtToken,
                    params.collateralToken
                );
            } catch Error(string memory reason) {
                failedCount++;
                console.log("Failed to initialize vault %d - reason: %s", vaultId, reason);
            } catch {
                failedCount++;
                console.log("Failed to initialize vault %d - unknown error", vaultId);
            }
        }

        console.log("Initialization complete:");
        console.log("  - Successfully initialized: %d", initializedCount);
        console.log("  - Failed: %d", failedCount);

        // Abort if any initialization failed
        require(failedCount == 0, "Some token pairs failed to initialize. Aborting migration.");

        // Step 3: Switch to new Oracle
        console.log("\n--- Step 3: Switching to new Oracle ---");
        systemControl.setOracle(address(newOracle));
        console.log("Oracle switched successfully!");

        // Verify the switch
        Oracle verifyOracle = vault.ORACLE();
        require(address(verifyOracle) == address(newOracle), "Oracle switch verification failed");
        console.log("Verification passed: Vault now uses new Oracle");

        vm.stopBroadcast();

        console.log("\n=== Migration Complete ===");
        console.log("Old Oracle:", address(currentOracle));
        console.log("New Oracle:", address(newOracle));
    }
}

/**
 * @title MigrateOracleWithEmergency
 * @notice Same as MigrateOracle but enters Emergency mode during migration for extra safety.
 * @dev Use this version if you want to ensure no minting/burning happens during the migration.
 *
 * Usage:
 *      Set environment variables:
 *          export SYSTEM_CONTROL=<address>
 *          export NEW_UNISWAP_FACTORY=<address>
 *          export NEW_POOL_INIT_CODE_HASH=<bytes32>
 *
 *      For MegaETH testnet:
 *          forge script script/MigrateOracle.s.sol:MigrateOracleWithEmergency --rpc-url megatest --broadcast --ledger --hd-paths $HD_PATH
 */
contract MigrateOracleWithEmergency is Script {
    function run() public {
        // Read addresses from environment
        address systemControlAddr = vm.envAddress("SYSTEM_CONTROL");
        address newUniswapFactory = vm.envAddress("NEW_UNISWAP_FACTORY");
        bytes32 newPoolInitCodeHash = vm.envBytes32("NEW_POOL_INIT_CODE_HASH");

        SystemControl systemControl = SystemControl(systemControlAddr);
        Vault vault = systemControl.vault();

        console.log("=== Oracle Migration Script (with Emergency Mode) ===");
        console.log("SystemControl:", systemControlAddr);
        console.log("Vault:", address(vault));
        console.log("New Uniswap V3 Factory:", newUniswapFactory);

        // Check system status - must be in TrainingWheels
        SystemControl.SystemStatus status = systemControl.systemStatus();
        require(
            status == SystemControl.SystemStatus.TrainingWheels,
            "System must be in TrainingWheels mode to use this script"
        );
        console.log("System status check passed (TrainingWheels)");

        // Get current Oracle for reference
        Oracle currentOracle = vault.ORACLE();
        console.log("Current Oracle:", address(currentOracle));

        // Get number of vaults
        uint48 numVaults = vault.numberOfVaults();
        console.log("Number of vaults to migrate:", numVaults);

        vm.startBroadcast();

        // Step 1: Enter Emergency mode to halt minting
        console.log("\n--- Step 1: Entering Emergency mode ---");
        systemControl.haultMinting();
        console.log("Emergency mode activated - minting halted");

        // Step 2: Deploy new Oracle
        console.log("\n--- Step 2: Deploying new Oracle ---");
        Oracle newOracle = new Oracle(newUniswapFactory, newPoolInitCodeHash);
        console.log("New Oracle deployed at:", address(newOracle));

        // Step 3: Initialize all token pairs in the new Oracle
        console.log("\n--- Step 3: Initializing token pairs ---");
        uint256 initializedCount = 0;
        uint256 failedCount = 0;

        for (uint48 vaultId = 1; vaultId <= numVaults; vaultId++) {
            SirStructs.VaultParameters memory params = vault.paramsById(vaultId);

            try newOracle.initialize(params.debtToken, params.collateralToken) {
                initializedCount++;
                console.log(
                    "Initialized vault %d - debt: %s, collateral: %s",
                    vaultId,
                    params.debtToken,
                    params.collateralToken
                );
            } catch Error(string memory reason) {
                failedCount++;
                console.log("Failed to initialize vault %d - reason: %s", vaultId, reason);
            } catch {
                failedCount++;
                console.log("Failed to initialize vault %d - unknown error", vaultId);
            }
        }

        console.log("Initialization complete:");
        console.log("  - Successfully initialized: %d", initializedCount);
        console.log("  - Failed: %d", failedCount);

        // If any initialization failed, resume minting and abort
        if (failedCount > 0) {
            console.log("Some initializations failed. Resuming minting and aborting...");
            systemControl.resumeMinting();
            revert("Some token pairs failed to initialize. Migration aborted.");
        }

        // Step 4: Switch to new Oracle
        console.log("\n--- Step 4: Switching to new Oracle ---");
        systemControl.setOracle(address(newOracle));
        console.log("Oracle switched successfully!");

        // Step 5: Resume minting
        console.log("\n--- Step 5: Resuming minting ---");
        systemControl.resumeMinting();
        console.log("Minting resumed - back to TrainingWheels mode");

        // Verify the switch
        Oracle verifyOracle = vault.ORACLE();
        require(address(verifyOracle) == address(newOracle), "Oracle switch verification failed");
        console.log("Verification passed: Vault now uses new Oracle");

        vm.stopBroadcast();

        console.log("\n=== Migration Complete ===");
        console.log("Old Oracle:", address(currentOracle));
        console.log("New Oracle:", address(newOracle));
    }
}

/**
 * @title ValidateOracleMigration
 * @notice Dry-run script to validate that a new Oracle can be initialized for all existing vaults.
 * @dev Use this to check if migration will succeed before actually doing it.
 *
 * Usage:
 *      Set environment variables:
 *          export VAULT=<address>
 *          export NEW_UNISWAP_FACTORY=<address>
 *          export NEW_POOL_INIT_CODE_HASH=<bytes32>
 *
 *      For MegaETH testnet:
 *          forge script script/MigrateOracle.s.sol:ValidateOracleMigration --rpc-url megatest
 */
contract ValidateOracleMigration is Script {
    function run() public {
        // Read addresses from environment
        address vaultAddr = vm.envAddress("VAULT");
        address newUniswapFactory = vm.envAddress("NEW_UNISWAP_FACTORY");
        bytes32 newPoolInitCodeHash = vm.envBytes32("NEW_POOL_INIT_CODE_HASH");

        Vault vault = Vault(vaultAddr);

        console.log("=== Oracle Migration Validation ===");
        console.log("Vault:", vaultAddr);
        console.log("New Uniswap V3 Factory:", newUniswapFactory);

        // Get current Oracle for reference
        Oracle currentOracle = vault.ORACLE();
        console.log("Current Oracle:", address(currentOracle));

        // Get number of vaults
        uint48 numVaults = vault.numberOfVaults();
        console.log("Number of vaults to check:", numVaults);

        // Deploy new Oracle in simulation
        vm.startBroadcast();
        Oracle newOracle = new Oracle(newUniswapFactory, newPoolInitCodeHash);
        console.log("Test Oracle deployed at:", address(newOracle));
        vm.stopBroadcast();

        // Check all token pairs
        console.log("\n--- Checking token pairs ---");
        uint256 successCount = 0;
        uint256 failCount = 0;

        for (uint48 vaultId = 1; vaultId <= numVaults; vaultId++) {
            SirStructs.VaultParameters memory params = vault.paramsById(vaultId);

            if (params.debtToken == address(0) || params.collateralToken == address(0)) {
                console.log("Vault %d - SKIP (invalid tokens)", vaultId);
                continue;
            }

            // Check if Uniswap pool exists by trying to get oracle state
            // We use a static call to avoid state changes
            try newOracle.initialize(params.debtToken, params.collateralToken) {
                successCount++;
                console.log("Vault %d - OK", vaultId);
            } catch Error(string memory reason) {
                failCount++;
                console.log("Vault %d - FAIL: %s", vaultId, reason);
            } catch {
                failCount++;
                console.log("Vault %d - FAIL: unknown error", vaultId);
            }
        }

        console.log("=== Validation Summary ===");
        console.log("Vaults that will succeed: %d", successCount);
        console.log("Vaults that will fail: %d", failCount);

        if (failCount > 0) {
            console.log("\nWARNING: Migration will fail for some vaults!");
            console.log("Ensure the new Uniswap V3 instance has liquidity pools for all token pairs.");
        } else {
            console.log("\nAll vaults can be migrated successfully.");
        }
    }
}
