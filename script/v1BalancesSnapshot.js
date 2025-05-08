require("dotenv").config();
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

// --- Configuration ---
const SNAPSHOT_BLOCK = 22157899;
const OUTPUT_FILE = path.join(__dirname, "../contributors/snapshot-allocations.json");
const SIR_ADDRESS = "0x1278B112943Abc025a0DF081Ee42369414c3A834".toLowerCase();
const VAULT_ADDRESS = "0xB91AE2c8365FD45030abA84a4666C4dB074E53E7".toLowerCase();
const V2_POOL = "0xD213F59f057d32194592f22850f4f077405F9Bc1".toLowerCase();
const ALCHEMY_KEY = process.env.ALCHEMY_KEY;

// Import contributor data
const SPICE_PATH = path.join(__dirname, "../contributors/spice-contributors.json");
const FUNDRAISING_PATH = path.join(__dirname, "../contributors/usd-contributors.json");
const spiceContributors = JSON.parse(fs.readFileSync(SPICE_PATH, "utf8"));
const fundraisingData = JSON.parse(fs.readFileSync(FUNDRAISING_PATH, "utf8"));

// Contributor & presale addresses from Contributors.sol
const CONTRIBUTOR_ADDRESSES = new Set(
    [
        "0xAacc079965F0F9473BF4299d930eF639690a9792",
        "0xa485B739e99334f4B92B04da2122e2923a054688",
        "0x1C5EB68630cCd90C3152FB9Dee3a1C2A7201631D",
        "0x0e52b591Cbc9AB81c806F303DE8d9a3B0Dc4ea5C",
        "0xfdcc69463b0106888D1CA07CE118A64AdF9fe458",
        "0xF613cfD07af6D011fD671F98064214b5B2942CF",
        "0x3424cd7D170949636C300e62674a3DFB7706Fc35",
        "0xe59813A4a120288dbf42630C051e3921E5dAbCd8",
        "0x241F1A461Da47Ccd40B48c38340896A9948A4725",
        "0x6422D607CA13457589A1f2dbf0ec63d5Adf87BFB",
        "0xE19618C08F74b7e80278Ec14b63797419dACCDf8",
        "0xbe1E110f4A2fD54622CD516e86b29f619ad994bF",
        "0x30E14c4b4768F9B5F520a2F6214d2cCc21255fDa",
        "0x0C0aB132F5a8d0988e88997cb2604F494052BDEF",
        "0x8D2a097607da5E2E3d599c72EC50FD0704a4D37f",
        "0x78086Ad810f8F99A0B6c92a9A6c8857d3c665622",
        "0x18e17dd452Ef58F91E45fD20Eb2F839ac13AA648",
        "0xc4Ab0e3F12309f37A5cdf3A4b3B7C70A53eeBBa9",
        "0xFe202706E36F31aFBaf4b4543C2A8bBa4ddB2deE",
        "0x7DF76FDEedE91d3cB80e4a86158dD9f6D206c98E",
        "0xe4F047C5DEB2659f3659057fe5cAFB5bC6bD4307",
        "0x26610e89A8B825F23E89e58879cE97D791aD4438",
        "0x32cf4d1df6fb7bB173183CF8b51EF9499c803634",
        "0x8D677d312F2CA04dF98eB22ce886bE8E7804280d",
        "0x40FEfD52714f298b9EaD6760753aAA720438D4bB",
        "0x16fD74300dcDc02E9b1E594f293c6EfFB299a3fc",
        "0xa233f74638Bd28A24CC2Ce23475eea7dC76881AC",
        "0xA6f4fa9840Aa6825446c820aF6d5eCcf9f78BA05",
        "0xa1a841D79758Bd4b06c9206e97343dFeBcBE200b",
        "0xEdA726014938d2E6Ed51c7d5A53193cf9713cdF7",
        "0x65665e10EB86D72b02067863342277EA2DF78516",
        "0xd11f322ad85730Eab11ef61eE9100feE84b63739",
        "0xdF58360e945F6a302FFFB012D114C9e2bE2F212a",
        "0x65a831D9fB2CC87A7956eB8E4720956f6bfC6eeA",
        "0xBA5EDc0d2Ae493C9574328d77dc36eEF19F699e2",
        "0x1ff241abaD54DEcB967Bd0f57c2a584C7d1ca8BD",
        "0x36D11126eBc59cb962AE8ddD3bcD0741b4e337Dc",
        "0x81B55FBe66C5FFbb8468328E924AF96a84438F14",
        "0x686748764c5C7Aa06FEc784E60D14b650bF79129",
        "0x07bfeB5488ad97aA3920cf241E59d2A817054eA3",
        "0xC3632CD03BEd246719965bB74279af79bE4bd813",
        "0xb1f55485d7ebA772F0d454Ceb0EA9a27586Ad86f",
        "0xC58D3aE892A104D663B01194f2EE325CfB5187f2",
        "0x0D5f69C67DAE06ce606246A8bd88B552d1DdE140",
        "0xde3697dDA384ce178d04D8879F7a66423F72A326",
        "0x79C1134a1dFdF7e0d58E58caFC84a514991372e6"
    ].map((a) => a.toLowerCase())
);

// ABIs
const SIR_ABI = [
    "event Transfer(address indexed from, address indexed to, uint256 amount)",
    "function balanceOf(address) view returns (uint256)",
    "function contributorUnclaimedSIR(address) view returns (uint80)",
    "function stakeOf(address) view returns (uint80 unlocked, uint80 locked)",
    "function ISSUANCE_RATE() view returns (uint72)"
];
const VAULT_ABI = [
    "function numberOfVaults() view returns (uint48)",
    "function unclaimedRewards(uint256, address) view returns (uint80)",
    "function TIMESTAMP_ISSUANCE_START() view returns (uint40)"
];

const UNI_V2_ABI = [
    "function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)",
    "function totalSupply() view returns (uint256)",
    "function balanceOf(address owner) view returns (uint256)",
    "function token0() view returns (address)",
    "function token1() view returns (address)"
];

async function main() {
    // Setup provider & contracts
    const provider = new ethers.AlchemyProvider("mainnet", ALCHEMY_KEY);
    const sir = new ethers.Contract(SIR_ADDRESS, SIR_ABI, provider);
    const vault = new ethers.Contract(VAULT_ADDRESS, VAULT_ABI, provider);
    const uniV2 = new ethers.Contract(V2_POOL, UNI_V2_ABI, provider);

    // Fetch vault count
    const vaultCountRaw = await vault.numberOfVaults({ blockTag: SNAPSHOT_BLOCK });
    const vaultCount = Number(vaultCountRaw);

    // Time stamps and issuance rate
    const tsIssuanceStart = await vault.TIMESTAMP_ISSUANCE_START();
    const block = await provider.getBlock(SNAPSHOT_BLOCK);
    const tsSnapshot = block.timestamp;
    const issuance = await sir.ISSUANCE_RATE();

    // Fetch Uniswap v2 reserves
    const [r0, r1] = await uniV2.getReserves({ blockTag: SNAPSHOT_BLOCK });
    const totalSupplyV2 = await uniV2.totalSupply({ blockTag: SNAPSHOT_BLOCK });
    const token0 = (await uniV2.token0()).toLowerCase();
    const token1 = (await uniV2.token1()).toLowerCase();
    const reserveSIR_V2 = token0 === SIR_ADDRESS ? r0 : token1 === SIR_ADDRESS ? r1 : 0;

    // 1) Gather holders via Transfer events
    console.log(`Fetching Transfer logs up to block ${SNAPSHOT_BLOCK}`);
    const logs = await sir.queryFilter(sir.filters.Transfer(), 0, SNAPSHOT_BLOCK);
    const holders = new Set();
    for (const log of logs) {
        const from = (log.args.from ?? log.args[0]).toLowerCase();
        const to = (log.args.to ?? log.args[1]).toLowerCase();
        if (from && from !== ethers.ZeroAddress && from !== SIR_ADDRESS && from !== VAULT_ADDRESS) holders.add(from);
        if (to && to !== ethers.ZeroAddress && to !== SIR_ADDRESS && to !== VAULT_ADDRESS) holders.add(to);
    }

    // 2) Snapshot balances and unclaimed amounts
    console.log(`Processing ${holders.size} holders across ${vaultCount} vaults`);
    const entries = [];
    for (const addr of holders) {
        process.stdout.write(`\r${entries.length} holders processed`);
        process.stdout.cursorTo(0);

        // on-chain balance is a bigint under ethers v6
        const minted = await sir.balanceOf(addr, { blockTag: SNAPSHOT_BLOCK }); // bigint

        // unminted contributor SIR
        let unmintedC = 0n;
        if (CONTRIBUTOR_ADDRESSES.has(addr)) {
            unmintedC = await sir.contributorUnclaimedSIR(addr, { blockTag: SNAPSHOT_BLOCK });
        }

        // unminted LP SIR across vaults
        let unmintedLP = 0n;
        for (let vid = 1; vid <= vaultCount; vid++) {
            try {
                const u = await vault.unclaimedRewards(vid, addr, { blockTag: SNAPSHOT_BLOCK });
                unmintedLP += u; // bigint addition
            } catch {
                // skip if vault id invalid or no rewards
            }
        }

        // staked SIR (unlocked + locked)
        const [unlocked, locked] = await sir.stakeOf(addr, { blockTag: SNAPSHOT_BLOCK });
        const staked = unlocked + locked;

        // SIR from Uniswap v2
        const userLPbalance = await uniV2.balanceOf(addr, { blockTag: SNAPSHOT_BLOCK });
        const sirFromV2 = (userLPbalance * reserveSIR_V2) / totalSupplyV2;

        entries.push({ addr, minted, unmintedLP, unmintedC, staked, sirFromV2 });

        if (entries.length === 3) break;
    }

    const threeYearsInSeconds = 3n * 365n * 24n * 60n * 60n;
    const totalSupply3Y = issuance * threeYearsInSeconds; // 3 years of issuance

    // 3) Safety: verify contributors have non-zero total
    for (const contrib of CONTRIBUTOR_ADDRESSES) {
        const rec = entries.find((e) => e.addr === contrib);

        // TEST
        if (rec === undefined) continue;
        // TEST

        if (rec.unmintedC === 0n) console.warn(`Contributor ${contrib} has no pending SIR to mint`);

        // Add unminted contributor SIR
        let contribData = spiceContributors.find((c) => c.address.toLowerCase() === contrib);
        const allocationSpice = contribData ? 1_000_000_000_000_000n * BigInt(contribData.allocation) : 0n;
        contribData = fundraisingData.contributors.find((c) => c.address.toLowerCase() === contrib);
        const allocationUsd = contribData ? BigInt(contribData.allocationPrecision) : 0n;
        rec.allocationOld = (allocationSpice + allocationUsd) / 1_000_000_000_000_000n;

        const unmintedRemainingC =
            (BigInt(issuance) *
                (BigInt(tsIssuanceStart) + threeYearsInSeconds - BigInt(tsSnapshot)) *
                (allocationSpice + allocationUsd)) /
            10_000_000_000_000_000_000n;
        rec.unmintedC += unmintedRemainingC;
    }

    // 4) Compute totals and allocations (12 decimals)

    const output = entries.map((e) => {
        const totalEnt = e.minted + e.unmintedLP + e.unmintedC + e.staked + (e.sirFromV2 || 0n);
        let allocation = Number((totalEnt * 10_000n) / totalSupply3Y);
        let allocationPrecision = Number((totalEnt * 10_000_000_000_000_000_000n) / totalSupply3Y);
        if (e.addr === "0x686748764c5C7Aa06FEc784E60D14b650bF79129".toLowerCase()) {
            // Treasury will get a fixed allocation
            allocation = 1_000;
            allocationPrecision = 1_000_000_000_000_000_000;
        } else if (e.addr === "0x5000ff6cc1864690d947b864b9fb0d603e8d1f1a".toLowerCase()) {
            // We do not reimburse ourselses
            allocation = 0;
            allocationPrecision = 0;
        }

        return {
            address: e.addr,
            minted_sir: Number(e.minted / BigInt(1e12)),
            unminted_lp_sir: Number(e.unmintedLP / BigInt(1e12)),
            unminted_contributor_sir: Number(e.unmintedC / BigInt(1e12)),
            staked_sir: Number(e.staked / BigInt(1e12)),
            uniswapV2_sir: Number(e.sirFromV2 / BigInt(1e12)),
            total_entitled: Number(totalEnt / BigInt(1e12)),
            allocationOld: e.allocationOld === undefined ? 0 : Number(e.allocationOld),
            allocation,
            allocationPrecision
        };
    });

    // 5) Write JSON
    fs.writeFileSync(OUTPUT_FILE, JSON.stringify(output, null, 2));
    console.log(`Wrote allocations to ${OUTPUT_FILE}`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
