require("dotenv").config();
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

// --- Configuration ---
const SNAPSHOT_BLOCK = 22157899;
const OUTPUT_FILE = path.join(__dirname, "../contributors/snapshot-allocations.json");
const SIR_ADDRESS = process.env.SIR_ADDRESS;
const VAULT_ADDRESS = process.env.VAULT_ADDRESS;
const ALCHEMY_KEY = process.env.ALCHEMY_KEY;
// Treasury override
const TREASURY_ADDRESS = process.env.TREASURY_ADDRESS.toLowerCase();

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
    "function stakeOf(address) view returns (uint80 unlocked, uint80 locked)"
];
const VAULT_ABI = [
    "function numberOfVaults() view returns (uint48)",
    "function unclaimedRewards(uint256, address) view returns (uint80)"
];

async function main() {
    // Setup provider & contracts
    const provider = new ethers.AlchemyProvider("mainnet", ALCHEMY_KEY);
    const sir = new ethers.Contract(SIR_ADDRESS, SIR_ABI, provider);
    const vault = new ethers.Contract(VAULT_ADDRESS, VAULT_ABI, provider);

    // Fetch vault count
    const vaultCountRaw = await vault.numberOfVaults({ blockTag: SNAPSHOT_BLOCK });
    const vaultCount = Number(vaultCountRaw);

    // 1) Gather holders via Transfer events
    console.log(`Fetching Transfer logs up to block ${SNAPSHOT_BLOCK}`);
    const logs = await sir.queryFilter(sir.filters.Transfer(), 0, SNAPSHOT_BLOCK);
    const holders = new Set();
    for (const log of logs) {
        const from = (log.args.from ?? log.args[0]).toLowerCase();
        const to = (log.args.to ?? log.args[1]).toLowerCase();
        if (from && from !== ethers.ZeroAddress) holders.add(from);
        if (to && to !== ethers.ZeroAddress) holders.add(to);
    }

    // 2) Snapshot balances and unclaimed amounts
    console.log(`Processing ${holders.size} holders across ${vaultCount} vaults`);
    const entries = [];
    for (const addr of holders) {
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

        entries.push({ addr, minted, unmintedLP, unmintedC, staked });
    }

    // 3) Safety: verify contributors have non-zero total
    for (const contrib of CONTRIBUTOR_ADDRESSES) {
        const rec = entries.find((e) => e.addr === contrib);
        const total = rec ? rec.minted + rec.unmintedLP + rec.unmintedC + rec.staked : 0n;
        if (total === 0n) console.warn(`Contributor ${contrib} has zero SIR at snapshot`);
    }

    // 4) Compute totals and allocations (12 decimals)
    const DECIMALS = 12n;
    const totalSupply3Y = 2015000000n * 10n ** DECIMALS * 3n;

    const output = entries.map((e) => {
        const totalEnt = e.minted + e.unmintedLP + e.unmintedC + e.staked;
        let alloc = Number((totalEnt * 10000n) / totalSupply3Y);
        if (e.addr === TREASURY_ADDRESS) alloc = 500;
        return {
            address: e.addr,
            minted_sir: e.minted.toString(),
            unminted_lp_sir: e.unmintedLP.toString(),
            unminted_contributor_sir: e.unmintedC.toString(),
            staked_sir: e.staked.toString(),
            total_entitled: totalEnt.toString(),
            allocation: alloc
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
