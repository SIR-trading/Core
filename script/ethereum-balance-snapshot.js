const ethers = require("ethers");
const fs = require("fs");
const path = require("path");
// Load .env from parent directory
require("dotenv").config({ path: path.join(__dirname, "..", ".env") });

// Configuration
const ALCHEMY_URL = "https://eth-mainnet.g.alchemy.com/v2/";
const ALCHEMY_KEY = process.env.ALCHEMY_KEY || "YOUR_KEY_HERE";
const SIR_DECIMALS = 12; // SIR token uses 12 decimals

// Block range configuration
// START_BLOCK: First block to query for events (set to your deployment block to speed up queries)
// Set to 0 to query from genesis, or to a specific block number to skip earlier blocks
const START_BLOCK = 22931060; // Change this to your deployment block for faster queries
// SNAPSHOT_BLOCK: Block number for the snapshot (can be overridden by command line argument)
// Set to "latest" for current block, or a specific number
const SNAPSHOT_BLOCK = "latest"; // Can be overridden with: node ethereum-balance-snapshot.js <blockNumber>

// Contract addresses - hardcoded from Ethereum mainnet deployment
const ADDRESSES = {
    ASSISTANT: "0xff14f91285580AEd3733c0B1F3C8b6d04804c5ec",
    CONTRIBUTORS: "0xCA5d6c55e249a9Add07a2440eccfe16f56572cb5",
    UNISWAP_V3_FACTORY: "0x1F98431c8aD98523631AE4a59f267346ea31F984",
    UNISWAP_V3_NFT_MANAGER: "0xC36442b4a4522E871399CD717aBDD847Ab11FE88",
    UNISWAP_V3_STAKING: "0xe34139463bA50bD61336E0c446Bd8C0867c6fE65",
    WETH: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    MULTICALL3: "0xcA11bde05977b3631167028862bE2a173976CA11"
    // VAULT, SIR, and ORACLE will be dynamically retrieved
};

// Manually ignored contract addresses (add addresses here to exclude them from snapshot)
// These will be excluded in addition to system contracts (Assistant, Contributors, Vault, SIR, Oracle, etc.)
const MANUALLY_IGNORED_CONTRACTS = [
    "0xD632204b44Ddf050019676BE26f23aDFC539DBAa", // Uniswap pool ETH/SIR
    "0x000000fee13a103A10D593b9AE06b3e05F2E7E1c", // Uniswap fee collector
    "0xCeFeF7bb8c4E32451f5FcEAF2127B0c26c89975b" // Uniswap pool APE-6/SIR
];

// Contributor addresses from ethereum-contributors.json
const CONTRIBUTOR_ADDRESSES = require("./ethereum-contributors.json");

// ABIs (partial ABIs with only needed functions)
const ABIS = {
    SIR: [
        "function balanceOf(address) view returns (uint256)",
        "function totalSupply() view returns (uint256)",
        "function contributorUnclaimedSIR(address) view returns (uint80)",
        "function ISSUANCE_RATE() view returns (uint72)",
        "function LP_ISSUANCE_FIRST_3_YEARS() view returns (uint72)",
        "function stakeOf(address) view returns (uint80 unlockedStake, uint80 lockedStake)",
        "event Transfer(address indexed from, address indexed to, uint256 amount)",
        "event Staked(address indexed staker, uint80 amount)",
        "event Unstaked(address indexed staker, uint80 amount)"
    ],
    STAKER: [
        "function stakeOf(address) view returns (uint80 unlockedStake, uint80 lockedStake)",
        "event Staked(address indexed staker, uint80 amount)",
        "event Unstaked(address indexed staker, uint80 amount)"
    ],
    VAULT: [
        "function balanceOf(address, uint256) view returns (uint256)",
        "function totalSupply(uint256) view returns (uint256)",
        "function paramsById(uint48) view returns (address debtToken, address collateralToken, int8 leverageTier)",
        "function vaultStates(address, address, int8) view returns (uint48 vaultId, uint40 timestampLastCollectionOfFees, uint144 cumulativeFees)",
        "function getReserves(tuple(address collateralToken, address debtToken, int8 leverageTier)) view returns (tuple(uint144 reserveLPers, uint144 reserveApes))",
        "function unclaimedRewards(uint256, address) view returns (uint80)",
        "function APE_IMPLEMENTATION() view returns (address)",
        "function SIR() view returns (address)",
        "function ORACLE() view returns (address)",
        "function TIMESTAMP_ISSUANCE_START() view returns (uint40)",
        "event Mint(uint48 indexed vaultId, address indexed minter, bool isAPE, uint144 collateralIn, uint144 collateralFeeToStakers, uint144 collateralFeeToLPers, uint256 tokenOut)",
        "event Burn(uint48 indexed vaultId, address indexed burner, bool isAPE, uint256 tokenIn, uint144 collateralWithdrawn, uint144 collateralFeeToStakers, uint144 collateralFeeToLPers)",
        "event Transfer(address indexed from, address indexed to, uint256 indexed id, uint256 amount)",
        "event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)",
        "event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)"
    ],
    ASSISTANT: [
        "function VAULT() view returns (address)",
        "function priceOfTEA(tuple(address collateralToken, address debtToken, int8 leverageTier)) view returns (uint256 num, uint256 den)",
        "function priceOfAPE(tuple(address collateralToken, address debtToken, int8 leverageTier)) view returns (uint256 num, uint256 den)",
        "function getAddressAPE(uint48) view returns (address)",
        "function quoteCollateralToDebtToken(address debtToken, address collateralToken, uint256 amountCollateral) view returns (uint256)"
    ],
    ERC20: [
        "function balanceOf(address) view returns (uint256)",
        "function totalSupply() view returns (uint256)",
        "function decimals() view returns (uint8)"
    ],
    UNISWAP_V3_POOL: [
        "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)",
        "function liquidity() view returns (uint128)",
        "function token0() view returns (address)",
        "function token1() view returns (address)",
        "function fee() view returns (uint24)",
        "function ticks(int24) view returns (uint128 liquidityGross, int128 liquidityNet, uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128, int56 tickCumulativeOutside, uint160 secondsPerLiquidityOutsideX128, uint32 secondsOutside, bool initialized)",
        "function snapshotCumulativesInside(int24 tickLower, int24 tickUpper) view returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside)"
    ],
    UNISWAP_V3_NFT: [
        "function positions(uint256) view returns (uint96 nonce, address operator, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1)",
        "function balanceOf(address) view returns (uint256)",
        "function tokenOfOwnerByIndex(address, uint256) view returns (uint256)",
        "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
        "event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)"
    ],
    UNISWAP_V3_STAKING: [
        "function deposits(uint256 tokenId) view returns (address owner, uint48 numberOfStakes, int24 tickLower, int24 tickUpper)",
        "function stakes(uint256 tokenId, bytes32 incentiveId) view returns (uint128 liquidity, uint160 secondsPerLiquidityInsideInitialX128)",
        "function getRewardInfo(tuple(address rewardToken, address pool, uint256 startTime, uint256 endTime, address refundee) key, uint256 tokenId) view returns (uint256 reward, uint160 secondsInsideX128)",
        "function incentives(bytes32 incentiveId) view returns (uint256 totalRewardUnclaimed, uint160 totalSecondsClaimedX128, uint96 numberOfStakes)",
        "event IncentiveCreated(address indexed rewardToken, address indexed pool, uint256 startTime, uint256 endTime, address refundee, uint256 reward)",
        "event DepositTransferred(uint256 indexed tokenId, address indexed oldOwner, address indexed newOwner)",
        "event TokenStaked(uint256 indexed tokenId, bytes32 indexed incentiveId, uint128 liquidity)",
        "event TokenUnstaked(uint256 indexed tokenId, bytes32 indexed incentiveId)"
    ],
    CONTRIBUTORS: ["function allocations(address) view returns (uint56)"],
    MULTICALL3: [
        "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) view returns (tuple(bool success, bytes returnData)[] returnData)"
    ]
};

class SIRBalanceSnapshot {
    constructor(provider, blockNumber) {
        this.provider = provider;
        this.blockNumber = blockNumber; // Will be resolved to actual number in initialize()
        this.contracts = {};
        this.contractCache = new Map(); // Cache for contract checks
        this.ignoredContracts = new Set(); // Contracts to ignore by default
        this.contractsWithBalances = []; // Track contracts with non-zero balances
        this.vaultTeaHolders = new Map(); // vaultId -> Set of TEA holders (for unclaimed rewards)
        this.BATCH_SIZE = 500; // Number of calls per multicall batch
        this.timestampIssuanceStart = null; // Will be fetched from SIR contract
        this.issuanceRate = null; // Will be fetched from SIR contract
        this.lpIssuanceFirst3Years = null; // Will be fetched from SIR contract
        this.uniswapV3Positions = new Map(); // tokenId -> owner for staked positions tracking
        this.results = {
            blockNumber: blockNumber,
            timestamp: null,
            balances: {},
            summary: {
                totalSIRSupply: "0",
                totalStakedSIR: "0",
                totalVaultEquity: "0",
                totalUnclaimedRewards: "0",
                totalContributorUnissued: "0",
                totalUniswapV3Equity: "0",
                totalUniswapV3UnclaimedFees: "0",
                totalUniswapV3StakingRewards: "0"
            }
        };
    }

    // Helper function to format numbers to 3 significant digits for display
    formatToSigFigs(value, sigFigs = 3) {
        const num = typeof value === "string" ? parseFloat(value) : value;

        if (num === 0 || !isFinite(num)) return "0";

        // Get the order of magnitude
        const magnitude = Math.floor(Math.log10(Math.abs(num)));

        // Calculate the precision needed
        const precision = sigFigs - magnitude - 1;

        // Round to significant figures
        const factor = Math.pow(10, precision);
        const rounded = Math.round(num * factor) / factor;

        // Format with appropriate precision
        if (magnitude >= sigFigs - 1) {
            // Large numbers: use toExponential or format as integer
            return rounded.toLocaleString("en-US", {
                maximumSignificantDigits: sigFigs,
                useGrouping: true
            });
        } else {
            // Small numbers: preserve significant figures
            return rounded.toPrecision(sigFigs);
        }
    }

    // Helper function to check if an address is a contract (with caching)
    async isContract(address) {
        if (this.contractCache.has(address)) {
            return this.contractCache.get(address);
        }

        const code = await this.provider.getCode(address, this.blockNumber);
        const isContract = code !== "0x";
        this.contractCache.set(address, isContract);
        return isContract;
    }

    // Helper function to batch multiple contract calls using Multicall3
    async batchCall(calls) {
        const results = [];

        // Process in batches to avoid gas limits
        for (let i = 0; i < calls.length; i += this.BATCH_SIZE) {
            const batch = calls.slice(i, i + this.BATCH_SIZE);

            const multicallCalls = batch.map((call) => ({
                target: call.target,
                allowFailure: true,
                callData: call.callData
            }));

            const batchResults = await this.contracts.multicall.aggregate3(multicallCalls, {
                blockTag: this.blockNumber
            });

            results.push(...batchResults);
        }

        return results;
    }

    async initialize() {
        // Initialize Multicall3 contract
        this.contracts.multicall = new ethers.Contract(ADDRESSES.MULTICALL3, ABIS.MULTICALL3, this.provider);

        // Initialize Assistant contract first (hardcoded for mainnet deployment)
        this.contracts.assistant = new ethers.Contract(ADDRESSES.ASSISTANT, ABIS.ASSISTANT, this.provider);

        // Retrieve VAULT address from Assistant
        console.log("Retrieving contract addresses...");
        ADDRESSES.VAULT = await this.contracts.assistant.VAULT({ blockTag: this.blockNumber });

        if (!ADDRESSES.VAULT || ADDRESSES.VAULT === ethers.ZeroAddress) {
            throw new Error(`Failed to retrieve VAULT address from Assistant contract at ${ADDRESSES.ASSISTANT}`);
        }
        console.log(`VAULT address: ${ADDRESSES.VAULT}`);

        // Initialize Vault contract
        this.contracts.vault = new ethers.Contract(ADDRESSES.VAULT, ABIS.VAULT, this.provider);

        // Retrieve SIR and ORACLE addresses from Vault
        ADDRESSES.SIR = await this.contracts.vault.SIR({ blockTag: this.blockNumber });
        if (!ADDRESSES.SIR || ADDRESSES.SIR === ethers.ZeroAddress) {
            throw new Error(`Failed to retrieve SIR address from Vault contract at ${ADDRESSES.VAULT}`);
        }

        ADDRESSES.ORACLE = await this.contracts.vault.ORACLE({ blockTag: this.blockNumber });
        if (!ADDRESSES.ORACLE || ADDRESSES.ORACLE === ethers.ZeroAddress) {
            throw new Error(`Failed to retrieve ORACLE address from Vault contract at ${ADDRESSES.VAULT}`);
        }

        console.log(`SIR address: ${ADDRESSES.SIR}`);
        console.log(`ORACLE address: ${ADDRESSES.ORACLE}`);

        // Initialize remaining contracts
        this.contracts.sir = new ethers.Contract(ADDRESSES.SIR, ABIS.SIR, this.provider);

        // Fetch issuance parameters - TIMESTAMP_ISSUANCE_START is on Vault, others on SIR
        this.timestampIssuanceStart = await this.contracts.vault.TIMESTAMP_ISSUANCE_START({
            blockTag: this.blockNumber
        });
        this.issuanceRate = await this.contracts.sir.ISSUANCE_RATE({ blockTag: this.blockNumber });
        this.lpIssuanceFirst3Years = await this.contracts.sir.LP_ISSUANCE_FIRST_3_YEARS({ blockTag: this.blockNumber });

        console.log(`TIMESTAMP_ISSUANCE_START: ${this.timestampIssuanceStart}`);
        console.log(
            `ISSUANCE_RATE: ${this.formatToSigFigs(ethers.formatUnits(this.issuanceRate, SIR_DECIMALS))} SIR/second`
        );
        console.log(
            `LP_ISSUANCE_FIRST_3_YEARS: ${this.formatToSigFigs(
                ethers.formatUnits(this.lpIssuanceFirst3Years, SIR_DECIMALS)
            )} SIR/second`
        );

        // Initialize Contributors contract if provided
        if (ADDRESSES.CONTRIBUTORS) {
            this.contracts.contributors = new ethers.Contract(ADDRESSES.CONTRIBUTORS, ABIS.CONTRIBUTORS, this.provider);
        }

        // Populate default ignored contracts (system contracts)
        this.ignoredContracts.add(ADDRESSES.ASSISTANT.toLowerCase());
        this.ignoredContracts.add(ADDRESSES.CONTRIBUTORS.toLowerCase());
        this.ignoredContracts.add(ADDRESSES.UNISWAP_V3_FACTORY.toLowerCase());
        this.ignoredContracts.add(ADDRESSES.UNISWAP_V3_NFT_MANAGER.toLowerCase());
        this.ignoredContracts.add(ADDRESSES.UNISWAP_V3_STAKING.toLowerCase());
        this.ignoredContracts.add(ADDRESSES.VAULT.toLowerCase());
        this.ignoredContracts.add(ADDRESSES.SIR.toLowerCase());
        this.ignoredContracts.add(ADDRESSES.ORACLE.toLowerCase());

        // Add manually ignored contracts from the array
        MANUALLY_IGNORED_CONTRACTS.forEach((address) => {
            this.ignoredContracts.add(address.toLowerCase());
        });

        // Get block timestamp and resolve "latest" to actual block number
        const block = await this.provider.getBlock(this.blockNumber);
        this.blockNumber = block.number; // Convert "latest" to actual number
        this.results.timestamp = block.timestamp;
        this.results.blockNumber = this.blockNumber; // Update results with actual number

        console.log(
            `Initializing snapshot for block ${this.blockNumber} (${new Date(block.timestamp * 1000).toISOString()})`
        );
    }

    // 1. Get SIR token balances
    async getSIRBalances() {
        console.log("Fetching SIR token balances...");

        // Get Transfer events to find all holders
        const filter = this.contracts.sir.filters.Transfer();
        const events = await this.contracts.sir.queryFilter(filter, START_BLOCK, this.blockNumber);

        const holders = new Set();
        events.forEach((event) => {
            holders.add(event.args.from);
            holders.add(event.args.to);
        });

        // Remove zero address
        holders.delete(ethers.ZeroAddress);

        const holdersArray = Array.from(holders);
        console.log(`Checking balances for ${holdersArray.length} potential holders...`);

        // Prepare multicall for all balanceOf calls
        const calls = holdersArray.map((holder) => ({
            target: ADDRESSES.SIR,
            callData: this.contracts.sir.interface.encodeFunctionData("balanceOf", [holder])
        }));

        // Execute multicall
        const results = await this.batchCall(calls);

        // Process results
        for (let i = 0; i < holdersArray.length; i++) {
            const holder = holdersArray[i];
            const result = results[i];

            if (!result.success) continue;

            const balance = BigInt(result.returnData);

            if (balance > 0n) {
                const isContractAddr = await this.isContract(holder);

                // Skip if in manually ignored list
                if (this.ignoredContracts.has(holder.toLowerCase())) {
                    continue;
                }

                // If it's a contract (not manually ignored), add to review list
                if (isContractAddr) {
                    this.contractsWithBalances.push({
                        address: holder,
                        sirBalance: balance.toString(),
                        type: "SIR Balance"
                    });
                }

                // Add to results (both EOAs and non-ignored contracts)
                if (!this.results.balances[holder]) {
                    this.results.balances[holder] = {};
                }
                this.results.balances[holder].sirBalance = balance.toString();
            }
        }

        // Get total supply
        const totalSupply = await this.contracts.sir.totalSupply({ blockTag: this.blockNumber });
        this.results.summary.totalSIRSupply = totalSupply.toString();

        console.log(`Found ${Object.keys(this.results.balances).length} SIR holders (EOAs only)`);
    }

    // 2. Get staked SIR balances (locked and unlocked)
    async getStakedSIRBalances() {
        console.log("Fetching staked SIR balances...");

        // Get Staked/Unstaked events to find all stakers
        const stakedFilter = this.contracts.sir.filters.Staked();
        const events = await this.contracts.sir.queryFilter(stakedFilter, START_BLOCK, this.blockNumber);

        const stakers = new Set();
        events.forEach((event) => {
            stakers.add(event.args.staker);
        });

        const stakersArray = Array.from(stakers);
        console.log(`Checking staking data for ${stakersArray.length} stakers...`);

        // Prepare multicall for stakeOf
        const calls = [];
        stakersArray.forEach((staker) => {
            calls.push({
                target: ADDRESSES.SIR,
                callData: this.contracts.sir.interface.encodeFunctionData("stakeOf", [staker])
            });
        });

        // Execute multicall
        const results = await this.batchCall(calls);

        let totalStaked = BigInt(0);

        // Process results
        for (let i = 0; i < stakersArray.length; i++) {
            const staker = stakersArray[i];
            const stakeResult = results[i];

            if (!stakeResult.success) continue;

            const stakingData = this.contracts.sir.interface.decodeFunctionResult("stakeOf", stakeResult.returnData);
            const unlockedStake = stakingData.unlockedStake;
            const lockedStake = stakingData.lockedStake;
            const totalStake = unlockedStake + lockedStake;

            if (totalStake > 0n) {
                const isContractAddr = await this.isContract(staker);

                // Skip if in manually ignored list
                if (this.ignoredContracts.has(staker.toLowerCase())) {
                    continue;
                }

                // If it's a contract (not manually ignored), add to review list
                if (isContractAddr) {
                    const existing = this.contractsWithBalances.find((c) => c.address === staker);
                    if (existing) {
                        existing.stakedSIR = totalStake.toString();
                        existing.type += ", Staked SIR";
                    } else {
                        this.contractsWithBalances.push({
                            address: staker,
                            stakedSIR: totalStake.toString(),
                            type: "Staked SIR"
                        });
                    }
                }

                // Add to results (both EOAs and non-ignored contracts)
                if (!this.results.balances[staker]) {
                    this.results.balances[staker] = {};
                }

                this.results.balances[staker].stakedSIR = {
                    unlockedStake: unlockedStake.toString(),
                    lockedStake: lockedStake.toString()
                };

                totalStaked = totalStaked + totalStake;
            }
        }

        this.results.summary.totalStakedSIR = totalStaked.toString();
        console.log(
            `Found stakers with total staked: ${this.formatToSigFigs(
                ethers.formatUnits(totalStaked, SIR_DECIMALS)
            )} SIR (EOAs only)`
        );
    }

    // 3. Get SIR equity in vaults where collateral is SIR
    async getVaultEquity() {
        console.log("Fetching vault equity...");

        // First, find all vaults through Mint events to identify vault IDs
        const mintFilter = this.contracts.vault.filters.Mint();
        const mintEvents = await this.contracts.vault.queryFilter(mintFilter, START_BLOCK, this.blockNumber);

        const vaultIds = new Set();
        mintEvents.forEach((event) => {
            vaultIds.add(event.args.vaultId);
        });

        const vaultIdsArray = Array.from(vaultIds);
        console.log(`Fetching parameters for ${vaultIdsArray.length} vaults...`);

        // Batch 1: Get all vault parameters and filter to SIR vaults only
        const paramsCallsget = vaultIdsArray.map((vaultId) => ({
            target: ADDRESSES.VAULT,
            callData: this.contracts.vault.interface.encodeFunctionData("paramsById", [vaultId])
        }));

        const paramsResults = await this.batchCall(paramsCallsget);

        // Filter to SIR vaults and get their parameters
        const sirVaults = [];
        for (let i = 0; i < vaultIdsArray.length; i++) {
            const result = paramsResults[i];
            if (!result.success) continue;

            const vaultParams = this.contracts.vault.interface.decodeFunctionResult("paramsById", result.returnData);
            if (vaultParams.collateralToken.toLowerCase() === ADDRESSES.SIR.toLowerCase()) {
                sirVaults.push({
                    vaultId: vaultIdsArray[i],
                    params: vaultParams
                });
            }
        }

        console.log(`Found ${sirVaults.length} vaults with SIR collateral`);

        if (sirVaults.length === 0) {
            this.results.summary.totalVaultEquity = "0";
            return;
        }

        // Batch 2: Get APE addresses, reserves, TEA total supplies, and APE total supplies for SIR vaults only
        const vaultDataCalls = [];
        sirVaults.forEach((vault) => {
            vaultDataCalls.push({
                target: ADDRESSES.ASSISTANT,
                callData: this.contracts.assistant.interface.encodeFunctionData("getAddressAPE", [vault.vaultId])
            });
            vaultDataCalls.push({
                target: ADDRESSES.VAULT,
                callData: this.contracts.vault.interface.encodeFunctionData("getReserves", [vault.params])
            });
            vaultDataCalls.push({
                target: ADDRESSES.VAULT,
                callData: this.contracts.vault.interface.encodeFunctionData("totalSupply", [vault.vaultId])
            });
        });

        const vaultDataResults = await this.batchCall(vaultDataCalls);

        // Process each SIR vault: get users who interacted with it and their balances
        let totalVaultEquity = BigInt(0);

        for (let i = 0; i < sirVaults.length; i++) {
            const apeResult = vaultDataResults[i * 3];
            const reservesResult = vaultDataResults[i * 3 + 1];
            const teaTotalSupplyResult = vaultDataResults[i * 3 + 2];

            if (!apeResult.success || !reservesResult.success || !teaTotalSupplyResult.success) continue;

            const vaultId = sirVaults[i].vaultId;
            const apeAddress = ethers.getAddress("0x" + apeResult.returnData.slice(-40));
            const reserves = this.contracts.vault.interface.decodeFunctionResult(
                "getReserves",
                reservesResult.returnData
            )[0];
            const teaTotalSupply = BigInt(teaTotalSupplyResult.returnData);

            // Get users who interacted with THIS specific vault - track TEA and APE separately
            const teaUsers = new Set();
            const apeUsers = new Set();

            // Get TEA holders from TransferSingle and TransferBatch events (ERC1155)
            // Note: 'id' is not indexed, so we must query all events and filter in JS
            const transferSingleFilter = this.contracts.vault.filters.TransferSingle();
            const transferBatchFilter = this.contracts.vault.filters.TransferBatch();

            const transferSingleEvents = await this.contracts.vault.queryFilter(
                transferSingleFilter,
                START_BLOCK,
                this.blockNumber
            );
            const transferBatchEvents = await this.contracts.vault.queryFilter(
                transferBatchFilter,
                START_BLOCK,
                this.blockNumber
            );

            // Filter TransferSingle events for this vaultId
            transferSingleEvents.forEach((event) => {
                if (event.args.id === vaultId) {
                    const from = event.args.from;
                    const to = event.args.to;

                    if (from !== ethers.ZeroAddress) teaUsers.add(from);
                    if (to !== ethers.ZeroAddress) teaUsers.add(to);
                }
            });

            // Filter TransferBatch events for this vaultId
            transferBatchEvents.forEach((event) => {
                const from = event.args.from;
                const to = event.args.to;
                const ids = event.args.ids;

                // Check if this batch includes our vaultId
                if (ids.some((id) => id === vaultId)) {
                    if (from !== ethers.ZeroAddress) teaUsers.add(from);
                    if (to !== ethers.ZeroAddress) teaUsers.add(to);
                }
            });

            // Get APE holders from Transfer events (ERC20)
            const apeContract = new ethers.Contract(
                apeAddress,
                [...ABIS.ERC20, "event Transfer(address indexed from, address indexed to, uint256 amount)"],
                this.provider
            );

            const apeTransferFilter = apeContract.filters.Transfer();
            const apeTransferEvents = await apeContract.queryFilter(apeTransferFilter, START_BLOCK, this.blockNumber);

            apeTransferEvents.forEach((event) => {
                const from = event.args.from;
                const to = event.args.to;

                if (from !== ethers.ZeroAddress) apeUsers.add(from);
                if (to !== ethers.ZeroAddress) apeUsers.add(to);
            });

            // Get APE total supply
            const apeTotalSupply = await apeContract.totalSupply({ blockTag: this.blockNumber });

            // Batch get balances - TEA users get TEA balance, APE users get APE balance
            const teaUsersArray = Array.from(teaUsers);
            const apeUsersArray = Array.from(apeUsers);
            const balanceCalls = [];
            const userBalanceMap = []; // Track which call corresponds to which user and type

            for (const user of teaUsersArray) {
                balanceCalls.push({
                    target: ADDRESSES.VAULT,
                    callData: this.contracts.vault.interface.encodeFunctionData("balanceOf", [user, vaultId])
                });
                userBalanceMap.push({ user, type: "tea" });
            }

            for (const user of apeUsersArray) {
                balanceCalls.push({
                    target: apeAddress,
                    callData: apeContract.interface.encodeFunctionData("balanceOf", [user])
                });
                userBalanceMap.push({ user, type: "ape" });
            }

            const balanceResults = await this.batchCall(balanceCalls);

            // Collect balances by user
            const userBalances = new Map(); // user -> { teaBalance, apeBalance }

            for (let j = 0; j < userBalanceMap.length; j++) {
                const { user, type } = userBalanceMap[j];
                const result = balanceResults[j];

                if (!result.success) continue;

                const balance = BigInt(result.returnData);

                if (!userBalances.has(user)) {
                    userBalances.set(user, {
                        teaBalance: BigInt(0),
                        apeBalance: BigInt(0)
                    });
                }

                if (type === "tea") {
                    userBalances.get(user).teaBalance = balance;
                } else {
                    userBalances.get(user).apeBalance = balance;
                }
            }

            // Process balances for this vault
            for (const [user, balances] of userBalances.entries()) {
                const teaBalance = balances.teaBalance;
                const apeBalance = balances.apeBalance;

                if (teaBalance > 0n || apeBalance > 0n) {
                    // Track TEA holders for unclaimed rewards calculation
                    if (teaBalance > 0n) {
                        if (!this.vaultTeaHolders.has(vaultId)) {
                            this.vaultTeaHolders.set(vaultId, new Set());
                        }
                        this.vaultTeaHolders.get(vaultId).add(user);
                    }
                    // Calculate SIR equity as proportional share of reserves
                    // TEA equity = (TEA balance / TEA total supply) * LP reserves
                    // APE equity = (APE balance / APE total supply) * Apes reserves
                    const teaEquity =
                        teaTotalSupply > 0n ? (teaBalance * reserves.reserveLPers) / teaTotalSupply : BigInt(0);
                    const apeEquity =
                        apeTotalSupply > 0n ? (apeBalance * reserves.reserveApes) / apeTotalSupply : BigInt(0);
                    const totalEquity = teaEquity + apeEquity;

                    const isContractAddr = await this.isContract(user);

                    // Skip if in manually ignored list
                    if (this.ignoredContracts.has(user.toLowerCase())) {
                        continue;
                    }

                    // If it's a contract (not manually ignored), add to review list
                    if (isContractAddr) {
                        const existing = this.contractsWithBalances.find((c) => c.address === user);
                        if (existing) {
                            if (!existing.vaultEquity) {
                                existing.vaultEquity = "0";
                            }
                            existing.vaultEquity = (BigInt(existing.vaultEquity) + totalEquity).toString();
                            existing.type += ", Vault Equity";
                        } else {
                            this.contractsWithBalances.push({
                                address: user,
                                vaultEquity: totalEquity.toString(),
                                type: "Vault Equity"
                            });
                        }
                    }

                    // Add to results (both EOAs and non-ignored contracts)
                    if (!this.results.balances[user]) {
                        this.results.balances[user] = {};
                    }

                    if (!this.results.balances[user].vaultEquity) {
                        this.results.balances[user].vaultEquity = {};
                    }

                    this.results.balances[user].vaultEquity[vaultId] = {
                        teaBalance: teaBalance.toString(),
                        apeBalance: apeBalance.toString(),
                        teaEquitySIR: teaEquity.toString(),
                        apeEquitySIR: apeEquity.toString()
                    };

                    totalVaultEquity = totalVaultEquity + totalEquity;
                }
            }
        }

        this.results.summary.totalVaultEquity = totalVaultEquity.toString();
        console.log(
            `Total vault equity: ${this.formatToSigFigs(ethers.formatUnits(totalVaultEquity, SIR_DECIMALS))} SIR`
        );
    }

    // 4. Get unclaimed SIR rewards
    async getUnclaimedRewards() {
        console.log("Fetching unclaimed rewards...");

        let totalUnclaimedLPer = BigInt(0);
        let totalUnclaimedContributor = BigInt(0);

        // Prepare multicall for unclaimed rewards
        const calls = [];
        const callMap = []; // Track which call corresponds to which user/vault

        // 1. Check LP rewards - only for TEA holders in each vault
        for (const [vaultId, teaHolders] of this.vaultTeaHolders.entries()) {
            for (const user of teaHolders) {
                calls.push({
                    target: ADDRESSES.VAULT,
                    callData: this.contracts.vault.interface.encodeFunctionData("unclaimedRewards", [vaultId, user])
                });
                callMap.push({ user, vaultId, type: "vault" });
            }
        }

        // 2. Check contributor rewards - only for addresses in contributor list
        for (const contributor of CONTRIBUTOR_ADDRESSES) {
            calls.push({
                target: ADDRESSES.SIR,
                callData: this.contracts.sir.interface.encodeFunctionData("contributorUnclaimedSIR", [contributor])
            });
            callMap.push({ user: contributor, type: "contributor" });
        }

        console.log(
            `Checking unclaimed rewards: ${this.vaultTeaHolders.size} vaults with TEA holders, ${CONTRIBUTOR_ADDRESSES.length} contributors...`
        );
        const results = await this.batchCall(calls);

        // Process results
        const userRewards = new Map(); // user -> { lperRewards, contributorRewards }

        for (let i = 0; i < callMap.length; i++) {
            const { user, vaultId, type } = callMap[i];
            const result = results[i];

            if (!result.success) continue;

            const amount = BigInt(result.returnData);

            if (amount === 0n) continue; // Skip zero amounts

            if (!userRewards.has(user)) {
                userRewards.set(user, {
                    lperRewards: BigInt(0),
                    contributorRewards: BigInt(0)
                });
            }

            if (type === "vault") {
                userRewards.get(user).lperRewards = userRewards.get(user).lperRewards + amount;
            } else if (type === "contributor") {
                userRewards.get(user).contributorRewards = amount;
            }
        }

        // Update balances with reward data
        for (const [user, rewards] of userRewards.entries()) {
            if (rewards.lperRewards > 0n || rewards.contributorRewards > 0n) {
                // Check if user is a contract
                const isContractAddr = await this.isContract(user);

                // Skip if in manually ignored list
                if (this.ignoredContracts.has(user.toLowerCase())) {
                    continue;
                }

                // If it's a contract (not manually ignored), add to review list
                if (isContractAddr) {
                    const existing = this.contractsWithBalances.find((c) => c.address === user);
                    if (existing) {
                        if (rewards.lperRewards > 0n) {
                            existing.unclaimedLperRewards = rewards.lperRewards.toString();
                        }
                        if (rewards.contributorRewards > 0n) {
                            existing.unclaimedContributorRewards = rewards.contributorRewards.toString();
                        }
                        existing.type += ", Unclaimed Rewards";
                    } else {
                        const contractData = {
                            address: user,
                            type: "Unclaimed Rewards"
                        };
                        if (rewards.lperRewards > 0n) {
                            contractData.unclaimedLperRewards = rewards.lperRewards.toString();
                        }
                        if (rewards.contributorRewards > 0n) {
                            contractData.unclaimedContributorRewards = rewards.contributorRewards.toString();
                        }
                        this.contractsWithBalances.push(contractData);
                    }
                }

                // Add to results (both EOAs and non-ignored contracts)
                if (!this.results.balances[user]) {
                    this.results.balances[user] = {};
                }

                if (rewards.lperRewards > 0n) {
                    this.results.balances[user].unclaimedLperRewards = rewards.lperRewards.toString();
                }
                if (rewards.contributorRewards > 0n) {
                    this.results.balances[user].unclaimedContributorRewards = rewards.contributorRewards.toString();
                }

                totalUnclaimedLPer = totalUnclaimedLPer + rewards.lperRewards;
                totalUnclaimedContributor = totalUnclaimedContributor + rewards.contributorRewards;
            }
        }

        this.results.summary.totalUnclaimedRewards = (totalUnclaimedLPer + totalUnclaimedContributor).toString();
        console.log(
            `Total unclaimed LP rewards: ${this.formatToSigFigs(
                ethers.formatUnits(totalUnclaimedLPer, SIR_DECIMALS)
            )} SIR`
        );
        console.log(
            `Total unclaimed contributor rewards: ${this.formatToSigFigs(
                ethers.formatUnits(totalUnclaimedContributor, SIR_DECIMALS)
            )} SIR`
        );
    }

    // 5. Calculate unissued contributor rewards (rewards that will accrue from NOW to end of 3-year period)
    async getUnissuedContributorRewards() {
        console.log("Calculating unissued contributor rewards...");

        if (!this.contracts.contributors) {
            console.log("Contributors contract not provided, skipping unissued rewards calculation");
            return;
        }

        const THREE_YEARS = 3 * 365 * 24 * 60 * 60;
        const timestampIssuanceEnd = Number(this.timestampIssuanceStart) + THREE_YEARS;
        const CONTRIBUTOR_ISSUANCE = BigInt(this.issuanceRate) - this.lpIssuanceFirst3Years;

        // If we're already past the issuance end, no unissued rewards
        if (this.results.timestamp >= timestampIssuanceEnd) {
            console.log("Snapshot time is past issuance end date, no unissued rewards");
            this.results.summary.totalContributorUnissued = "0";
            return;
        }

        const timeRemaining = timestampIssuanceEnd - this.results.timestamp;
        console.log(`Time remaining in issuance period: ${timeRemaining} seconds`);

        // Prepare multicall to get allocations
        const calls = CONTRIBUTOR_ADDRESSES.map((contributor) => ({
            target: ADDRESSES.CONTRIBUTORS,
            callData: this.contracts.contributors.interface.encodeFunctionData("allocations", [contributor])
        }));

        const results = await this.batchCall(calls);

        let totalUnissued = BigInt(0);

        // Process results
        for (let i = 0; i < CONTRIBUTOR_ADDRESSES.length; i++) {
            const contributor = CONTRIBUTOR_ADDRESSES[i];
            const result = results[i];

            if (!result.success) continue;

            const allocation = BigInt(result.returnData);

            if (allocation > 0n) {
                // Calculate issuance rate for this contributor
                const issuanceRate = (allocation * CONTRIBUTOR_ISSUANCE) / (BigInt(2) ** BigInt(56) - 1n);

                // Calculate unissued rewards from NOW to end of 3-year period
                const unissued = issuanceRate * BigInt(timeRemaining);

                if (unissued > 0n) {
                    // Check if contributor is a contract
                    const isContractAddr = await this.isContract(contributor);

                    // Skip if in manually ignored list
                    if (this.ignoredContracts.has(contributor.toLowerCase())) {
                        continue;
                    }

                    // If it's a contract (not manually ignored), add to review list
                    if (isContractAddr) {
                        const existing = this.contractsWithBalances.find((c) => c.address === contributor);
                        if (existing) {
                            existing.unissuedContributorRewards = unissued.toString();
                            existing.type += ", Unissued Contributor Rewards";
                        } else {
                            this.contractsWithBalances.push({
                                address: contributor,
                                unissuedContributorRewards: unissued.toString(),
                                type: "Unissued Contributor Rewards"
                            });
                        }
                    }

                    // Add to results (both EOAs and non-ignored contracts)
                    if (!this.results.balances[contributor]) {
                        this.results.balances[contributor] = {};
                    }
                    this.results.balances[contributor].unissuedContributorRewards = unissued.toString();
                    totalUnissued = totalUnissued + unissued;
                }
            }
        }

        this.results.summary.totalContributorUnissued = totalUnissued.toString();

        console.log(
            `Total unissued contributor rewards: ${this.formatToSigFigs(
                ethers.formatUnits(totalUnissued, SIR_DECIMALS)
            )} SIR`
        );
    }

    // 6. Get SIR equity in Uniswap V3
    async getUniswapV3Equity() {
        console.log("Fetching Uniswap V3 positions...");

        // Find all SIR/WETH pools
        const factoryContract = new ethers.Contract(
            ADDRESSES.UNISWAP_V3_FACTORY,
            ["function getPool(address, address, uint24) view returns (address)"],
            this.provider
        );

        const feeTiers = [100, 500, 3000, 10000];

        // Step 1: Get pool addresses for all fee tiers
        const poolCalls = feeTiers.map((fee) => ({
            target: ADDRESSES.UNISWAP_V3_FACTORY,
            callData: factoryContract.interface.encodeFunctionData("getPool", [ADDRESSES.SIR, ADDRESSES.WETH, fee])
        }));

        const poolResults = await this.batchCall(poolCalls);

        const sirPools = [];
        for (let i = 0; i < feeTiers.length; i++) {
            const result = poolResults[i];
            if (!result.success) {
                console.log(`  Fee tier ${feeTiers[i]}: call failed`);
                continue;
            }

            const poolAddress = ethers.getAddress("0x" + result.returnData.slice(-40));
            if (poolAddress !== ethers.ZeroAddress) {
                console.log(`  Fee tier ${feeTiers[i]}: found pool at ${poolAddress}`);
                sirPools.push({ address: poolAddress, fee: feeTiers[i] });
            } else {
                console.log(`  Fee tier ${feeTiers[i]}: no pool found`);
            }
        }

        console.log(`Found ${sirPools.length} SIR/WETH pools on Uniswap V3`);

        if (sirPools.length === 0) {
            this.results.summary.totalUniswapV3Equity = "0";
            return;
        }

        // Step 2: Query Mint events from SIR pools to find blocks where positions were created
        console.log("Finding blocks where SIR positions were created...");

        const POOL_ABI = [
            ...ABIS.UNISWAP_V3_POOL,
            "event Mint(address sender, address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)"
        ];

        const BLOCK_BATCH_SIZE = 10000;
        const positionCreationBlocks = new Set();
        let totalMintEvents = 0;

        for (const pool of sirPools) {
            const poolContract = new ethers.Contract(pool.address, POOL_ABI, this.provider);

            for (let fromBlock = START_BLOCK; fromBlock <= this.blockNumber; fromBlock += BLOCK_BATCH_SIZE) {
                const toBlock = Math.min(fromBlock + BLOCK_BATCH_SIZE - 1, this.blockNumber);
                const mintEvents = await poolContract.queryFilter(poolContract.filters.Mint(), fromBlock, toBlock);

                mintEvents.forEach((event) => {
                    positionCreationBlocks.add(event.blockNumber);
                });
                totalMintEvents += mintEvents.length;
            }
        }

        console.log(`  Found ${totalMintEvents} Mint events across ${positionCreationBlocks.size} unique blocks`);

        if (positionCreationBlocks.size === 0) {
            this.results.summary.totalUniswapV3Equity = "0";
            return;
        }

        // Step 3: Query IncreaseLiquidity events in those specific blocks to get tokenIds
        console.log("Fetching NFT tokenIds from IncreaseLiquidity events...");

        const nftManager = new ethers.Contract(ADDRESSES.UNISWAP_V3_NFT_MANAGER, ABIS.UNISWAP_V3_NFT, this.provider);

        const candidateTokenIds = new Set();
        const blocksArray = Array.from(positionCreationBlocks).sort((a, b) => a - b);

        console.log(`  Querying IncreaseLiquidity events in ${blocksArray.length} blocks...`);
        for (const blockNumber of blocksArray) {
            const events = await nftManager.queryFilter(
                nftManager.filters.IncreaseLiquidity(),
                blockNumber,
                blockNumber
            );

            events.forEach((event) => {
                candidateTokenIds.add(event.args.tokenId.toString());
            });
        }

        console.log(`  Found ${candidateTokenIds.size} candidate tokenIds from IncreaseLiquidity events`);

        if (candidateTokenIds.size === 0) {
            this.results.summary.totalUniswapV3Equity = "0";
            return;
        }

        // Step 4: Verify which tokenIds are SIR/WETH positions
        console.log("Verifying SIR/WETH positions...");

        const tokenIdsArray = Array.from(candidateTokenIds);
        const positionCalls = tokenIdsArray.map((tokenId) => ({
            target: ADDRESSES.UNISWAP_V3_NFT_MANAGER,
            callData: nftManager.interface.encodeFunctionData("positions", [tokenId])
        }));

        const positionResults = await this.batchCall(positionCalls);

        // Build a map of pool address -> pool info for quick lookup
        const poolMap = new Map();
        sirPools.forEach((pool) => {
            poolMap.set(pool.address.toLowerCase(), pool);
        });

        const verifiedSIRTokenIds = [];
        console.log(`  Checking ${tokenIdsArray.length} positions...`);
        for (let i = 0; i < tokenIdsArray.length; i++) {
            const result = positionResults[i];
            if (!result.success) {
                console.log(`    TokenId ${tokenIdsArray[i]}: call failed`);
                continue;
            }

            const position = nftManager.interface.decodeFunctionResult("positions", result.returnData);
            const { token0, token1, fee } = position;

            // Check if this position matches any SIR/WETH pool
            let matched = false;
            for (const pool of sirPools) {
                const poolContract = new ethers.Contract(pool.address, POOL_ABI, this.provider);
                const poolToken0 = await poolContract.token0({ blockTag: this.blockNumber });
                const poolToken1 = await poolContract.token1({ blockTag: this.blockNumber });

                if (
                    token0.toLowerCase() === poolToken0.toLowerCase() &&
                    token1.toLowerCase() === poolToken1.toLowerCase() &&
                    Number(fee) === pool.fee
                ) {
                    verifiedSIRTokenIds.push({
                        tokenId: tokenIdsArray[i],
                        pool: pool.address,
                        position
                    });
                    matched = true;
                    break;
                }
            }
        }

        console.log(`  Verified ${verifiedSIRTokenIds.length} positions belong to SIR/WETH pools`);

        if (verifiedSIRTokenIds.length === 0) {
            this.results.summary.totalUniswapV3Equity = "0";
            return;
        }

        // Step 5: Track current ownership for each tokenId
        console.log("Tracking NFT ownership...");

        for (const { tokenId, pool, position } of verifiedSIRTokenIds) {
            // Query Transfer events for this tokenId
            const transferEvents = await nftManager.queryFilter(
                nftManager.filters.Transfer(null, null, tokenId),
                START_BLOCK,
                this.blockNumber
            );

            // The last transfer determines current ownership
            let currentOwner = ethers.ZeroAddress;
            if (transferEvents.length > 0) {
                const lastTransfer = transferEvents[transferEvents.length - 1];
                currentOwner = lastTransfer.args.to;
            }

            // If owned by staking contract, get the actual depositor
            if (currentOwner.toLowerCase() === ADDRESSES.UNISWAP_V3_STAKING.toLowerCase()) {
                const stakingContract = new ethers.Contract(
                    ADDRESSES.UNISWAP_V3_STAKING,
                    ABIS.UNISWAP_V3_STAKING,
                    this.provider
                );

                try {
                    const deposit = await stakingContract.deposits(tokenId, { blockTag: this.blockNumber });
                    currentOwner = deposit.owner;
                } catch (e) {
                    console.log(`    Warning: Could not fetch staking deposit owner for tokenId ${tokenId}`);
                }
            }

            // Store in the map for later use by staking rewards calculation
            this.uniswapV3Positions.set(tokenId, currentOwner);
        }

        console.log(`  Tracked ownership for ${this.uniswapV3Positions.size} positions`);

        // Step 6: Calculate SIR holdings for each position
        console.log("Calculating SIR equity in positions...");

        let totalUniswapEquity = BigInt(0);
        let positionsProcessed = 0;

        for (const { tokenId, pool, position } of verifiedSIRTokenIds) {
            const currentOwner = this.uniswapV3Positions.get(tokenId);

            if (!currentOwner || currentOwner === ethers.ZeroAddress) {
                continue;
            }

            const { tickLower, tickUpper, liquidity } = position;

            if (liquidity === 0n) {
                continue;
            }

            // Get pool state
            const poolContract = new ethers.Contract(pool, POOL_ABI, this.provider);
            const slot0 = await poolContract.slot0({ blockTag: this.blockNumber });
            const currentTick = slot0.tick;
            const sqrtPriceX96 = slot0.sqrtPriceX96;

            // Determine which token is SIR
            const token0 = await poolContract.token0({ blockTag: this.blockNumber });
            const isSIRToken0 = token0.toLowerCase() === ADDRESSES.SIR.toLowerCase();

            // Calculate SIR amount in position
            let sirAmount = BigInt(0);

            const Q96 = BigInt(2) ** BigInt(96);

            if (currentTick >= tickLower && currentTick < tickUpper) {
                // Position is in range - has both tokens
                const sqrtRatioA = this._getSqrtRatioAtTick(tickLower);
                const sqrtRatioB = this._getSqrtRatioAtTick(tickUpper);

                if (isSIRToken0) {
                    // SIR is token0
                    // Formula: amount0 = liquidity * (sqrtB - sqrtP) * Q96 / (sqrtB * sqrtP)
                    const numerator = liquidity * (sqrtRatioB - sqrtPriceX96) * Q96;
                    const denominator = sqrtRatioB * sqrtPriceX96;
                    const amount0 = numerator / denominator;
                    sirAmount = amount0;
                } else {
                    // SIR is token1
                    // Formula: amount1 = liquidity * (sqrtP - sqrtA) / Q96
                    const amount1 = (liquidity * (sqrtPriceX96 - sqrtRatioA)) / Q96;
                    sirAmount = amount1;
                }
            } else if (currentTick < tickLower) {
                // Position is entirely in token0
                if (isSIRToken0) {
                    const sqrtRatioA = this._getSqrtRatioAtTick(tickLower);
                    const sqrtRatioB = this._getSqrtRatioAtTick(tickUpper);
                    // Formula: amount0 = liquidity * (sqrtB - sqrtA) * Q96 / (sqrtB * sqrtA)
                    const numerator = liquidity * (sqrtRatioB - sqrtRatioA) * Q96;
                    const denominator = sqrtRatioB * sqrtRatioA;
                    const amount0 = numerator / denominator;
                    sirAmount = amount0;
                }
            } else {
                // Position is entirely in token1
                if (!isSIRToken0) {
                    const sqrtRatioA = this._getSqrtRatioAtTick(tickLower);
                    const sqrtRatioB = this._getSqrtRatioAtTick(tickUpper);
                    // Formula: amount1 = liquidity * (sqrtB - sqrtA) / Q96
                    const amount1 = (liquidity * (sqrtRatioB - sqrtRatioA)) / Q96;
                    sirAmount = amount1;
                }
            }

            if (sirAmount > 0n) {
                const isContractAddr = await this.isContract(currentOwner);

                // Skip if in manually ignored list
                if (this.ignoredContracts.has(currentOwner.toLowerCase())) {
                    continue;
                }

                // If it's a contract (not manually ignored), add to review list
                if (isContractAddr) {
                    const existing = this.contractsWithBalances.find((c) => c.address === currentOwner);
                    if (existing) {
                        if (!existing.uniswapV3Equity) {
                            existing.uniswapV3Equity = "0";
                        }
                        existing.uniswapV3Equity = (BigInt(existing.uniswapV3Equity) + sirAmount).toString();
                        existing.type += ", Uniswap V3";
                    } else {
                        this.contractsWithBalances.push({
                            address: currentOwner,
                            uniswapV3Equity: sirAmount.toString(),
                            type: "Uniswap V3"
                        });
                    }
                }

                // Add to results (both EOAs and non-ignored contracts)
                if (!this.results.balances[currentOwner]) {
                    this.results.balances[currentOwner] = {};
                }
                if (!this.results.balances[currentOwner].uniswapV3Equity) {
                    this.results.balances[currentOwner].uniswapV3Equity = "0";
                }
                this.results.balances[currentOwner].uniswapV3Equity = (
                    BigInt(this.results.balances[currentOwner].uniswapV3Equity) + sirAmount
                ).toString();

                totalUniswapEquity = totalUniswapEquity + sirAmount;
                positionsProcessed++;
            }
        }

        console.log(
            `\nProcessed ${positionsProcessed} positions with SIR equity out of ${verifiedSIRTokenIds.length} verified positions`
        );

        this.results.summary.totalUniswapV3Equity = totalUniswapEquity.toString();
        console.log(
            `Total Uniswap V3 equity: ${this.formatToSigFigs(ethers.formatUnits(totalUniswapEquity, SIR_DECIMALS))} SIR`
        );
    }

    // Helper function to calculate sqrt ratio at tick
    // Implements Uniswap V3's getSqrtRatioAtTick formula
    _getSqrtRatioAtTick(tick) {
        // Convert to Number for bitwise operations
        const tickNum = typeof tick === "bigint" ? Number(tick) : tick;
        const absTick = tickNum < 0 ? -tickNum : tickNum;

        if (absTick > 887272) throw new Error("Tick out of bounds");

        let ratio = BigInt("0xfffcb933bd6fad37aa2d162d1a594001");

        if (absTick & 0x1) ratio = (ratio * BigInt("0xfff97272373d413259a46990580e213a")) >> 128n;
        if (absTick & 0x2) ratio = (ratio * BigInt("0xfff2e50f5f656932ef12357cf3c7fdcc")) >> 128n;
        if (absTick & 0x4) ratio = (ratio * BigInt("0xffe5caca7e10e4e61c3624eaa0941cd0")) >> 128n;
        if (absTick & 0x8) ratio = (ratio * BigInt("0xffcb9843d60f6159c9db58835c926644")) >> 128n;
        if (absTick & 0x10) ratio = (ratio * BigInt("0xff973b41fa98c081472e6896dfb254c0")) >> 128n;
        if (absTick & 0x20) ratio = (ratio * BigInt("0xff2ea16466c96a3843ec78b326b52861")) >> 128n;
        if (absTick & 0x40) ratio = (ratio * BigInt("0xfe5dee046a99a2a811c461f1969c3053")) >> 128n;
        if (absTick & 0x80) ratio = (ratio * BigInt("0xfcbe86c7900a88aedcffc83b479aa3a4")) >> 128n;
        if (absTick & 0x100) ratio = (ratio * BigInt("0xf987a7253ac413176f2b074cf7815e54")) >> 128n;
        if (absTick & 0x200) ratio = (ratio * BigInt("0xf3392b0822b70005940c7a398e4b70f3")) >> 128n;
        if (absTick & 0x400) ratio = (ratio * BigInt("0xe7159475a2c29b7443b29c7fa6e889d9")) >> 128n;
        if (absTick & 0x800) ratio = (ratio * BigInt("0xd097f3bdfd2022b8845ad8f792aa5825")) >> 128n;
        if (absTick & 0x1000) ratio = (ratio * BigInt("0xa9f746462d870fdf8a65dc1f90e061e5")) >> 128n;
        if (absTick & 0x2000) ratio = (ratio * BigInt("0x70d869a156d2a1b890bb3df62baf32f7")) >> 128n;
        if (absTick & 0x4000) ratio = (ratio * BigInt("0x31be135f97d08fd981231505542fcfa6")) >> 128n;
        if (absTick & 0x8000) ratio = (ratio * BigInt("0x9aa508b5b7a84e1c677de54f3e99bc9")) >> 128n;
        if (absTick & 0x10000) ratio = (ratio * BigInt("0x5d6af8dedb81196699c329225ee604")) >> 128n;
        if (absTick & 0x20000) ratio = (ratio * BigInt("0x2216e584f5fa1ea926041bedfe98")) >> 128n;
        if (absTick & 0x40000) ratio = (ratio * BigInt("0x48a170391f7dc42444e8fa2")) >> 128n;

        if (tickNum > 0) {
            ratio = ethers.MaxUint256 / ratio;
        }

        // Round up if remainder exists
        return ratio >> 32n;
    }

    // 7. Get uncollected Uniswap V3 LP fees (SIR only)
    async getUniswapV3UnclaimedFees() {
        console.log("Fetching uncollected Uniswap V3 LP fees...");

        // Check if we have any positions tracked
        if (this.uniswapV3Positions.size === 0) {
            console.log("No Uniswap V3 positions tracked, skipping unclaimed fees");
            this.results.summary.totalUniswapV3UnclaimedFees = "0";
            return;
        }

        const nftManager = new ethers.Contract(ADDRESSES.UNISWAP_V3_NFT_MANAGER, ABIS.UNISWAP_V3_NFT, this.provider);

        // Prepare multicall to get position data for all tracked positions
        const positionCalls = [];
        const tokenIds = Array.from(this.uniswapV3Positions.keys());

        for (const tokenId of tokenIds) {
            positionCalls.push({
                target: ADDRESSES.UNISWAP_V3_NFT_MANAGER,
                callData: nftManager.interface.encodeFunctionData("positions", [tokenId])
            });
        }

        console.log(`Checking ${tokenIds.length} positions for uncollected fees...`);

        // Execute multicall
        const positionResults = await this.batchCall(positionCalls);

        // Process results
        const ownerFees = new Map(); // owner -> total SIR fees
        let totalUnclaimedFees = BigInt(0);

        for (let i = 0; i < tokenIds.length; i++) {
            const tokenId = tokenIds[i];
            const owner = this.uniswapV3Positions.get(tokenId);
            const result = positionResults[i];

            if (!result.success) {
                console.log(`  Warning: Failed to fetch position data for tokenId ${tokenId}`);
                continue;
            }

            // Decode position data
            const position = nftManager.interface.decodeFunctionResult("positions", result.returnData);
            const token0 = position.token0;
            const token1 = position.token1;
            const tokensOwed0 = position.tokensOwed0;
            const tokensOwed1 = position.tokensOwed1;

            // Determine which token is SIR
            const isSIRToken0 = token0.toLowerCase() === ADDRESSES.SIR.toLowerCase();
            const isSIRToken1 = token1.toLowerCase() === ADDRESSES.SIR.toLowerCase();

            if (!isSIRToken0 && !isSIRToken1) {
                // This position doesn't involve SIR, skip
                continue;
            }

            // Get SIR fees
            const sirFees = isSIRToken0 ? tokensOwed0 : tokensOwed1;

            if (sirFees > 0n) {
                // Check if owner is a contract
                const isContractAddr = await this.isContract(owner);

                // Skip if in manually ignored list
                if (this.ignoredContracts.has(owner.toLowerCase())) {
                    continue;
                }

                // If it's a contract (not manually ignored), add to review list
                if (isContractAddr) {
                    const existing = this.contractsWithBalances.find((c) => c.address === owner);
                    if (existing) {
                        if (!existing.uniswapV3UnclaimedFees) {
                            existing.uniswapV3UnclaimedFees = "0";
                        }
                        existing.uniswapV3UnclaimedFees = (
                            BigInt(existing.uniswapV3UnclaimedFees) + sirFees
                        ).toString();
                        existing.type += ", Uniswap V3 Unclaimed Fees";
                    } else {
                        this.contractsWithBalances.push({
                            address: owner,
                            uniswapV3UnclaimedFees: sirFees.toString(),
                            type: "Uniswap V3 Unclaimed Fees"
                        });
                    }
                }

                // Add fees to owner (both EOAs and non-ignored contracts)
                if (!ownerFees.has(owner)) {
                    ownerFees.set(owner, BigInt(0));
                }
                ownerFees.set(owner, ownerFees.get(owner) + sirFees);
                totalUnclaimedFees = totalUnclaimedFees + sirFees;
            }
        }

        // Update balances with uncollected fees
        for (const [owner, totalFees] of ownerFees.entries()) {
            if (!this.results.balances[owner]) {
                this.results.balances[owner] = {};
            }

            this.results.balances[owner].uniswapV3UnclaimedFees = totalFees.toString();
        }

        this.results.summary.totalUniswapV3UnclaimedFees = totalUnclaimedFees.toString();
        console.log(
            `Total uncollected Uniswap V3 LP fees: ${ethers.formatUnits(totalUnclaimedFees, SIR_DECIMALS)} SIR`
        );
    }

    // 8. Get unclaimed SIR rewards from staked Uniswap V3 positions
    async getUniswapV3StakingRewards() {
        console.log("Fetching Uniswap V3 staking rewards...");

        // Check if we have any positions tracked
        if (this.uniswapV3Positions.size === 0) {
            console.log("No Uniswap V3 positions tracked, skipping staking rewards");
            this.results.summary.totalUniswapV3StakingRewards = "0";
            return;
        }

        // Get staking contract
        const stakingContract = new ethers.Contract(
            ADDRESSES.UNISWAP_V3_STAKING,
            ABIS.UNISWAP_V3_STAKING,
            this.provider
        );

        // Get IncentiveCreated events to find all SIR incentives
        const incentiveCreatedFilter = stakingContract.filters.IncentiveCreated(ADDRESSES.SIR);
        const incentiveCreatedEvents = await stakingContract.queryFilter(
            incentiveCreatedFilter,
            START_BLOCK,
            this.blockNumber
        );

        console.log(`Found ${incentiveCreatedEvents.length} SIR incentives created`);

        if (incentiveCreatedEvents.length === 0) {
            this.results.summary.totalUniswapV3StakingRewards = "0";
            return;
        }

        // Build map of incentiveId -> incentive params
        const incentiveParams = new Map();
        for (const event of incentiveCreatedEvents) {
            const { pool, startTime, endTime, reward } = event.args;

            // Create incentive key hash (same as contract does)
            // Uses standard ABI encoding (not packed) to match Uniswap V3 Staker
            const abiCoder = ethers.AbiCoder.defaultAbiCoder();
            const incentiveKey = ethers.keccak256(
                abiCoder.encode(
                    ["address", "address", "uint256", "uint256", "address"],
                    [ADDRESSES.SIR, pool, startTime, endTime, event.args.refundee]
                )
            );

            incentiveParams.set(incentiveKey, {
                pool,
                startTime,
                endTime,
                refundee: event.args.refundee,
                totalReward: reward
            });
        }

        // Get TokenStaked events filtered by SIR incentiveIds to find all tokenIds that have been staked
        const stakedEvents = [];
        for (const incentiveId of incentiveParams.keys()) {
            const stakedFilter = stakingContract.filters.TokenStaked(null, incentiveId);
            const events = await stakingContract.queryFilter(stakedFilter, START_BLOCK, this.blockNumber);
            stakedEvents.push(...events);
        }

        // Get unique tokenIds that have ever been staked in SIR incentives
        const stakedTokenIds = new Set();
        stakedEvents.forEach((event) => {
            stakedTokenIds.add(event.args.tokenId.toString());
        });

        // Get NFT manager for position info
        const nftManager = new ethers.Contract(ADDRESSES.UNISWAP_V3_NFT_MANAGER, ABIS.UNISWAP_V3_NFT, this.provider);

        // Prepare multicall to check current stake status for all tokenId + incentiveId combinations
        const stakeCalls = [];
        const stakeCallMap = [];

        // For each tokenId that has ever been staked, check each SIR incentive
        for (const tokenId of stakedTokenIds) {
            for (const incentiveId of incentiveParams.keys()) {
                // Query current stake status
                stakeCalls.push({
                    target: ADDRESSES.UNISWAP_V3_STAKING,
                    callData: stakingContract.interface.encodeFunctionData("stakes", [tokenId, incentiveId])
                });

                stakeCallMap.push({ tokenId, incentiveId });
            }
        }

        // Execute multicall to get stake status
        const multicall3 = new ethers.Contract(ADDRESSES.MULTICALL3, ABIS.MULTICALL3, this.provider);
        const stakeResults = await multicall3.aggregate3.staticCall(
            stakeCalls.map((call) => ({ target: call.target, allowFailure: true, callData: call.callData })),
            { blockTag: this.blockNumber }
        );

        // Filter to only currently staked positions (liquidity > 0)
        const positionCalls = [];
        const positionCallMap = [];
        let activeStakes = 0;

        for (let i = 0; i < stakeResults.length; i++) {
            const result = stakeResults[i];
            const { tokenId, incentiveId } = stakeCallMap[i];

            if (!result.success) {
                continue;
            }

            const stakeData = stakingContract.interface.decodeFunctionResult("stakes", result.returnData);
            const stakedLiquidity = stakeData.liquidity;

            // Only process if currently staked (liquidity > 0)
            if (stakedLiquidity > 0n) {
                activeStakes++;
                const incentive = incentiveParams.get(incentiveId);

                // Get owner from tracked positions or query the staking contract
                let owner = this.uniswapV3Positions.get(tokenId);
                if (!owner) {
                    // Query deposits to get owner
                    const deposit = await stakingContract.deposits(tokenId, { blockTag: this.blockNumber });
                    owner = deposit.owner;
                }

                // Get reward info from staking contract
                // Pass IncentiveKey as tuple
                const incentiveKey = [
                    ADDRESSES.SIR, // rewardToken
                    incentive.pool, // pool
                    incentive.startTime, // startTime
                    incentive.endTime, // endTime
                    incentive.refundee // refundee
                ];
                positionCalls.push({
                    target: ADDRESSES.UNISWAP_V3_STAKING,
                    callData: stakingContract.interface.encodeFunctionData("getRewardInfo", [incentiveKey, tokenId])
                });

                positionCallMap.push({ tokenId, owner, incentiveId, stakedLiquidity });
            }
        }

        if (positionCallMap.length === 0) {
            this.results.summary.totalUniswapV3StakingRewards = "0";
            return;
        }
        const rewardResults = await this.batchCall(positionCalls);

        // Process rewards for each position/incentive combo
        const ownerRewards = new Map();
        let totalStakingRewards = BigInt(0);

        for (let i = 0; i < positionCallMap.length; i++) {
            const { tokenId, owner, incentiveId, stakedLiquidity } = positionCallMap[i];
            const rewardResult = rewardResults[i];

            if (!rewardResult.success) continue;

            // Decode reward info from the contract
            const rewardInfo = stakingContract.interface.decodeFunctionResult("getRewardInfo", rewardResult.returnData);
            const reward = rewardInfo.reward;

            if (reward > 0n) {
                if (!ownerRewards.has(owner)) {
                    ownerRewards.set(owner, BigInt(0));
                }
                ownerRewards.set(owner, ownerRewards.get(owner) + reward);
            }
        }

        // Update balances with staking rewards
        for (const [owner, totalRewards] of ownerRewards.entries()) {
            if (!this.results.balances[owner]) {
                this.results.balances[owner] = {};
            }

            this.results.balances[owner].uniswapV3StakingRewards = totalRewards.toString();
            totalStakingRewards = totalStakingRewards + totalRewards;
        }

        this.results.summary.totalUniswapV3StakingRewards = totalStakingRewards.toString();
        console.log(`Total Uniswap V3 staking rewards: ${ethers.formatUnits(totalStakingRewards, SIR_DECIMALS)} SIR`);
    }

    // Display contracts with balances for user review
    displayContractsWithBalances() {
        if (this.contractsWithBalances.length === 0) {
            console.log("\nNo contracts with SIR balances found (excluding system contracts)");
            return;
        }

        console.log("\n=== CONTRACTS WITH SIR BALANCES (for review) ===");
        console.log("These contracts are included in the snapshot but you may want to exclude them.");
        console.log("Review each one and add to MANUALLY_IGNORED_CONTRACTS if needed.\n");

        for (const contract of this.contractsWithBalances) {
            console.log(`Address: ${contract.address}`);
            console.log(`Type: ${contract.type}`);

            // Display relevant balances
            if (contract.sirBalance) {
                console.log(`  SIR Balance: ${ethers.formatUnits(contract.sirBalance, SIR_DECIMALS)} SIR`);
            }
            if (contract.stakedSIR) {
                console.log(`  Staked SIR: ${ethers.formatUnits(contract.stakedSIR, SIR_DECIMALS)} SIR`);
            }
            if (contract.vaultEquity) {
                console.log(`  Vault Equity: ${ethers.formatUnits(contract.vaultEquity, SIR_DECIMALS)} SIR`);
            }
            if (contract.unclaimedLperRewards) {
                console.log(
                    `  Unclaimed LPer Rewards: ${ethers.formatUnits(contract.unclaimedLperRewards, SIR_DECIMALS)} SIR`
                );
            }
            if (contract.unclaimedContributorRewards) {
                console.log(
                    `  Unclaimed Contributor Rewards: ${ethers.formatUnits(
                        contract.unclaimedContributorRewards,
                        SIR_DECIMALS
                    )} SIR`
                );
            }
            if (contract.unissuedContributorRewards) {
                console.log(
                    `  Unissued Contributor Rewards: ${ethers.formatUnits(
                        contract.unissuedContributorRewards,
                        SIR_DECIMALS
                    )} SIR`
                );
            }
            if (contract.uniswapV3Equity) {
                console.log(`  Uniswap V3 Equity: ${ethers.formatUnits(contract.uniswapV3Equity, SIR_DECIMALS)} SIR`);
            }
            if (contract.uniswapV3UnclaimedFees) {
                console.log(
                    `  Uniswap V3 Unclaimed Fees: ${ethers.formatUnits(
                        contract.uniswapV3UnclaimedFees,
                        SIR_DECIMALS
                    )} SIR`
                );
            }
            console.log();
        }

        console.log(`Total: ${this.contractsWithBalances.length} contract(s) with balances\n`);
    }

    // Add contract flags to all addresses (using existing cache)
    async addContractFlags() {
        console.log("Adding contract flags...");

        const addresses = Object.keys(this.results.balances);

        // Use the existing cache populated during balance gathering
        for (const address of addresses) {
            // Check cache first, if not cached check now
            const isContract = this.contractCache.has(address)
                ? this.contractCache.get(address)
                : await this.isContract(address);

            this.results.balances[address].isContract = isContract;
        }

        console.log(`Contract flags added for ${addresses.length} addresses`);
    }

    // Main execution function
    async execute() {
        await this.initialize();

        await this.getSIRBalances();
        await this.getStakedSIRBalances();
        await this.getVaultEquity();
        await this.getUnclaimedRewards();
        await this.getUnissuedContributorRewards();
        await this.getUniswapV3Equity();
        await this.getUniswapV3UnclaimedFees();
        await this.getUniswapV3StakingRewards();

        // Add contract flags to all addresses
        await this.addContractFlags();

        // Display contracts with balances for user review
        this.displayContractsWithBalances();

        return this.results;
    }

    // Save results to file
    saveResults(filename = null) {
        if (!filename) {
            filename = `ethereum-snapshot-block-${this.blockNumber}.json`;
        }

        const outputPath = path.join(process.cwd(), "snapshots", filename);

        // Create directory if it doesn't exist
        if (!fs.existsSync(path.dirname(outputPath))) {
            fs.mkdirSync(path.dirname(outputPath), { recursive: true });
        }

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

    console.log(`Starting SIR balance snapshot at block ${blockNumber}...`);
    console.log(`Using Assistant contract at: ${ADDRESSES.ASSISTANT}`);
    console.log(`Loaded ${CONTRIBUTOR_ADDRESSES.length} contributor addresses`);

    const provider = new ethers.JsonRpcProvider(ALCHEMY_URL + ALCHEMY_KEY);

    const snapshot = new SIRBalanceSnapshot(provider, blockNumber);

    try {
        const results = await snapshot.execute();
        snapshot.saveResults();

        console.log("\n=== Snapshot Summary ===");
        console.log(`Block: ${results.blockNumber}`);
        console.log(`Timestamp: ${new Date(results.timestamp * 1000).toISOString()}`);
        console.log(
            `Total SIR Supply: ${snapshot.formatToSigFigs(
                ethers.formatUnits(results.summary.totalSIRSupply, SIR_DECIMALS)
            )} SIR`
        );
        console.log(
            `Total Staked: ${snapshot.formatToSigFigs(
                ethers.formatUnits(results.summary.totalStakedSIR, SIR_DECIMALS)
            )} SIR`
        );
        console.log(
            `Total Vault Equity: ${snapshot.formatToSigFigs(
                ethers.formatUnits(results.summary.totalVaultEquity, SIR_DECIMALS)
            )} SIR`
        );
        console.log(
            `Total Vault Unclaimed Rewards (LP + Contributor): ${snapshot.formatToSigFigs(
                ethers.formatUnits(results.summary.totalUnclaimedRewards, SIR_DECIMALS)
            )} SIR`
        );
        console.log(
            `Total Contributor Unissued Rewards: ${snapshot.formatToSigFigs(
                ethers.formatUnits(results.summary.totalContributorUnissued, SIR_DECIMALS)
            )} SIR`
        );
        console.log(
            `Total Uniswap V3 Equity (in positions): ${snapshot.formatToSigFigs(
                ethers.formatUnits(results.summary.totalUniswapV3Equity, SIR_DECIMALS)
            )} SIR`
        );
        console.log(
            `Total Uniswap V3 Unclaimed Fees: ${snapshot.formatToSigFigs(
                ethers.formatUnits(results.summary.totalUniswapV3UnclaimedFees, SIR_DECIMALS)
            )} SIR`
        );
        console.log(
            `Total Uniswap V3 Staking Rewards: ${snapshot.formatToSigFigs(
                ethers.formatUnits(results.summary.totalUniswapV3StakingRewards, SIR_DECIMALS)
            )} SIR`
        );
        console.log(`Total Addresses: ${Object.keys(results.balances).length}`);
    } catch (error) {
        console.error("Error during snapshot:", error);
        process.exit(1);
    }
}

// Run if executed directly
if (require.main === module) {
    main().catch(console.error);
}

module.exports = { SIRBalanceSnapshot, ADDRESSES, ABIS };
