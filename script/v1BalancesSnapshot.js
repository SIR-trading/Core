/**
 * MISSING: SENDERS OR RECEIVERS OF UNI V2 AND V3 POSITIONS
 */

require("dotenv").config();
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

// --- Configuration ---
const DEPLOYMENT_BLOCK = 21888475;
const SNAPSHOT_BLOCK = 22157899;
const OUTPUT_FILE = path.join(__dirname, "../contributors/posthack-compensations.json");

// Important addresses
const SIR_ADDRESS = ethers.getAddress("0x1278B112943Abc025a0DF081Ee42369414c3A834");
const VAULT_ADDRESS = ethers.getAddress("0xB91AE2c8365FD45030abA84a4666C4dB074E53E7");
const V2_POOL = ethers.getAddress("0xD213F59f057d32194592f22850f4f077405F9Bc1");
const V3_NFPM_ADDRESS = ethers.getAddress("0xC36442b4a4522E871399CD717aBDD847Ab11FE88");
const ALCHEMY_KEY = process.env.ALCHEMY_KEY;

// Load JSONs and normalize addresses
const prehackContributorsPath = path.join(__dirname, "../contributors/prehack-contributors.json");
const prehackPresalePath = path.join(__dirname, "../contributors/prehack-presale.json");
const prehackContributors = JSON.parse(fs.readFileSync(prehackContributorsPath, "utf8")).map((c) => ({
    ...c,
    address: ethers.getAddress(c.address)
}));
const prehackPresale = JSON.parse(fs.readFileSync(prehackPresalePath, "utf8"));
prehackPresale.contributors = prehackPresale.contributors.map((c) => ({
    ...c,
    address: ethers.getAddress(c.address)
}));

// Hard-coded contributor set from Contributors.sol
const CONTRIBUTOR_ADDRESSES = new Set(
    [
        "0xAacc079965F0F9473BF4299d930eF639690a9792",
        "0xa485B739e99334f4B92B04da2122e2923a054688",
        "0x1C5EB68630cCd90C3152FB9Dee3a1C2A7201631D",
        "0x0e52b591Cbc9AB81c806F303DE8d9a3B0Dc4ea5C",
        "0xfdcc69463b0106888D1CA07CE118A64AdF9fe458",
        "0xF613cfD07af6D011fD671F98064214aB5B2942CF",
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
    ].map((addr) => ethers.getAddress(addr))
);

const addressesToIgnore = [
    "0x5000Ff6Cc1864690d947B864B9FB0d603E8d1F1A", // We do not reimburse our team play account
    "0x000000000004444c5dc75cB358380D2e3dE08A90", // Ignore Uniswap v4 pool manager
    "0x000000fee13a103A10D593b9AE06b3e05F2E7E1c", // Ignore Uniswap fee collector
    "0x00700052c0608F670705380a4900e0a8080010CC", // Ignore Paraswap augustus fee vault
    "0x9008D19f58AAbD9eD0D60971565AA8510560ab41", // Ignore CoW Protocol fees
    "0xad3b67BCA8935Cb510C8D18bD45F0b94F54A968f", // Ignore 1inch
    "0xB6E981f235F70bDa631122DF1ee8303D7566AB62", // Ignore Uniswap v3 pool
    V2_POOL // Ignore Uniswap v2 pool
].map((addr) => ethers.getAddress(addr));

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
    "function TIMESTAMP_ISSUANCE_START() view returns (uint40)",
    "function paramsById(uint48 vaultId) external view returns ((address debtToken, address collateralToken, int8 leverageTier))",
    "event VaultInitialized(address indexed debtToken, address indexed collateralToken, int8 indexed leverageTier, uint256 vaultId, address ape)",
    "function balanceOf(address account, uint256 vaultId) external view returns (uint256)",
    "function mint(bool isAPE, (address debtToken, address collateralToken, int8 leverageTier) vaultParams, uint256 amountToDeposit, uint144 collateralToDepositMin) external returns (uint256 amount)",
    "function burn(bool isAPE, (address debtToken, address collateralToken, int8 leverageTier) vaultParams, uint256 amount) external returns (uint144)"
];

const UNI_V2_ABI = [
    "function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32)",
    "function totalSupply() view returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
    "function token0() view returns (address)",
    "function token1() view returns (address)",
    "event Transfer(address indexed from, address indexed to, uint256 value)"
];

const NFPM_ABI = [
    "function positions(uint256) external view returns (uint96 nonce, address operator, " +
        "address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity, " +
        "uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1)",
    "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
    "function decreaseLiquidity((uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min, uint256 deadline)) external payable returns (uint256 amount0, uint256 amount1)",
    "function collect((uint256 tokenId, address recipient, uint128 amount0Max, uint128 amount1Max)) external payable returns (uint256 amount0, uint256 amount1)",
    "function burn(uint256 tokenId) external payable",
    "function multicall(bytes[] calldata data) external payable returns (bytes[] memory results)"
];

const MaxUint128 = BigInt(2) ** BigInt(128) - 1n;

async function main() {
    const provider = new ethers.JsonRpcProvider(`https://eth-mainnet.alchemyapi.io/v2/${ALCHEMY_KEY}`);

    // ——————— Retry‐wrapper for ANY eth_call / eth_getLogs / etc ———————
    const originalSend = provider.send.bind(provider);
    provider.send = async (method, params) => {
        const maxRetries = 5;
        for (let i = 0; i < maxRetries; i++) {
            try {
                return await originalSend(method, params);
            } catch (err) {
                const code = err.info?.error?.code ?? err.status;
                if (code === 429 && i < maxRetries - 1) {
                    const backoff = (i + 1) * 1000;
                    // console.warn(`Rate-limited on ${method}, retrying in ${backoff}ms…`);
                    await new Promise((r) => setTimeout(r, backoff));
                    continue;
                }
                throw err;
            }
        }
    };

    const sir = new ethers.Contract(SIR_ADDRESS, SIR_ABI, provider);
    const vault = new ethers.Contract(VAULT_ADDRESS, VAULT_ABI, provider);
    const uniV2 = new ethers.Contract(V2_POOL, UNI_V2_ABI, provider);
    const nfpm = new ethers.Contract(V3_NFPM_ADDRESS, NFPM_ABI, provider);

    console.log(`There are ${CONTRIBUTOR_ADDRESSES.size} contributors.`);
    if (!Array.from(CONTRIBUTOR_ADDRESSES).every((a) => ethers.isAddress(a))) {
        throw new Error("Some contributors are not addresses.");
    }

    // a helper that pages through the full range in slices of `STEP` blocks
    async function fetchAllEvents(contract, filter, fromBlock, toBlock, step = 10_000) {
        let allEvents = [];

        for (let start = fromBlock; start <= toBlock; start += step) {
            const end = Math.min(start + step - 1, toBlock);
            // console.log(`Fetching ${filter.eventFragment.name} events from blocks ${start} to ${end}…`);
            const events = await contract.queryFilter(filter, start, end);
            allEvents = allEvents.concat(events);
        }

        return allEvents;
    }

    // 1) Vault + issuance info
    // Pull all events from genesis through your snapshot block
    const initEvents = await vault.queryFilter(
        vault.filters.VaultInitialized(), // no args ⇒ all vaults
        DEPLOYMENT_BLOCK,
        SNAPSHOT_BLOCK
    );
    const vaultCountRaw = await vault.numberOfVaults({ blockTag: SNAPSHOT_BLOCK });
    const vaultParamsArray = [];
    for (let i = 1; i <= vaultCountRaw; i++) {
        const { debtToken, collateralToken, leverageTier } = await vault.paramsById(i);
        const apeToken = new ethers.Contract(
            initEvents[i - 1].args.ape,
            [
                "function balanceOf(address) view returns (uint256)",
                "event Transfer(address indexed from, address indexed to, uint256 value)"
            ],
            provider
        );
        const collateralSymbol = await new ethers.Contract(
            collateralToken,
            ["function symbol() view returns (string)"],
            provider
        ).symbol();
        vaultParamsArray.push({
            debtToken,
            collateralToken,
            leverageTier,
            apeToken,
            collateralTokenSymbol: collateralSymbol.toLowerCase()
        });
    }
    const vaultCount = Number(vaultCountRaw);
    const tsIssuanceStart = await vault.TIMESTAMP_ISSUANCE_START();
    const blockInfo = await provider.getBlock(SNAPSHOT_BLOCK);
    const tsSnapshot = blockInfo.timestamp;
    const issuance = await sir.ISSUANCE_RATE();

    // helper to fetch prices by symbol at a given UNIX timestamp
    async function fetchPrices(symbol) {
        const startTime = new Date(tsSnapshot * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
        const endTime = new Date((tsSnapshot + 100000) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
        const res = await fetch(`https://api.g.alchemy.com/prices/v1/${ALCHEMY_KEY}/tokens/historical`, {
            method: "POST",
            headers: {
                "Content-Type": "application/json"
            },
            body: JSON.stringify({
                symbol,
                startTime,
                endTime
            })
        });
        if (!res.ok) throw new Error(`Prices API error: ${res.statusText}`);
        const { data } = await res.json();
        return Number(data[0].value);
    }

    // 2) build V3‐positions map
    console.log("Fetching V3 NFT Transfer events…");
    let rawV3Events = await fetchAllEvents(
        nfpm,
        nfpm.filters.Transfer(null, null, null),
        DEPLOYMENT_BLOCK,
        SNAPSHOT_BLOCK,
        10_000
    );
    console.log(`Fetched ${rawV3Events.length} Uniswap V3 NFT Transfer events.`);

    // 2a) dedupe tokenIds
    const tokenIdStrings = Array.from(new Set(rawV3Events.map((ev) => ev.args.tokenId.toString())));

    // 2b) fetch positions *once* per unique tokenId, in parallel (or via BatchProvider)
    const positionPromises = tokenIdStrings.map(
        (id) =>
            nfpm
                .positions(id, { blockTag: SNAPSHOT_BLOCK })
                .then((pos) => ({ id, pos }))
                .catch(() => null) // skip burned or invalid IDs
    );
    const positionsArr = await Promise.all(positionPromises);

    // 2c) build a lookup map, and filter down to only SIR‐pool positions
    const posMap = {};
    for (const entry of positionsArr) {
        if (!entry) continue;
        const { id, pos } = entry;
        const t0 = ethers.getAddress(pos.token0);
        const t1 = ethers.getAddress(pos.token1);
        if (t0 === SIR_ADDRESS || t1 === SIR_ADDRESS) {
            posMap[id] = pos;
        }
    }
    const sirTokenIds = new Set(Object.keys(posMap));
    console.log(`Found ${sirTokenIds.size} unique V3 positions for our SIR pools.`);

    // 2d) now filter your raw events down to just those tokenIds
    const v3TransferEvents = rawV3Events.filter((ev) => sirTokenIds.has(ev.args.tokenId.toString()));
    console.log(`Filtered down to ${v3TransferEvents.length} V3 Transfer events across SIR pools.`);

    // 2e) build your v3Positions exactly as before, but now you never call `positions()` again:
    const v3Positions = {};
    for (const ev of v3TransferEvents) {
        const from = ethers.getAddress(ev.args.from);
        const to = ethers.getAddress(ev.args.to);
        const id = ev.args.tokenId.toString();
        if (from !== ethers.ZeroAddress) {
            v3Positions[from] = v3Positions[from] || new Set();
            v3Positions[from].delete(id);
        }
        if (to !== ethers.ZeroAddress) {
            v3Positions[to] = v3Positions[to] || new Set();
            v3Positions[to].add(id);
        }
    }
    for (const addr of Object.keys(v3Positions)) {
        v3Positions[addr] = Array.from(v3Positions[addr]);
    }

    // 3) Uniswap V2 reserves
    const [r0, r1] = await uniV2.getReserves({ blockTag: SNAPSHOT_BLOCK });
    const totalSupplyV2 = await uniV2.totalSupply({ blockTag: SNAPSHOT_BLOCK });
    const token0 = ethers.getAddress(await uniV2.token0());
    const token1 = ethers.getAddress(await uniV2.token1());
    const [reserveSIR_V2, reserveETH_V2] =
        token0 === SIR_ADDRESS ? [r0, r1] : token1 === SIR_ADDRESS ? [r1, r0] : [0n, 0n];

    // helper to simulate V3 and V4 withdrawal via read‐only multicall
    async function simulateWithdrawV3(tokenId) {
        const iface = nfpm.interface;

        let liquidity;
        try {
            // 1) read current position info
            const pos = await nfpm.positions(tokenId, { blockTag: SNAPSHOT_BLOCK });
            liquidity = BigInt(pos.liquidity);
            if (liquidity === 0n) return { sirAmt: 0n, ethAmt: 0n };

            // 2) build the calldata for decreaseLiquidity
            const decData = iface.encodeFunctionData("decreaseLiquidity", [
                {
                    tokenId,
                    liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: ethers.MaxUint256
                }
            ]);

            // 3) build the calldata for collect
            const colData = iface.encodeFunctionData("collect", [
                {
                    tokenId,
                    recipient: ethers.ZeroAddress,
                    amount0Max: MaxUint128,
                    amount1Max: MaxUint128
                }
            ]);

            // 4) multicall them in one eth_call
            const multiData = iface.encodeFunctionData("multicall", [[decData, colData]]);
            const ret = await provider.call(
                {
                    to: V3_NFPM_ADDRESS,
                    data: multiData
                },
                SNAPSHOT_BLOCK
            );

            // 5) decode the multicall return
            const [results] = iface.decodeFunctionResult("multicall", ret);
            // results is an array: [ bytes(return of decreaseLiquidity), bytes(return of collect) ]

            // 6) decode the collect return
            //    decreaseLiquidity returns (uint256 amount0, uint256 amount1)
            //    collect returns     (uint256 amount0, uint256 amount1)
            const collectReturn = iface.decodeFunctionResult("collect", results[1]);
            const [amount0, amount1] = collectReturn;

            // 7) split both sides
            const [sirAmt, ethAmt] =
                ethers.getAddress(pos.token0) === SIR_ADDRESS ? [amount0, amount1] : [amount1, amount0];
            return { sirAmt, ethAmt };
        } catch {
            // console.log(`Failed to simulate withdraw for token ${tokenId} with liquidity ${liquidity}.`);
            return { sirAmt: 0n, ethAmt: 0n };
        }
    }

    // 4) Gather all holders
    console.log(`Fetching SIR Transfer logs up to block ${SNAPSHOT_BLOCK}`);
    const logs = await sir.queryFilter(sir.filters.Transfer(), DEPLOYMENT_BLOCK, SNAPSHOT_BLOCK);
    console.log(`Found ${logs.length} SIR Transfer events.`);

    // Include any TEA (ERC-1155) transfers from the vault itself:
    console.log("Fetching TEA (ERC-1155) TransferSingle logs…");
    const ERC1155_ABI = [
        "event TransferSingle(address indexed operator,address indexed from,address indexed to,uint256 id,uint256 value)"
    ];
    const erc1155 = new ethers.Contract(VAULT_ADDRESS, ERC1155_ABI, provider);
    const teaEvents = await fetchAllEvents(
        erc1155,
        erc1155.filters.TransferSingle(null, null, null),
        DEPLOYMENT_BLOCK,
        SNAPSHOT_BLOCK,
        10_000,
        erc1155.filters.TransferSingle()
    );
    console.log(`Found ${teaEvents.length} TEA TransferSingle events.`);

    // Include any APE (ERC-20) transfers on each vault’s apeToken:
    console.log(`Fetching APE (ERC-20) Transfer log from ${vaultParamsArray.length} vaults…`);
    let apeEvents = [];
    for (const { apeToken } of vaultParamsArray) {
        console.log(`Fetching APE events for vault ${apeToken.target}…`);
        const events = await fetchAllEvents(
            apeToken,
            apeToken.filters.Transfer(null, null),
            DEPLOYMENT_BLOCK,
            SNAPSHOT_BLOCK,
            10_000
        );
        apeEvents.push(...events);

        // optional small pause to give Alchemy breathing room
        await new Promise((r) => setTimeout(r, 200));
    }
    console.log(`Found ${apeEvents.length} APE Transfer events.`);

    console.log("Fetching Uniswap V2 LP-token Transfer logs…");
    const v2TransferEvents = await fetchAllEvents(
        uniV2,
        uniV2.filters.Transfer(null, null),
        DEPLOYMENT_BLOCK,
        SNAPSHOT_BLOCK,
        10_000
    );
    console.log(`Found ${v2TransferEvents.length} V2 LP-token Transfer events.`);

    let holders = new Set(CONTRIBUTOR_ADDRESSES);
    // Add SIR senders/receivers
    for (const lg of logs) {
        const from = ethers.getAddress(lg.args.from);
        const to = ethers.getAddress(lg.args.to);
        if (from !== ethers.ZeroAddress && from !== SIR_ADDRESS && from !== VAULT_ADDRESS) holders.add(from);
        if (to !== ethers.ZeroAddress && to !== SIR_ADDRESS && to !== VAULT_ADDRESS) holders.add(to);
    }

    // Add TEA senders/receivers
    for (const ev of teaEvents) {
        const from = ethers.getAddress(ev.args.from);
        const to = ethers.getAddress(ev.args.to);
        if (from !== ethers.ZeroAddress && from !== SIR_ADDRESS && from !== VAULT_ADDRESS) holders.add(from);
        if (to !== ethers.ZeroAddress && to !== SIR_ADDRESS && to !== VAULT_ADDRESS) holders.add(to);
    }

    // Add APE senders/receivers
    for (const ev of apeEvents) {
        const from = ethers.getAddress(ev.args.from);
        const to = ethers.getAddress(ev.args.to);
        if (from !== ethers.ZeroAddress && from !== SIR_ADDRESS && from !== VAULT_ADDRESS) holders.add(from);
        if (to !== ethers.ZeroAddress && to !== SIR_ADDRESS && to !== VAULT_ADDRESS) holders.add(to);
    }

    // Add V2 LP-token senders/receivers
    for (const ev of v2TransferEvents) {
        const from = ethers.getAddress(ev.args.from);
        const to = ethers.getAddress(ev.args.to);
        if (from !== ethers.ZeroAddress && from !== SIR_ADDRESS && from !== VAULT_ADDRESS) holders.add(from);
        if (to !== ethers.ZeroAddress && to !== SIR_ADDRESS && to !== VAULT_ADDRESS) holders.add(to);
    }

    // Add V3 NFT-position senders/receivers
    for (const ev of v3TransferEvents) {
        const from = ethers.getAddress(ev.args.from);
        const to = ethers.getAddress(ev.args.to);
        if (from !== ethers.ZeroAddress && from !== SIR_ADDRESS && from !== VAULT_ADDRESS) holders.add(from);
        if (to !== ethers.ZeroAddress && to !== SIR_ADDRESS && to !== VAULT_ADDRESS) holders.add(to);
    }

    // 5) For each holder snapshot balances + LP pulls
    console.log(`Processing ${holders.size} holders across ${vaultCount} vaults`);
    const entries = [];
    for (const addr of holders) {
        process.stdout.write(`\r${entries.length} processed`);

        const code = await provider.getCode(addr);
        const isContract = code !== "0x";

        // on‐chain balance
        const sir_balance = await sir.balanceOf(addr, { blockTag: SNAPSHOT_BLOCK });

        // contributor unminted
        let sir_unminted_contributor = 0n;
        if (CONTRIBUTOR_ADDRESSES.has(addr)) {
            sir_unminted_contributor = await sir.contributorUnclaimedSIR(addr, { blockTag: SNAPSHOT_BLOCK });
        }

        // vault rewards and LP positions
        let sir_liquidity_mining = 0n;
        const lp_sir = {
            usdc: 0n,
            usdt: 0n,
            weth: 0n,
            wbtc: 0n,
            sir: 0n
        };
        for (let vid = 1; vid <= vaultCount; vid++) {
            try {
                sir_liquidity_mining += await vault.unclaimedRewards(vid, addr, { blockTag: SNAPSHOT_BLOCK });
            } catch {
                console.log(`User ${addr} call to unclaimedRewards for vault ID ${vid} reverted.`);
            }

            const { debtToken, collateralToken, leverageTier } = vaultParamsArray[vid - 1];
            const vaultParams = { debtToken, collateralToken, leverageTier };

            // Get LPers claim of colalteral
            const teaBal = BigInt(await vault.balanceOf(addr, vid, { blockTag: SNAPSHOT_BLOCK }));
            if (teaBal > 0) {
                try {
                    const collateralFromTeaBurn = BigInt(
                        await vault.burn.staticCall(
                            false, // isAPE
                            vaultParams,
                            teaBal,
                            { from: addr, blockTag: SNAPSHOT_BLOCK }
                        )
                    );
                    lp_sir[vaultParamsArray[vid - 1].collateralTokenSymbol] += collateralFromTeaBurn;
                } catch {
                    console.log(`User ${addr} with balance ${teaBal} call to burn TEA for vault ID ${vid} reverted.`);
                }
            }

            // Get leveragors claim of collateral
            const apeBal = BigInt(
                await vaultParamsArray[vid - 1].apeToken.balanceOf(addr, { blockTag: SNAPSHOT_BLOCK })
            );
            if (apeBal > 0) {
                try {
                    const collateralFromApeBurn = BigInt(
                        await vault.burn.staticCall(
                            true, // isAPE
                            vaultParams,
                            apeBal,
                            { from: addr, blockTag: SNAPSHOT_BLOCK }
                        )
                    );
                    lp_sir[vaultParamsArray[vid - 1].collateralTokenSymbol] += collateralFromApeBurn;
                } catch {
                    console.log(
                        `User ${addr} with balance ${apeBal} call to burn APE (${
                            vaultParamsArray[vid - 1].apeToken.target
                        }) for vault ID ${vid} reverted.`
                    );
                }
            }
        }

        // stake
        const [unlocked, locked] = await sir.stakeOf(addr, { blockTag: SNAPSHOT_BLOCK });
        const sir_staked = unlocked + locked;

        // v2 LP share
        const lp_uniswap_v2 = { sir: 0n, weth: 0n };
        const lpBalV2 = await uniV2.balanceOf(addr, { blockTag: SNAPSHOT_BLOCK });
        lp_uniswap_v2.sir = (lpBalV2 * reserveSIR_V2) / totalSupplyV2;
        lp_uniswap_v2.weth = (lpBalV2 * reserveETH_V2) / totalSupplyV2;

        // sum up SIR in Uniswap V3
        const lp_uniswap_v3 = { sir: 0n, weth: 0n };
        const tokenIds = v3Positions[addr] || [];
        for (const tokenId of tokenIds) {
            const { sirAmt, ethAmt } = await simulateWithdrawV3(tokenId);
            lp_uniswap_v3.sir += BigInt(sirAmt);
            lp_uniswap_v3.weth += BigInt(ethAmt);
        }

        if (
            sir_balance === 0n &&
            sir_unminted_contributor === 0n &&
            sir_liquidity_mining === 0n &&
            sir_staked === 0n &&
            allZero(lp_uniswap_v2) &&
            allZero(lp_uniswap_v3) &&
            allZero(lp_sir)
        )
            continue;

        entries.push({
            addr,
            isContract,
            sir_balance,
            sir_unminted_contributor,
            sir_liquidity_mining,
            sir_staked,
            lp_uniswap_v2,
            lp_uniswap_v3,
            lp_sir
        });
    }

    // 5) post‐process contributor “old” and unmintedRemaining etc.
    const threeYears = 3n * 365n * 24n * 60n * 60n;
    const total3Y = issuance * threeYears;
    for (const contrib of CONTRIBUTOR_ADDRESSES) {
        const rec = entries.find((e) => e.addr === contrib);

        if (rec.sir_unminted_contributor === 0n) throw new Error(`No record found for contributor ${contrib}`);

        // Old allocation
        let cdata = prehackContributors.find((c) => ethers.getAddress(c.address) === contrib) ?? {};
        const allocationsContributors = BigInt(cdata.allocation || 0) * 1_000_000_000_000_000n;

        cdata = prehackPresale.contributors.find((c) => ethers.getAddress(c.address) === contrib) ?? {};
        const allocationPresale = BigInt(cdata.allocationPrecision || 0);

        const allocationOld = allocationsContributors + allocationPresale;
        rec.allocationOld = Number(allocationOld / 1_000_000_000_000_000n);

        // Compute remaining unminted contributor SIR
        const remainC =
            (issuance * (BigInt(tsIssuanceStart) + threeYears - BigInt(tsSnapshot)) * allocationOld) /
            10_000_000_000_000_000_000n;
        rec.sir_unminted_contributor += remainC;
    }

    const prices = {
        eth: await fetchPrices("ETH"),
        btc: await fetchPrices("BTC"),
        usdt: await fetchPrices("USDT"),
        usdc: await fetchPrices("USDC"),
        sir: 3_600_000 / (2_015_000_000 * 3) // Assuming $3.6M valuation after 3 years of emissions
    };

    const pricesPrecision = Object.fromEntries(
        Object.entries(prices).map(([key, value]) => [key, BigInt(Math.round(value * 1e10))])
    );

    // 6) final vector of allocations
    const allocations = entries
        .map((e) => {
            const SIR_TOTAL_BALANCE =
                e.sir_balance +
                e.sir_unminted_contributor +
                e.sir_liquidity_mining +
                e.sir_staked +
                e.lp_sir.sir +
                e.lp_uniswap_v2.sir +
                e.lp_uniswap_v3.sir;

            const WETH_TOTAL_BALANCE = e.lp_uniswap_v2.weth + e.lp_uniswap_v3.weth + e.lp_sir.weth;

            let SIR_ENTITLED = SIR_TOTAL_BALANCE;
            SIR_ENTITLED += (WETH_TOTAL_BALANCE * pricesPrecision.eth) / (pricesPrecision.sir * 1_000_000n);
            SIR_ENTITLED += (e.lp_sir.wbtc * pricesPrecision.btc * 10_000n) / pricesPrecision.sir;
            SIR_ENTITLED += (e.lp_sir.usdt * pricesPrecision.usdt * 1_000_000n) / pricesPrecision.sir;
            SIR_ENTITLED += (e.lp_sir.usdc * pricesPrecision.usdc * 1_000_000n) / pricesPrecision.sir;

            // The extra term "+total3Y/2n" is to round to the nearest integer
            let allocationInBasisPoints = Number((SIR_ENTITLED * 10_000n + total3Y / 2n) / total3Y);
            let allocationInBillionParts = Number((SIR_ENTITLED * 1_000_000_000n + total3Y / 2n) / total3Y);

            // Exceptions
            if (e.addr === "0x686748764c5C7Aa06FEc784E60D14b650bF79129") {
                // Treasury will get a fixed allocation
                allocationInBasisPoints = 1_000;
                allocationInBillionParts = 100_000_000;
            } else if (SIR_ENTITLED < 1_000_000_000_000n) {
                // Ignore balances less than 1 SIR
                return undefined;
            } else if (addressesToIgnore.includes(e.addr)) {
                // Ignore some addresses
                return undefined;
            } else if (e.addr === "0xFBc09531f02CAb8A0c78Da0cCDCf0AeF34D1c5EB") {
                // Defi Collective cannot claim from their locking contract, so we swap it to their safe address
                return (e.addr = "0x6665E62eF6F6Db29D5F8191fBAC472222C2cc80F");
            }

            return {
                address: e.addr,
                isContract: e.isContract,
                sir_balance: bigIntToString(e.sir_balance),
                sir_liquidity_mining: bigIntToString(e.sir_liquidity_mining),
                sir_unminted_contributor: bigIntToString(e.sir_unminted_contributor),
                sir_staked: bigIntToString(e.sir_staked),
                sir_sir: bigIntToString(e.lp_sir.sir),
                sir_uniswapV2: bigIntToString(e.lp_uniswap_v2.sir),
                sir_uniswapV3: bigIntToString(e.lp_uniswap_v3.sir),
                SIR_TOTAL_BALANCE: bigIntToString(SIR_TOTAL_BALANCE),
                eth_sir: bigIntToString(e.lp_sir.weth),
                eth_uniswapV2: bigIntToString(e.lp_uniswap_v2.weth),
                eth_uniswapV3: bigIntToString(e.lp_uniswap_v3.weth),
                WETH_TOTAL_BALANCE: bigIntToString(WETH_TOTAL_BALANCE),
                wbtc_sir: bigIntToString(e.lp_sir.wbtc),
                usdc_sir: bigIntToString(e.lp_sir.usdc),
                usdt_sir: bigIntToString(e.lp_sir.usdt),
                SIR_ENTITLED: bigIntToString(SIR_ENTITLED),
                allocationOld: e.allocationOld || 0,
                allocationInBasisPoints,
                allocationInBillionParts
            };
        })
        .filter((e) => e !== undefined);

    console.log(
        `Total old team + presale allocation: ${allocations.reduce((acc, curr) => acc + curr.allocationOld, 0)}`
    );

    const output = {
        allocations,
        TOTAL_BASIS_POINTS: allocations.reduce((acc, curr) => acc + curr.allocationInBasisPoints, 0),
        prices
    };

    fs.writeFileSync(OUTPUT_FILE, JSON.stringify(output, null, 2));
    await provider.connection?.agent.destroy?.();
    console.log(`\nWrote allocations to ${OUTPUT_FILE}`);
}

const allZero = (obj) => Object.values(obj).every((v) => typeof v === "bigint" && v === 0n);

function bigIntToString(x) {
    return x.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

main();
