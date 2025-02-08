const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

// Configure these values
const SALE_CAP_USD = 100000; // $100,000
const BASE_ALLOCATION_PERCENT = 10; // 10% of total tokens
const CARD_BOOST_PERCENT = 6; // 6% boost per card
const CONTRACT_ADDRESS = "0x4edF071a7dEe52fBE663DF7873994725ba91Cdc7";
const ABI = [
    {
        type: "function",
        name: "contributions",
        inputs: [{ name: "contributor", type: "address", internalType: "address" }],
        outputs: [
            {
                name: "",
                type: "tuple",
                internalType: "struct SaleStructs.Contribution",
                components: [
                    {
                        name: "stablecoin",
                        type: "uint8",
                        internalType: "enum SaleStructs.Stablecoin"
                    },
                    {
                        name: "amountFinalNoDecimals",
                        type: "uint24",
                        internalType: "uint24"
                    },
                    {
                        name: "amountWithdrawableNoDecimals",
                        type: "uint24",
                        internalType: "uint24"
                    },
                    {
                        name: "timeLastContribution",
                        type: "uint40",
                        internalType: "uint40"
                    },
                    {
                        name: "lockedButerinCards",
                        type: "tuple",
                        internalType: "struct SaleStructs.LockedButerinCards",
                        components: [
                            { name: "number", type: "uint8", internalType: "uint8" },
                            {
                                name: "ids",
                                type: "uint16[5]",
                                internalType: "uint16[5]"
                            }
                        ]
                    },
                    {
                        name: "lockedMinedJpegs",
                        type: "tuple",
                        internalType: "struct SaleStructs.LockedMinedJpegs",
                        components: [
                            { name: "number", type: "uint8", internalType: "uint8" },
                            {
                                name: "ids",
                                type: "uint8[5]",
                                internalType: "uint8[5]"
                            }
                        ]
                    }
                ]
            }
        ],
        stateMutability: "view"
    },
    {
        type: "event",
        name: "Deposit",
        inputs: [
            {
                name: "stablecoin",
                type: "uint8",
                indexed: false,
                internalType: "enum SaleStructs.Stablecoin"
            },
            {
                name: "amountNoDecimals",
                type: "uint24",
                indexed: false,
                internalType: "uint24"
            }
        ],
        anonymous: false
    }
];
const BOOSTED_ADDRESSES = new Set([
    "0x36D11126eBc59cb962AE8ddD3bcD0741b4e337Dc".toLowerCase(),
    "0xF032eF6D2Bc2dBAF66371cFEC4B1B49F4786A250".toLowerCase(),
    "0x2513bf7540334eeF1733849c50FD41D598a46103".toLowerCase(),
    "0xa485b739e99334f4b92b04da2122e2923a054688".toLowerCase(),
    "0x478087E12DB15302a364C64CDB79F14Ae6C5C9b7".toLowerCase(),
    "0x7B3E8cbA240827590F63249Bc6314713317a665b".toLowerCase(),
    "0x349DC3AcFb99ddACd3D00F1AEFC297eE8108Cb44".toLowerCase(),
    "0xB10B38a69DA178aa2d249315CbB28F031E9fb71B".toLowerCase(),
    "0xAacc079965F0F9473BF4299d930eF639690a9792".toLowerCase()
]);

const EXTERNAL_CONTRIBUTOR = {
    address: "0xE19618C08F74b7e80278Ec14b63797419dACCDf8",
    contribution: 2000,
    stablecoin: "USDT"
};

function calculateAllocation(contributionUSD, cardCount) {
    const baseRatio = contributionUSD / SALE_CAP_USD;
    const baseAllocation = baseRatio * BASE_ALLOCATION_PERCENT;
    const boostedAllocation = baseAllocation * (1 + (cardCount * CARD_BOOST_PERCENT) / 100);
    return [
        Math.round(boostedAllocation * 100), // Convert to basis points (1% = 100‱)
        Math.round(boostedAllocation * 1e17) // Precision
    ];
}

let disclaimer_message;
async function processContributor(address, contract, provider, depositEventsWithTx) {
    const isBoosted = BOOSTED_ADDRESSES.has(address.toLowerCase());

    // Get contribution data
    let contribution;
    try {
        contribution = await contract.contributions(address);
    } catch (error) {
        console.error(`Failed to get contribution for ${address}:`, error.message);
        return null;
    }

    // Calculate NFT counts
    const lock_nfts = isBoosted
        ? 5
        : Number(contribution.lockedButerinCards.number) + Number(contribution.lockedMinedJpegs.number);

    // Get ENS name
    const ens = (await provider.lookupAddress(address)) || "";

    // Get signature from API
    let signature;
    try {
        const response = await fetch(`https://www.sir.trading/api/get-wallet-signature?wallet=${address}`);
        const data = await response.json();
        signature = data.signature;
        if (disclaimer_message === undefined) disclaimer_message = data.message;
    } catch (error) {
        signature = "not_available";
    }

    // Get transactions
    const transactions = depositEventsWithTx
        .filter(({ tx }) => tx.from.toLowerCase() === address.toLowerCase())
        .map(({ event }) => event.transactionHash);

    const [allocation, allocationPrecision] = calculateAllocation(
        Number(contribution.amountFinalNoDecimals),
        lock_nfts
    );

    return {
        ens,
        address,
        contribution: Number(contribution.amountFinalNoDecimals),
        lock_nfts,
        allocation,
        allocationPrecision,
        disclaimer_signature: signature,
        transactions
    };
}

// Modified function to get contributors
async function getContributors(depositEvents, provider) {
    const contributors = new Set();

    // Process each deposit transaction
    for (const event of depositEvents) {
        const tx = await provider.getTransaction(event.transactionHash);
        contributors.add(tx.from);
    }

    return Array.from(contributors);
}

function bigIntReplacer(key, value) {
    return typeof value === "bigint" ? value.toString() : value;
}
function addExternalContributor(report) {
    if (!report.some((c) => c.address.toLowerCase() === EXTERNAL_CONTRIBUTOR.address.toLowerCase())) {
        const [allocation, allocationPrecision] = calculateAllocation(
            EXTERNAL_CONTRIBUTOR.contribution,
            0 // No cards
        );

        report.push({
            ens: "",
            address: EXTERNAL_CONTRIBUTOR.address,
            contribution: EXTERNAL_CONTRIBUTOR.contribution,
            lock_nfts: 0,
            allocation,
            allocationPrecision,
            disclaimer_signature: "",
            transactions: [],
            note: `External ${EXTERNAL_CONTRIBUTOR.stablecoin} contribution`
        });
    }
    return report;
}

async function generateParticipantReport() {
    // Setup provider and contract
    const provider = new ethers.AlchemyProvider(1, process.env.ALCHEMY_KEY);
    const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, provider);

    // Get contributors from Transfer events
    const depositEvents = await contract.queryFilter("Deposit");
    const depositEventsWithTx = await Promise.all(
        depositEvents.map(async (e) => ({
            event: e,
            tx: await provider.getTransaction(e.transactionHash)
        }))
    );

    const contributors = await getContributors(depositEvents, provider);

    // Process all contributors and calculate total allocation
    const report = {
        disclaimer_message,
        contributors: [],
        total_allocation: 0
    };

    // Process all contributors
    for (const address of contributors) {
        const entry = await processContributor(address, contract, provider, depositEventsWithTx);
        if (entry) {
            report.contributors.push(entry);
            report.total_allocation += entry.allocation;
        }
    }

    report.disclaimer_message = disclaimer_message;

    // Add external contributor
    addExternalContributor(report.contributors);
    report.total_allocation += report.contributors.find(
        (c) => c.address.toLowerCase() === EXTERNAL_CONTRIBUTOR.address.toLowerCase()
    ).allocation;

    // Save to JSON file
    fs.writeFileSync(
        path.join(__dirname, "../contributors/usd-contributors.json"),
        JSON.stringify(report, bigIntReplacer, 2)
    );

    console.log(`Report generated with ${report.contributors.length} contributors`);
    console.log(`Total allocation: ${report.total_allocation}‱ (${report.total_allocation / 100}%)`);
}

generateParticipantReport()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
