const ethers = require("ethers");
const fs = require("fs");
const path = require("path");

// Configuration
const OLD_TREASURY = "0x686748764c5C7Aa06FEc784E60D14b650bF79129";
const NEW_TREASURY = "0x5f84c79389a4d44A38a3bF81f9B8c1179e615cc8";

// Allocation percentages (out of 100%)
const LP_ALLOCATION = 70; // 70% to LPers (not in this contract)
const SIR_HOLDER_ALLOCATION = 25; // 25% to SIR holders
const HYPURR_HOLDER_ALLOCATION = 1; // 1% to Hypurr holders
// Additional allocations from hyperevm-contributors.json (in basis points)
// Remainder goes to treasury

// Load snapshot files
const ethereumSnapshot = require("./ethereum-snapshot.json");
const hypurrSnapshot = require("./hyperevm-hypurr-snapshot.json");
const hyperevmContributors = require("./hyperevm-contributors.json");

class AllocationsGenerator {
    constructor() {
        this.allocations = new Map(); // address -> uint56 allocation
        this.allocationBreakdowns = new Map(); // address -> {fromEthereum, fromHypurr, fromHyperEVMContributor, fromTreasury}
        this.sources = new Map(); // address -> {ethereum, hypurr, hyperevmContributor}
        this.totalSIR = 0n;
        this.totalNFTs = 0;
    }

    // Calculate total SIR for a user across all balance types
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

    // Process ethereum snapshot to calculate SIR allocations
    processEthereumSnapshot() {
        console.log("Processing Ethereum snapshot...");

        const balances = ethereumSnapshot.balances;
        let totalSIR = 0n;
        const userSIR = new Map(); // address -> total SIR

        // Calculate total SIR for each user
        for (const [address, balanceData] of Object.entries(balances)) {
            const userTotal = this.calculateUserTotalSIR(balanceData);

            // Replace old treasury with new treasury
            const finalAddress = address.toLowerCase() === OLD_TREASURY.toLowerCase() ? NEW_TREASURY : address;

            if (userTotal > 0n) {
                // If new treasury already exists and we're adding old treasury, combine them
                if (finalAddress.toLowerCase() === NEW_TREASURY.toLowerCase() && userSIR.has(NEW_TREASURY)) {
                    userSIR.set(NEW_TREASURY, userSIR.get(NEW_TREASURY) + userTotal);
                } else {
                    userSIR.set(finalAddress, userTotal);
                }
                totalSIR += userTotal;
            }
        }

        this.totalSIR = totalSIR;
        console.log(`Total SIR across all holders: ${ethers.formatUnits(totalSIR, 12)} SIR`);
        console.log(`Number of unique holders: ${userSIR.size}`);

        // Calculate allocations (25% of total issuance = 25/30 of contributor pool)
        const MAX_UINT56 = (1n << 56n) - 1n;
        const sirAllocationPool = (MAX_UINT56 * BigInt(SIR_HOLDER_ALLOCATION)) / 30n;

        for (const [address, sirAmount] of userSIR.entries()) {
            const allocation = (sirAllocationPool * sirAmount) / totalSIR;
            this.allocations.set(address, allocation);

            // Store breakdown
            const breakdown = this.allocationBreakdowns.get(address) || { fromEthereum: 0n, fromHypurr: 0n, fromHyperEVMContributor: 0n, fromTreasury: 0n };
            breakdown.fromEthereum = allocation;
            this.allocationBreakdowns.set(address, breakdown);

            // Store source data
            const originalAddress = address === NEW_TREASURY ? OLD_TREASURY : address;
            const balanceData = balances[originalAddress] || balances[address];
            if (balanceData) {
                const sources = this.sources.get(address) || {};
                sources.ethereum = {
                    ...balanceData,
                    totalSIR: sirAmount.toString()
                };
                this.sources.set(address, sources);
            }
        }

        console.log(`SIR holder allocations calculated (${SIR_HOLDER_ALLOCATION}% of pool)`);
    }

    // Process Hypurr snapshot to calculate NFT allocations
    processHypurrSnapshot() {
        console.log("\nProcessing Hypurr NFT snapshot...");

        const balances = hypurrSnapshot.balances;
        let totalNFTs = 0;

        // Count total NFTs
        for (const count of Object.values(balances)) {
            totalNFTs += count;
        }

        this.totalNFTs = totalNFTs;
        console.log(`Total Hypurr NFTs: ${totalNFTs}`);
        console.log(`Number of unique holders: ${Object.keys(balances).length}`);

        // Calculate allocations (1% of total issuance = 1/30 of contributor pool)
        const MAX_UINT56 = (1n << 56n) - 1n;
        const nftAllocationPool = (MAX_UINT56 * BigInt(HYPURR_HOLDER_ALLOCATION)) / 30n;

        for (const [address, nftCount] of Object.entries(balances)) {
            const allocation = (nftAllocationPool * BigInt(nftCount)) / BigInt(totalNFTs);

            // Add to existing allocation if address already has SIR allocation
            if (this.allocations.has(address)) {
                this.allocations.set(address, this.allocations.get(address) + allocation);
            } else {
                this.allocations.set(address, allocation);
            }

            // Store breakdown
            const breakdown = this.allocationBreakdowns.get(address) || { fromEthereum: 0n, fromHypurr: 0n, fromHyperEVMContributor: 0n, fromTreasury: 0n };
            breakdown.fromHypurr = allocation;
            this.allocationBreakdowns.set(address, breakdown);

            // Store source data
            const sources = this.sources.get(address) || {};
            sources.hypurr = {
                nftCount: nftCount
            };
            this.sources.set(address, sources);
        }

        console.log(`Hypurr holder allocations calculated (${HYPURR_HOLDER_ALLOCATION}% of pool)`);
    }

    // Process HyperEVM contributors with basis point allocations
    processHyperEvmContributors() {
        console.log("\nProcessing HyperEVM contributors...");

        let totalBasisPoints = 0;

        // Calculate total basis points
        for (const basisPoints of Object.values(hyperevmContributors)) {
            totalBasisPoints += basisPoints;
        }

        console.log(`Total basis points: ${totalBasisPoints} (${totalBasisPoints / 100}%)`);
        console.log(`Number of contributors: ${Object.keys(hyperevmContributors).length}`);

        // Calculate allocations
        // Formula: basisPoints/10000 * type(uint56).max * 100/30
        // This converts basis points (from total issuance) to contributor pool allocation
        const MAX_UINT56 = (1n << 56n) - 1n;

        for (const [address, basisPoints] of Object.entries(hyperevmContributors)) {
            // allocation = (basisPoints / 10000) * MAX_UINT56 * (100 / 30)
            const allocation = (MAX_UINT56 * BigInt(basisPoints) * 100n) / (10000n * 30n);

            // Add to existing allocation if address already has allocation
            if (this.allocations.has(address)) {
                this.allocations.set(address, this.allocations.get(address) + allocation);
            } else {
                this.allocations.set(address, allocation);
            }

            // Store breakdown
            const breakdown = this.allocationBreakdowns.get(address) || { fromEthereum: 0n, fromHypurr: 0n, fromHyperEVMContributor: 0n, fromTreasury: 0n };
            breakdown.fromHyperEVMContributor = allocation;
            this.allocationBreakdowns.set(address, breakdown);

            // Store source data
            const sources = this.sources.get(address) || {};
            sources.hyperevmContributor = {
                basisPoints: basisPoints
            };
            this.sources.set(address, sources);

            const percent = basisPoints / 100;
            console.log(`  ${address}: ${basisPoints} bp (${percent}% of total)`);
        }

        console.log(`HyperEVM contributor allocations calculated`);
    }

    // Add treasury allocation for remainder
    addTreasuryAllocation() {
        console.log("\nCalculating treasury allocation...");

        const MAX_UINT56 = (1n << 56n) - 1n;
        let allocatedSoFar = 0n;

        // Sum all allocations
        for (const allocation of this.allocations.values()) {
            allocatedSoFar += allocation;
        }

        // Treasury gets the remainder
        const treasuryAllocation = MAX_UINT56 - allocatedSoFar;

        // Add or update treasury allocation
        if (this.allocations.has(NEW_TREASURY)) {
            this.allocations.set(NEW_TREASURY, this.allocations.get(NEW_TREASURY) + treasuryAllocation);
        } else {
            this.allocations.set(NEW_TREASURY, treasuryAllocation);
        }

        // Store treasury remainder in breakdown
        const breakdown = this.allocationBreakdowns.get(NEW_TREASURY) || { fromEthereum: 0n, fromHypurr: 0n, fromHyperEVMContributor: 0n, fromTreasury: 0n };
        breakdown.fromTreasury = treasuryAllocation;
        this.allocationBreakdowns.set(NEW_TREASURY, breakdown);

        const treasuryPercent = (Number(treasuryAllocation) / Number(MAX_UINT56)) * 100;
        console.log(`Treasury allocation: ${treasuryPercent.toFixed(2)}% of pool`);
        console.log(`Treasury allocation (uint56): ${treasuryAllocation.toString()}`);
    }

    // Generate allocations JSON file
    generateJSON() {
        console.log("\nGenerating allocations JSON...");

        const MAX_UINT56 = (1n << 56n) - 1n;

        // Sort by allocation descending
        const sortedAllocations = Array.from(this.allocations.entries()).sort((a, b) => {
            if (b[1] > a[1]) return 1;
            if (b[1] < a[1]) return -1;
            return 0;
        });

        // Calculate total basis points for metadata
        let totalBasisPoints = 0;
        for (const basisPoints of Object.values(hyperevmContributors)) {
            totalBasisPoints += basisPoints;
        }

        // Create metadata object
        const metadata = {
            generatedAt: new Date().toISOString(),
            totalSIR: ethers.formatUnits(this.totalSIR, 12),
            totalSIRRaw: this.totalSIR.toString(),
            totalNFTs: this.totalNFTs,
            totalAddresses: this.allocations.size,
            maxUint56: MAX_UINT56.toString(),
            allocationDistribution: {
                lpAllocation: `${LP_ALLOCATION}%`,
                sirHolders: `${SIR_HOLDER_ALLOCATION}%`,
                hypurrHolders: `${HYPURR_HOLDER_ALLOCATION}%`,
                hyperevmContributors: `${totalBasisPoints / 100}%`,
                treasury: "Remainder"
            },
            sources: {
                ethereumSnapshot: "ethereum-snapshot.json",
                hypurrSnapshot: "hyperevm-hypurr-snapshot.json",
                hyperevmContributors: "hyperevm-contributors.json"
            },
            oldTreasury: OLD_TREASURY,
            newTreasury: NEW_TREASURY
        };

        // Create object with address -> detailed allocation info
        const allocationsObj = {};
        for (const [address, allocation] of sortedAllocations) {
            // Calculate % of total issuance (contributors are 30% of total, so multiply by 0.3)
            const percentOfContributorPool = (Number(allocation) / Number(MAX_UINT56)) * 100;
            const percentOfTotalIssuance = percentOfContributorPool * 0.3; // Contributors are 30% of total

            // Format percentage string
            let allocationPerc;
            if (percentOfTotalIssuance >= 0.01) {
                // For percentages >= 0.01%, show 2 decimal places
                allocationPerc = `${percentOfTotalIssuance.toFixed(2)}%`;
            } else {
                // For very small percentages, show 6 decimal places
                allocationPerc = `${percentOfTotalIssuance.toFixed(6)}%`;
            }

            // Get breakdown
            const breakdown = this.allocationBreakdowns.get(address) || { fromEthereum: 0n, fromHypurr: 0n, fromHyperEVMContributor: 0n, fromTreasury: 0n };

            // Get sources
            const sources = this.sources.get(address) || {};

            allocationsObj[address] = {
                allocation: allocation.toString(),
                allocationPerc: allocationPerc,
                sources: sources,
                allocationBreakdown: {
                    fromEthereum: breakdown.fromEthereum.toString(),
                    fromHypurr: breakdown.fromHypurr.toString(),
                    fromHyperEVMContributor: breakdown.fromHyperEVMContributor.toString(),
                    fromTreasury: breakdown.fromTreasury.toString()
                }
            };
        }

        return {
            metadata: metadata,
            allocations: allocationsObj
        };
    }

    // Main execution
    async execute() {
        // Calculate total basis points for display
        let totalBasisPoints = 0;
        for (const basisPoints of Object.values(hyperevmContributors)) {
            totalBasisPoints += basisPoints;
        }
        const hyperevmContributorPercent = totalBasisPoints / 100;

        console.log("=== Allocations Generator ===\n");
        console.log(`Old Treasury: ${OLD_TREASURY}`);
        console.log(`New Treasury: ${NEW_TREASURY}`);
        console.log(`\nAllocation Distribution:`);
        console.log(`  LP: ${LP_ALLOCATION}%`);
        console.log(`  SIR Holders: ${SIR_HOLDER_ALLOCATION}%`);
        console.log(`  Hypurr Holders: ${HYPURR_HOLDER_ALLOCATION}%`);
        console.log(`  HyperEVM Contributors: ${hyperevmContributorPercent}%`);
        console.log(`  Treasury: Remainder`);
        console.log("\n" + "=".repeat(50) + "\n");

        // Process snapshots
        this.processEthereumSnapshot();
        this.processHypurrSnapshot();
        this.processHyperEvmContributors();
        this.addTreasuryAllocation();

        // Generate JSON
        const allocationsJSON = this.generateJSON();

        // Save to file
        const outputPath = path.join(__dirname, "allocations.json");
        fs.writeFileSync(outputPath, JSON.stringify(allocationsJSON, null, 2));
        console.log(`\nGenerated file: ${outputPath}`);

        // Print summary
        console.log("\n=== Summary ===");
        console.log(`Total addresses: ${this.allocations.size}`);
        console.log(`Total SIR processed: ${ethers.formatUnits(this.totalSIR, 12)} SIR`);
        console.log(`Total Hypurr NFTs: ${this.totalNFTs}`);

        // Verify sum equals type(uint56).max
        const MAX_UINT56 = (1n << 56n) - 1n;
        let sum = 0n;
        for (const allocation of this.allocations.values()) {
            sum += allocation;
        }
        console.log(`\nVerification:`);
        console.log(`  Sum of allocations: ${sum}`);
        console.log(`  type(uint56).max:   ${MAX_UINT56}`);
        console.log(`  Match: ${sum === MAX_UINT56 ? "✓" : "✗"}`);

        if (sum !== MAX_UINT56) {
            console.error(`ERROR: Allocations do not sum to type(uint56).max!`);
            console.error(`Difference: ${MAX_UINT56 - sum}`);
        }
    }
}

// Main execution
async function main() {
    // Validate configuration
    if (NEW_TREASURY === "0x0000000000000000000000000000000000000000") {
        console.error("ERROR: NEW_TREASURY must be set to a valid address");
        process.exit(1);
    }

    const generator = new AllocationsGenerator();
    await generator.execute();
}

main().catch((error) => {
    console.error("Error:", error);
    process.exit(1);
});
