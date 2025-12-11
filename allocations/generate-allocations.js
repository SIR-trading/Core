const ethers = require("ethers");
const fs = require("fs");
const path = require("path");

// =============================================================================
// CONFIGURATION
// =============================================================================

// Treasury addresses per chain (same owner, different addresses)
const TREASURY = {
    ethereum: "0x686748764c5C7Aa06FEc784E60D14b650bF79129",
    hyperevm: "0x5f84c79389a4d44A38a3bF81f9B8c1179e615cc8",
    megaeth: "0xbFb4D49C01dc40C53372D68d5F979a89811d8d6C"
};

// TVL weights for computing allocations (in USD)
// These determine how much weight each chain's holdings get
const TVL_WEIGHTS = {
    sir: 80100, // $80.1k TVL for SIR on Ethereum
    hyperSir: 18200 // $18.2k TVL for HyperSIR on HyperEVM
};

// Allocation percentages (out of 100% total issuance)
const LP_ALLOCATION = 70; // 70% to LPers (not in this contract, handled separately)
// Remaining 30% goes to contributors based on their SIR/HyperSIR holdings

// =============================================================================
// LOAD DATA FILES
// =============================================================================

const ethereumSnapshot = require("./ethereum-snapshot.json");

// Load HyperEVM snapshot if it exists
let hyperevmSnapshot = null;
try {
    hyperevmSnapshot = require("./hyperevm-snapshot.json");
} catch (e) {
    // File doesn't exist yet - will be skipped in processing
}

// =============================================================================
// ALLOCATIONS GENERATOR
// =============================================================================

const MAX_UINT24 = (1n << 24n) - 1n; // 16,777,215

class AllocationsGenerator {
    constructor() {
        // Maps MegaETH address -> allocation amount (BigInt)
        this.allocations = new Map();

        // Maps MegaETH address -> breakdown of sources
        this.allocationBreakdowns = new Map();

        // Maps MegaETH address -> source data for debugging/auditing
        this.sources = new Map();

        // Totals for weighting
        this.totalWeightedValue = 0n;

        // Track user weighted values before final allocation calculation
        this.userWeightedValues = new Map();
    }

    /**
     * Calculate total SIR value for a user from Ethereum snapshot
     */
    calculateUserTotalSIR(balanceData) {
        let total = 0n;

        // 1. SIR balance
        if (balanceData.sirBalance) {
            total += BigInt(balanceData.sirBalance);
        }

        // 2. Staked SIR
        if (balanceData.stakedSIR) {
            total += BigInt(balanceData.stakedSIR.unlockedStake || 0);
            total += BigInt(balanceData.stakedSIR.lockedStake || 0);
        }

        // 3. Vault equity (sum across all vaults)
        if (balanceData.vaultEquity) {
            for (const vaultId in balanceData.vaultEquity) {
                const vault = balanceData.vaultEquity[vaultId];
                total += BigInt(vault.teaEquitySIR || 0);
                total += BigInt(vault.apeEquitySIR || 0);
            }
        }

        // 4. Unclaimed LP rewards
        if (balanceData.unclaimedLperRewards) {
            total += BigInt(balanceData.unclaimedLperRewards);
        }

        // 5. Unclaimed contributor rewards
        if (balanceData.unclaimedContributorRewards) {
            total += BigInt(balanceData.unclaimedContributorRewards);
        }

        // 6. Unissued contributor rewards
        if (balanceData.unissuedContributorRewards) {
            total += BigInt(balanceData.unissuedContributorRewards);
        }

        // 7. Uniswap V3 equity
        if (balanceData.uniswapV3Equity) {
            total += BigInt(balanceData.uniswapV3Equity);
        }

        // 8. Uniswap V3 unclaimed fees
        if (balanceData.uniswapV3UnclaimedFees) {
            total += BigInt(balanceData.uniswapV3UnclaimedFees);
        }

        // 9. Uniswap V3 staking rewards
        if (balanceData.uniswapV3StakingRewards) {
            total += BigInt(balanceData.uniswapV3StakingRewards);
        }

        return total;
    }

    /**
     * Process Ethereum snapshot - SIR holders
     * Treasury on Ethereum gets treated as a regular user
     */
    processEthereumSnapshot() {
        console.log("Processing Ethereum snapshot (SIR holders)...");

        const balances = ethereumSnapshot.balances;
        let totalSIR = 0n;

        for (const [address, balanceData] of Object.entries(balances)) {
            const userSIR = this.calculateUserTotalSIR(balanceData);

            if (userSIR > 0n) {
                // Apply TVL weight
                const weightedValue = (userSIR * BigInt(Math.floor(TVL_WEIGHTS.sir * 1e18))) / BigInt(1e18);

                // Determine MegaETH address:
                // - If this is the Ethereum treasury, map to MegaETH treasury
                // - Otherwise, use same address (assumes same keys across chains)
                let megaethAddress = address;
                if (address.toLowerCase() === TREASURY.ethereum.toLowerCase()) {
                    megaethAddress = TREASURY.megaeth;
                }

                // Add to user's weighted value
                const existing = this.userWeightedValues.get(megaethAddress) || 0n;
                this.userWeightedValues.set(megaethAddress, existing + weightedValue);

                // Store source data
                const sources = this.sources.get(megaethAddress) || {};
                sources.ethereum = {
                    originalAddress: address,
                    sirBalance: userSIR.toString(),
                    weightedValue: weightedValue.toString()
                };
                this.sources.set(megaethAddress, sources);

                // Store breakdown
                const breakdown = this.allocationBreakdowns.get(megaethAddress) || {
                    fromEthereumSIR: 0n,
                    fromHyperEVMSIR: 0n
                };
                breakdown.fromEthereumSIR = weightedValue;
                this.allocationBreakdowns.set(megaethAddress, breakdown);

                totalSIR += userSIR;
            }
        }

        this.totalSIR = totalSIR;
        console.log(`  Total SIR: ${ethers.formatUnits(totalSIR, 12)} SIR`);
        console.log(`  Unique holders: ${this.userWeightedValues.size}`);
    }

    /**
     * Process HyperEVM snapshot - HyperSIR holders
     * Treasury on HyperEVM gets treated as a regular user
     */
    processHyperEVMSnapshot() {
        console.log("\nProcessing HyperEVM snapshot (HyperSIR holders)...");

        if (!hyperevmSnapshot) {
            console.log("  [SKIPPED] hyperevm-snapshot.json not found");
            console.log("  Run: node hyperevm-balance-snapshot.js to generate it");
            return;
        }

        const balances = hyperevmSnapshot.balances;
        let totalHyperSIR = 0n;

        for (const [address, balanceData] of Object.entries(balances)) {
            const userHyperSIR = this.calculateUserTotalSIR(balanceData);

            if (userHyperSIR > 0n) {
                // Apply TVL weight for HyperSIR
                const weightedValue = (userHyperSIR * BigInt(Math.floor(TVL_WEIGHTS.hyperSir * 1e18))) / BigInt(1e18);

                // Determine MegaETH address:
                // - If this is the HyperEVM treasury, map to MegaETH treasury
                // - Otherwise, use same address (assumes same keys across chains)
                let megaethAddress = address;
                if (address.toLowerCase() === TREASURY.hyperevm.toLowerCase()) {
                    megaethAddress = TREASURY.megaeth;
                }

                // Add to user's weighted value
                const existing = this.userWeightedValues.get(megaethAddress) || 0n;
                this.userWeightedValues.set(megaethAddress, existing + weightedValue);

                // Store source data
                const sources = this.sources.get(megaethAddress) || {};
                sources.hyperevm = {
                    originalAddress: address,
                    hyperSirBalance: userHyperSIR.toString(),
                    weightedValue: weightedValue.toString()
                };
                this.sources.set(megaethAddress, sources);

                // Store breakdown
                const breakdown = this.allocationBreakdowns.get(megaethAddress) || {
                    fromEthereumSIR: 0n,
                    fromHyperEVMSIR: 0n
                };
                breakdown.fromHyperEVMSIR = weightedValue;
                this.allocationBreakdowns.set(megaethAddress, breakdown);

                totalHyperSIR += userHyperSIR;
            }
        }

        this.totalHyperSIR = totalHyperSIR;
        console.log(`  Total HyperSIR: ${ethers.formatUnits(totalHyperSIR, 12)} HyperSIR`);
        console.log(`  Unique holders: ${Object.keys(balances).length}`);
    }

    /**
     * Calculate final allocations based on weighted values
     * Distributes MAX_UINT24 proportionally to all users based on their weighted value
     */
    calculateFinalAllocations() {
        console.log("\nCalculating final allocations...");

        // Calculate total weighted value across all users
        let totalWeighted = 0n;
        for (const value of this.userWeightedValues.values()) {
            totalWeighted += value;
        }
        this.totalWeightedValue = totalWeighted;

        console.log(`  Total weighted value: ${ethers.formatUnits(totalWeighted, 18)}`);

        // Distribute MAX_UINT24 proportionally
        let allocatedSoFar = 0n;
        const sortedUsers = Array.from(this.userWeightedValues.entries()).sort((a, b) =>
            b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : 0
        );

        for (let i = 0; i < sortedUsers.length; i++) {
            const [address, weightedValue] = sortedUsers[i];

            let allocation;
            if (i === sortedUsers.length - 1) {
                // Last user gets remainder to ensure exact sum
                allocation = MAX_UINT24 - allocatedSoFar;
            } else {
                allocation = (weightedValue * MAX_UINT24) / totalWeighted;
            }

            if (allocation > 0n) {
                this.allocations.set(address, allocation);
                allocatedSoFar += allocation;
            }
        }

        console.log(`  Addresses with allocation: ${this.allocations.size}`);
    }

    /**
     * Generate the final JSON output
     */
    generateJSON() {
        console.log("\nGenerating allocations JSON...");

        // Filter out zero allocations
        let discardedCount = 0;
        for (const [address, allocation] of this.allocations.entries()) {
            if (allocation === 0n) {
                this.allocations.delete(address);
                this.allocationBreakdowns.delete(address);
                this.sources.delete(address);
                discardedCount++;
            }
        }
        if (discardedCount > 0) {
            console.log(`  Discarded ${discardedCount} addresses with 0 allocation`);
        }

        // Sort by allocation descending
        const sortedAllocations = Array.from(this.allocations.entries()).sort((a, b) =>
            b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : 0
        );

        // Create metadata
        const metadata = {
            generatedAt: new Date().toISOString(),
            maxUint24: MAX_UINT24.toString(),
            totalAddresses: this.allocations.size,
            lpAllocationPercent: LP_ALLOCATION,
            contributorAllocationPercent: 100 - LP_ALLOCATION,
            tvlWeights: TVL_WEIGHTS,
            treasury: TREASURY,
            sources: {
                ethereumSnapshot: "ethereum-snapshot.json",
                hyperevmSnapshot: hyperevmSnapshot ? "hyperevm-snapshot.json" : null
            },
            rpcEndpoints: {
                ethereum: "standard Ethereum RPC",
                hyperevm: "https://hyperliquid-mainnet.g.alchemy.com/v2/{KEY}"
            },
            snapshotBlocks: {
                hyperevm: 22931060 // START_BLOCK for HyperSIR snapshot
            }
        };

        // Create allocations object
        const allocationsObj = {};
        for (const [address, allocation] of sortedAllocations) {
            // Calculate percentage of contributor pool (30% of total)
            const PRECISION = 1000000000000000n;
            const partsPerQuadrillion = (allocation * 30n * PRECISION) / MAX_UINT24;
            const percentOfTotalIssuance = Number(partsPerQuadrillion) / Number(PRECISION);

            // Format percentage string
            let allocationPerc;
            if (percentOfTotalIssuance === 0) {
                allocationPerc = "0.0%";
            } else {
                const sigFigs = Number(percentOfTotalIssuance.toPrecision(2));
                if (sigFigs >= 1) {
                    allocationPerc = `${sigFigs.toFixed(1)}%`;
                } else if (sigFigs >= 0.1) {
                    allocationPerc = `${sigFigs.toFixed(2)}%`;
                } else if (sigFigs >= 0.01) {
                    allocationPerc = `${sigFigs.toFixed(3)}%`;
                } else if (sigFigs >= 0.001) {
                    allocationPerc = `${sigFigs.toFixed(4)}%`;
                } else if (sigFigs >= 0.0001) {
                    allocationPerc = `${sigFigs.toFixed(5)}%`;
                } else {
                    allocationPerc = `${sigFigs.toFixed(6)}%`;
                }
            }

            // Get breakdown and sources
            const breakdown = this.allocationBreakdowns.get(address) || {};
            const sources = this.sources.get(address) || {};

            allocationsObj[address] = {
                allocation: allocation.toString(),
                allocationPerc: allocationPerc,
                sources: sources,
                allocationBreakdown: {
                    fromEthereumSIR: (breakdown.fromEthereumSIR || 0n).toString(),
                    fromHyperEVMSIR: (breakdown.fromHyperEVMSIR || 0n).toString()
                }
            };
        }

        return {
            metadata: metadata,
            allocations: allocationsObj
        };
    }

    /**
     * Generate compact JSON for Foundry deployment
     * Uses parallel arrays for efficient parsing with parseJsonAddressArray/parseJsonUintArray
     */
    generateDeploymentJSON() {
        const sortedAllocations = Array.from(this.allocations.entries()).sort((a, b) =>
            b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : 0
        );

        const addresses = [];
        const amounts = [];

        for (const [address, allocation] of sortedAllocations) {
            if (allocation > 0n) {
                addresses.push(address);
                amounts.push(Number(allocation));
            }
        }

        return {
            addresses: addresses,
            amounts: amounts
        };
    }

    /**
     * Verify the allocations sum to MAX_UINT24
     */
    verify() {
        let sum = 0n;
        for (const allocation of this.allocations.values()) {
            sum += allocation;
        }

        console.log("\n=== Verification ===");
        console.log(`  Sum of allocations: ${sum}`);
        console.log(`  type(uint24).max:   ${MAX_UINT24}`);
        console.log(`  Match: ${sum === MAX_UINT24 ? "✓" : "✗"}`);

        if (sum !== MAX_UINT24) {
            console.error(`ERROR: Allocations do not sum to type(uint24).max!`);
            console.error(`Difference: ${MAX_UINT24 - sum}`);
            return false;
        }
        return true;
    }

    /**
     * Main execution
     */
    async execute() {
        console.log("=== MegaETH Allocations Generator ===\n");
        console.log("Treasury Addresses:");
        console.log(`  Ethereum: ${TREASURY.ethereum}`);
        console.log(`  HyperEVM: ${TREASURY.hyperevm}`);
        console.log(`  MegaETH:  ${TREASURY.megaeth}`);
        console.log(`\nTVL Weights:`);
        console.log(`  SIR (Ethereum): ${TVL_WEIGHTS.sir}`);
        console.log(`  HyperSIR (HyperEVM): ${TVL_WEIGHTS.hyperSir}`);
        console.log(`\nAllocation Split:`);
        console.log(`  LP: ${LP_ALLOCATION}%`);
        console.log(`  Contributors: ${100 - LP_ALLOCATION}%`);
        console.log("\n" + "=".repeat(50) + "\n");

        // Process all sources
        this.processEthereumSnapshot();
        this.processHyperEVMSnapshot();

        // Calculate final allocations
        this.calculateFinalAllocations();

        // Generate and save detailed JSON (for auditing/debugging)
        const allocationsJSON = this.generateJSON();
        const outputPath = path.join(__dirname, "allocations.json");
        fs.writeFileSync(outputPath, JSON.stringify(allocationsJSON, null, 2));
        console.log(`\nGenerated: ${outputPath}`);

        // Generate compact deployment JSON (for Foundry)
        const deploymentJSON = this.generateDeploymentJSON();
        const deploymentPath = path.join(__dirname, "allocations-deploy.json");
        fs.writeFileSync(deploymentPath, JSON.stringify(deploymentJSON));
        console.log(`Generated: ${deploymentPath}`);

        // Print summary
        console.log("\n=== Summary ===");
        console.log(`  Total addresses: ${this.allocations.size}`);
        if (this.totalSIR) {
            console.log(`  Total SIR processed: ${ethers.formatUnits(this.totalSIR, 12)} SIR`);
        }
        if (this.totalHyperSIR) {
            console.log(`  Total HyperSIR processed: ${ethers.formatUnits(this.totalHyperSIR, 12)} HyperSIR`);
        }

        // Verify
        this.verify();
    }
}

// =============================================================================
// MAIN
// =============================================================================

async function main() {
    const generator = new AllocationsGenerator();
    await generator.execute();
}

main().catch((error) => {
    console.error("Error:", error);
    process.exit(1);
});
