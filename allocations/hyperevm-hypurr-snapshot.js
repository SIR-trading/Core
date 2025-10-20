const ethers = require("ethers");
const fs = require("fs");
const path = require("path");
// Load .env from parent directory
require("dotenv").config({ path: path.join(__dirname, "..", ".env") });

// Configuration
const ALCHEMY_URL = "https://hyperliquid-mainnet.g.alchemy.com/v2/";
const ALCHEMY_KEY = process.env.ALCHEMY_KEY || "YOUR_KEY_HERE";

// Block range configuration
const START_BLOCK = 15060098; // HyperEVM genesis
const SNAPSHOT_BLOCK = "latest"; // Can be overridden with: node hyperevm-hypurr-snapshot.js <blockNumber>

// Contract address
const HYPURR_NFT = "0x9125e2d6827a00b0f8330d6ef7bef07730bac685";

// ABI for ERC721
const HYPURR_ABI = [
    "function name() view returns (string)",
    "function symbol() view returns (string)",
    "function totalSupply() view returns (uint256)",
    "function ownerOf(uint256 tokenId) view returns (address)",
    "function balanceOf(address owner) view returns (uint256)",
    "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)"
];

class HypurrNFTSnapshot {
    constructor(provider, blockNumber) {
        this.provider = provider;
        this.blockNumber = blockNumber;
        this.contract = null;
        this.results = {
            blockNumber: blockNumber,
            timestamp: null,
            timestampGMT: null,
            contract: HYPURR_NFT,
            balances: {}, // address -> count
            summary: {
                totalSupply: "0",
                totalHolders: 0
            }
        };
    }

    async initialize() {
        // Resolve block number
        if (this.blockNumber === "latest") {
            this.blockNumber = await this.provider.getBlockNumber();
        }
        this.results.blockNumber = this.blockNumber;

        // Get timestamp
        const block = await this.provider.getBlock(this.blockNumber);
        this.results.timestamp = block.timestamp;
        this.results.timestampGMT = new Date(block.timestamp * 1000).toISOString();

        // Initialize contract
        this.contract = new ethers.Contract(HYPURR_NFT, HYPURR_ABI, this.provider);

        console.log(`Initialized at block ${this.blockNumber} (${this.results.timestampGMT})`);
    }

    async getHolders() {
        console.log("Fetching Hypurr NFT holders...");

        // Get total supply
        const totalSupply = await this.contract.totalSupply({ blockTag: this.blockNumber });
        this.results.summary.totalSupply = totalSupply.toString();
        console.log(`Total Supply: ${totalSupply}`);

        // Track ownership via Transfer events
        const holders = new Map(); // address -> count

        // Query Transfer events in batches
        const BATCH_SIZE = 10000;
        let totalTransfers = 0;

        for (let fromBlock = START_BLOCK; fromBlock <= this.blockNumber; fromBlock += BATCH_SIZE) {
            const toBlock = Math.min(fromBlock + BATCH_SIZE - 1, this.blockNumber);

            const transferEvents = await this.contract.queryFilter(
                this.contract.filters.Transfer(),
                fromBlock,
                toBlock
            );

            // Process transfers
            for (const event of transferEvents) {
                const from = event.args.from;
                const to = event.args.to;

                // Decrease count for sender (unless minting from zero address)
                if (from !== ethers.ZeroAddress) {
                    const currentCount = holders.get(from) || 0;
                    if (currentCount > 0) {
                        holders.set(from, currentCount - 1);
                    }
                }

                // Increase count for receiver (unless burning to zero address)
                if (to !== ethers.ZeroAddress) {
                    const currentCount = holders.get(to) || 0;
                    holders.set(to, currentCount + 1);
                }
            }

            totalTransfers += transferEvents.length;
        }

        console.log(`Processed ${totalTransfers} Transfer events`);

        // Filter out addresses with 0 balance and convert to results
        for (const [address, count] of holders.entries()) {
            if (count > 0) {
                this.results.balances[address] = count;
            }
        }

        this.results.summary.totalHolders = Object.keys(this.results.balances).length;
        console.log(`Found ${this.results.summary.totalHolders} unique holders`);
    }

    async execute() {
        await this.initialize();
        await this.getHolders();
        return this.results;
    }

    saveResults(filename = null) {
        if (!filename) {
            filename = `hyperevm-hypurr-snapshot.json`;
        }

        const outputPath = path.join(__dirname, filename);
        fs.writeFileSync(outputPath, JSON.stringify(this.results, null, 2));
        console.log(`Results saved to ${outputPath}`);
    }
}

// Main execution
async function main() {
    // Parse block number argument (overrides SNAPSHOT_BLOCK constant)
    let blockNumber = SNAPSHOT_BLOCK;
    if (process.argv[2]) {
        const parsed = parseInt(process.argv[2]);
        blockNumber = isNaN(parsed) ? process.argv[2] : parsed;
    }

    // Validate required configuration
    if (!ALCHEMY_KEY || ALCHEMY_KEY === "YOUR_KEY_HERE") {
        console.error("ERROR: ALCHEMY_KEY must be set in .env file");
        process.exit(1);
    }

    console.log(`Starting Hypurr NFT snapshot at block ${blockNumber}...`);
    console.log(`Contract: ${HYPURR_NFT}`);

    const provider = new ethers.JsonRpcProvider(ALCHEMY_URL + ALCHEMY_KEY);
    const snapshot = new HypurrNFTSnapshot(provider, blockNumber);

    try {
        const results = await snapshot.execute();
        snapshot.saveResults();

        console.log("\n=== Snapshot Summary ===");
        console.log(`Block: ${results.blockNumber}`);
        console.log(`Timestamp: ${new Date(results.timestamp * 1000).toISOString()}`);
        console.log(`Total Supply: ${results.summary.totalSupply} NFTs`);
        console.log(`Total Holders: ${results.summary.totalHolders} addresses`);

        // Show distribution
        const counts = Object.values(results.balances);
        const avg = counts.reduce((sum, c) => sum + c, 0) / counts.length;
        const max = Math.max(...counts);
        const min = Math.min(...counts);

        console.log(`\nDistribution:`);
        console.log(`  Average: ${avg.toFixed(2)} NFTs per holder`);
        console.log(`  Min: ${min} NFT(s)`);
        console.log(`  Max: ${max} NFT(s)`);

        // Show top holders
        const sorted = Object.entries(results.balances).sort((a, b) => b[1] - a[1]);
        console.log(`\nTop 10 Holders:`);
        for (let i = 0; i < Math.min(10, sorted.length); i++) {
            console.log(`  ${sorted[i][0]}: ${sorted[i][1]} NFT(s)`);
        }
    } catch (error) {
        console.error("Error during snapshot:", error);
        process.exit(1);
    }
}

main();
