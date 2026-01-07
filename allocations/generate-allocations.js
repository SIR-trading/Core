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
    sir: 76000, // $66k TVL for SIR on Ethereum
    hyperSir: 12000 // $10k TVL for HyperSIR on HyperEVM
};

// Total TVL for weighted average calculation
const TOTAL_TVL = TVL_WEIGHTS.sir + TVL_WEIGHTS.hyperSir;

// Allocation percentages (out of 100% total issuance)
const LP_ALLOCATION = 69; // % to LPers (not in this contract, handled separately)
// Remaining 30% goes to contributors based on their SIR/HyperSIR holdings

// High precision for percentage calculations (18 decimals)
const PRECISION = BigInt(10) ** BigInt(18);

// =============================================================================
// LOAD DATA FILES
// =============================================================================

const ethereumSnapshot = require("./ethereum-snapshot.json");
const hyperevmSnapshot = require("./hyperevm-snapshot.json");
const megaethContributors = require("./megaeth-contributors.json");

// =============================================================================
// ALLOCATIONS GENERATOR
// =============================================================================

const MAX_UINT16 = (1n << 16n) - 1n; // 65,535

class AllocationsGenerator {
    constructor() {
        // Maps MegaETH address -> allocation amount (BigInt)
        this.allocations = new Map();

        // Maps MegaETH address -> breakdown of sources
        this.allocationBreakdowns = new Map();

        // Maps MegaETH address -> source data for debugging/auditing
        this.sources = new Map();

        // Track user percentages from each chain (as BigInt with 18 decimals precision)
        // percentage * PRECISION (e.g., 2.5% = 2.5 * 10^18)
        this.userEthereumPercentages = new Map();
        this.userHyperEVMPercentages = new Map();

        // Track final weighted percentages
        this.userWeightedPercentages = new Map();

        // Fixed contributors from megaeth-contributors.json
        // These get fixed allocations in basis points of total issuance (not contributor pool)
        // Map: address (lowercase) -> { allocationInBasisPoints, ... }
        this.fixedContributors = new Map();
        for (const contributor of megaethContributors) {
            this.fixedContributors.set(contributor.address.toLowerCase(), contributor);
        }
    }

    /**
     * Parse percentage string to BigInt with 18 decimals precision
     * Input: "2.5" (meaning 2.5%)
     * Output: 2500000000000000000n (2.5 * 10^18)
     */
    parsePercentageToBigInt(percentageStr) {
        if (!percentageStr || percentageStr === "0") return 0n;
        // Parse the percentage string to BigInt with 18 decimals
        return ethers.parseUnits(percentageStr, 18);
    }

    /**
     * Process Ethereum snapshot - SIR holders
     * Uses the pre-calculated percentage field from the snapshot
     * Treasury on Ethereum gets treated as a regular user
     * Skips fixed contributors (they get fixed allocations instead)
     */
    processEthereumSnapshot() {
        console.log("Processing Ethereum snapshot (SIR holders)...");

        const balances = ethereumSnapshot.balances;
        let holderCount = 0;
        let skippedFixedContributors = 0;

        for (const [address, balanceData] of Object.entries(balances)) {
            // Use the percentage field from the snapshot
            const percentageStr = balanceData.percentage;
            if (!percentageStr || percentageStr === "0") continue;

            const percentage = this.parsePercentageToBigInt(percentageStr);
            if (percentage === 0n) continue;

            // Determine MegaETH address:
            // - If this is the Ethereum treasury, map to MegaETH treasury
            // - Otherwise, use same address (assumes same keys across chains)
            let megaethAddress = address;
            if (address.toLowerCase() === TREASURY.ethereum.toLowerCase()) {
                megaethAddress = TREASURY.megaeth;
            }

            // Skip fixed contributors - they get fixed allocations
            if (this.fixedContributors.has(megaethAddress.toLowerCase())) {
                skippedFixedContributors++;
                continue;
            }

            // Store the Ethereum percentage for this address
            const existing = this.userEthereumPercentages.get(megaethAddress) || 0n;
            this.userEthereumPercentages.set(megaethAddress, existing + percentage);

            // Store source data with full breakdown
            const sources = this.sources.get(megaethAddress) || {};
            sources.ethereum = {
                originalAddress: address,
                percentage: percentageStr,
                totalSIR: balanceData.totalSIR,
                breakdown: {
                    sirBalance: balanceData.sirBalance,
                    stakedSIR: balanceData.stakedSIR,
                    vaultEquity: balanceData.vaultEquity,
                    unclaimedLperRewards: balanceData.unclaimedLperRewards,
                    unclaimedContributorRewards: balanceData.unclaimedContributorRewards,
                    unissuedContributorRewards: balanceData.unissuedContributorRewards,
                    uniswapV3Equity: balanceData.uniswapV3Equity,
                    uniswapV3UnclaimedFees: balanceData.uniswapV3UnclaimedFees,
                    uniswapV3StakingRewards: balanceData.uniswapV3StakingRewards
                }
            };
            this.sources.set(megaethAddress, sources);

            holderCount++;
        }

        console.log(`  Holders with percentage: ${holderCount}`);
        console.log(`  Skipped fixed contributors: ${skippedFixedContributors}`);
        console.log(`  Unique MegaETH addresses: ${this.userEthereumPercentages.size}`);
    }

    /**
     * Process HyperEVM snapshot - HyperSIR holders
     * Uses the pre-calculated percentage field from the snapshot
     * Treasury on HyperEVM gets treated as a regular user
     * Skips fixed contributors (they get fixed allocations instead)
     */
    processHyperEVMSnapshot() {
        console.log("\nProcessing HyperEVM snapshot (HyperSIR holders)...");

        if (!hyperevmSnapshot) {
            console.log("  [SKIPPED] hyperevm-snapshot.json not found");
            console.log("  Run: node hyperevm-balance-snapshot.js to generate it");
            return;
        }

        const balances = hyperevmSnapshot.balances;
        let holderCount = 0;
        let skippedFixedContributors = 0;

        for (const [address, balanceData] of Object.entries(balances)) {
            // Use the percentage field from the snapshot
            const percentageStr = balanceData.percentage;
            if (!percentageStr || percentageStr === "0") continue;

            const percentage = this.parsePercentageToBigInt(percentageStr);
            if (percentage === 0n) continue;

            // Determine MegaETH address:
            // - If this is the HyperEVM treasury, map to MegaETH treasury
            // - Otherwise, use same address (assumes same keys across chains)
            let megaethAddress = address;
            if (address.toLowerCase() === TREASURY.hyperevm.toLowerCase()) {
                megaethAddress = TREASURY.megaeth;
            }

            // Skip fixed contributors - they get fixed allocations
            if (this.fixedContributors.has(megaethAddress.toLowerCase())) {
                skippedFixedContributors++;
                continue;
            }

            // Store the HyperEVM percentage for this address
            const existing = this.userHyperEVMPercentages.get(megaethAddress) || 0n;
            this.userHyperEVMPercentages.set(megaethAddress, existing + percentage);

            // Store source data with full breakdown
            const sources = this.sources.get(megaethAddress) || {};
            sources.hyperevm = {
                originalAddress: address,
                percentage: percentageStr,
                totalSIR: balanceData.totalSIR,
                breakdown: {
                    sirBalance: balanceData.sirBalance,
                    stakedSIR: balanceData.stakedSIR,
                    vaultEquity: balanceData.vaultEquity,
                    unclaimedLperRewards: balanceData.unclaimedLperRewards,
                    unclaimedContributorRewards: balanceData.unclaimedContributorRewards,
                    unissuedContributorRewards: balanceData.unissuedContributorRewards,
                    uniswapV3Equity: balanceData.uniswapV3Equity,
                    uniswapV3UnclaimedFees: balanceData.uniswapV3UnclaimedFees,
                    uniswapV3StakingRewards: balanceData.uniswapV3StakingRewards
                }
            };
            this.sources.set(megaethAddress, sources);

            holderCount++;
        }

        console.log(`  Holders with percentage: ${holderCount}`);
        console.log(`  Skipped fixed contributors: ${skippedFixedContributors}`);
        console.log(`  Unique MegaETH addresses: ${this.userHyperEVMPercentages.size}`);
    }

    /**
     * Calculate final allocations based on TVL-weighted percentages
     * Formula: megaeth_percentage = (eth_percentage * TVL_SIR + hyper_percentage * TVL_HYPERSIR) / TOTAL_TVL
     *
     * Fixed contributors get their allocation in basis points of TOTAL issuance (not contributor pool).
     * Since MAX_UINT16 represents 100% of contributor pool (30% of total issuance):
     * - 1 basis point of total = 0.01% of total = (0.01/30)% of contributor pool
     * - Fixed allocation = basisPoints * MAX_UINT16 / 3000
     *
     * Remaining allocation goes to weighted holders.
     */
    calculateFinalAllocations() {
        console.log("\nCalculating final allocations...");
        console.log(`  TVL weights: SIR=${TVL_WEIGHTS.sir}, HyperSIR=${TVL_WEIGHTS.hyperSir}, Total=${TOTAL_TVL}`);

        // Step 1: Allocate fixed contributors first
        console.log("\n  Fixed contributors (basis points of total issuance):");
        let fixedAllocationTotal = 0n;

        for (const [addressLower, contributor] of this.fixedContributors) {
            // basis points of total -> allocation in MAX_UINT16
            // MAX_UINT16 = 30% of total, so basisPoints/10000 of total = basisPoints/10000 * (MAX_UINT16/0.3)
            // = basisPoints * MAX_UINT16 / 3000
            const basisPoints = BigInt(contributor.allocationInBasisPoints);
            const allocation = (basisPoints * MAX_UINT16) / 3000n;

            // Use the original address casing from the JSON
            const address = contributor.address;
            this.allocations.set(address, allocation);
            fixedAllocationTotal += allocation;

            // Store breakdown for fixed contributors
            const percentOfTotal = Number(basisPoints) / 100;
            const percentOfContributorPool = Number(basisPoints) / 30;
            this.allocationBreakdowns.set(address, {
                type: "fixed",
                basisPointsOfTotal: contributor.allocationInBasisPoints,
                percentOfTotalIssuance: `${percentOfTotal}%`,
                percentOfContributorPool: `${percentOfContributorPool.toFixed(2)}%`
            });

            console.log(
                `    ${address}: ${contributor.allocationInBasisPoints} bp (${percentOfTotal}% of total) -> ${allocation}`
            );
        }

        const remainingAllocation = MAX_UINT16 - fixedAllocationTotal;
        console.log(`\n  Fixed contributors total: ${fixedAllocationTotal}`);
        console.log(`  Remaining for weighted holders: ${remainingAllocation}`);

        // Step 2: Get all unique addresses from both chains (excluding fixed contributors)
        const allAddresses = new Set([...this.userEthereumPercentages.keys(), ...this.userHyperEVMPercentages.keys()]);

        console.log(`  Total unique weighted addresses: ${allAddresses.size}`);

        // Step 3: Calculate TVL-weighted percentage for each address
        let totalWeightedPercentage = 0n;

        for (const address of allAddresses) {
            const ethPercentage = this.userEthereumPercentages.get(address) || 0n;
            const hyperPercentage = this.userHyperEVMPercentages.get(address) || 0n;

            // Calculate weighted percentage: (eth% * tvl_sir + hyper% * tvl_hypersir) / total_tvl
            // All percentages are already scaled by PRECISION (10^18)
            const weightedPercentage =
                (ethPercentage * BigInt(TVL_WEIGHTS.sir) + hyperPercentage * BigInt(TVL_WEIGHTS.hyperSir)) /
                BigInt(TOTAL_TVL);

            if (weightedPercentage > 0n) {
                this.userWeightedPercentages.set(address, weightedPercentage);
                totalWeightedPercentage += weightedPercentage;

                // Store breakdown
                this.allocationBreakdowns.set(address, {
                    type: "weighted",
                    ethereumPercentage: ethers.formatUnits(ethPercentage, 18),
                    hyperEVMPercentage: ethers.formatUnits(hyperPercentage, 18),
                    weightedPercentage: ethers.formatUnits(weightedPercentage, 18)
                });
            }
        }

        console.log(`  Total weighted percentage: ${ethers.formatUnits(totalWeightedPercentage, 18)}%`);

        // Step 4: Distribute remaining allocation proportionally based on weighted percentages
        let allocatedSoFar = fixedAllocationTotal;
        const sortedUsers = Array.from(this.userWeightedPercentages.entries()).sort((a, b) =>
            b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : 0
        );

        for (let i = 0; i < sortedUsers.length; i++) {
            const [address, weightedPercentage] = sortedUsers[i];

            let allocation;
            if (i === sortedUsers.length - 1) {
                // Last user gets remainder to ensure exact sum
                allocation = MAX_UINT16 - allocatedSoFar;
            } else {
                // Proportional share of the remaining allocation
                allocation = (weightedPercentage * remainingAllocation) / totalWeightedPercentage;
            }

            if (allocation > 0n) {
                this.allocations.set(address, allocation);
                allocatedSoFar += allocation;
            }
        }

        console.log(`  Total addresses with allocation: ${this.allocations.size}`);
        console.log(`    - Fixed contributors: ${this.fixedContributors.size}`);
        console.log(`    - Weighted holders: ${this.userWeightedPercentages.size}`);
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

        // Calculate fixed contributors total basis points
        let fixedBasisPointsTotal = 0;
        for (const contributor of megaethContributors) {
            fixedBasisPointsTotal += contributor.allocationInBasisPoints;
        }

        // Create metadata
        const metadata = {
            generatedAt: new Date().toISOString(),
            maxUint16: MAX_UINT16.toString(),
            totalAddresses: this.allocations.size,
            lpAllocationPercent: LP_ALLOCATION,
            contributorAllocationPercent: 100 - LP_ALLOCATION,
            fixedContributors: {
                count: megaethContributors.length,
                totalBasisPoints: fixedBasisPointsTotal,
                percentOfTotalIssuance: `${fixedBasisPointsTotal / 100}%`,
                source: "megaeth-contributors.json"
            },
            weightedHolders: {
                count: this.userWeightedPercentages.size,
                remainingPercent: `${100 - LP_ALLOCATION - fixedBasisPointsTotal / 100}%`
            },
            tvlWeights: TVL_WEIGHTS,
            totalTVL: TOTAL_TVL,
            treasury: TREASURY,
            sources: {
                ethereumSnapshot: "ethereum-snapshot.json",
                hyperevmSnapshot: hyperevmSnapshot ? "hyperevm-snapshot.json" : null,
                megaethContributors: "megaeth-contributors.json"
            },
            formula: "(eth_percentage * TVL_SIR + hyper_percentage * TVL_HYPERSIR) / TOTAL_TVL"
        };

        // Create allocations object
        const allocationsObj = {};
        for (const [address, allocation] of sortedAllocations) {
            // Calculate percentage of contributor pool (30% of total)
            const CALC_PRECISION = 1000000000000000n;
            const partsPerQuadrillion = (allocation * 30n * CALC_PRECISION) / MAX_UINT16;
            const percentOfTotalIssuance = Number(partsPerQuadrillion) / Number(CALC_PRECISION);

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

            // Build allocation entry based on type
            if (breakdown.type === "fixed") {
                allocationsObj[address] = {
                    allocation: allocation.toString(),
                    allocationPerc: allocationPerc,
                    type: "fixed",
                    basisPointsOfTotal: breakdown.basisPointsOfTotal,
                    percentOfTotalIssuance: breakdown.percentOfTotalIssuance,
                    percentOfContributorPool: breakdown.percentOfContributorPool
                };
            } else {
                allocationsObj[address] = {
                    allocation: allocation.toString(),
                    allocationPerc: allocationPerc,
                    type: "weighted",
                    sources: sources,
                    percentageBreakdown: {
                        ethereumPercentage: breakdown.ethereumPercentage || "0",
                        hyperEVMPercentage: breakdown.hyperEVMPercentage || "0",
                        weightedPercentage: breakdown.weightedPercentage || "0"
                    }
                };
            }
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
     * Verify the allocations sum to MAX_UINT16
     */
    verify() {
        let sum = 0n;
        for (const allocation of this.allocations.values()) {
            sum += allocation;
        }

        console.log("\n=== Verification ===");
        console.log(`  Sum of allocations: ${sum}`);
        console.log(`  type(uint16).max:   ${MAX_UINT16}`);
        console.log(`  Match: ${sum === MAX_UINT16 ? "✓" : "✗"}`);

        if (sum !== MAX_UINT16) {
            console.error(`ERROR: Allocations do not sum to type(uint16).max!`);
            console.error(`Difference: ${MAX_UINT16 - sum}`);
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

        // Calculate fixed contributors total
        let fixedBasisPointsTotal = 0;
        for (const contributor of megaethContributors) {
            fixedBasisPointsTotal += contributor.allocationInBasisPoints;
        }
        console.log(`\nFixed Contributors (from megaeth-contributors.json):`);
        console.log(`  Count: ${megaethContributors.length}`);
        console.log(
            `  Total: ${fixedBasisPointsTotal} basis points (${fixedBasisPointsTotal / 100}% of total issuance)`
        );
        console.log(
            `  Remaining for weighted holders: ${100 - LP_ALLOCATION - fixedBasisPointsTotal / 100}% of total issuance`
        );
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
        console.log(`  Ethereum holders: ${this.userEthereumPercentages.size}`);
        console.log(`  HyperEVM holders: ${this.userHyperEVMPercentages.size}`);
        console.log(`  Combined unique addresses: ${this.userWeightedPercentages.size}`);

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
