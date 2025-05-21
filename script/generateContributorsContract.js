const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

// File paths
const COMP_PATH = path.join(__dirname, "../contributors/posthack-compensations.json");
const POST_PATH = path.join(__dirname, "../contributors/posthack-contributors.json");
const OUTPUT_PATH = path.join(__dirname, "../src/Contributors.sol");

// Load data
const compensations = JSON.parse(fs.readFileSync(COMP_PATH, "utf8")).allocations;
const postContribs = JSON.parse(fs.readFileSync(POST_PATH, "utf8"));

/**
 * Combine raw weights from both sources (summing duplicates) and scale to uint56.max using largest-remainder.
 * Also compute each address's percentage of total weight.
 */
let totalWeight;
function combineAllocations() {
    const TYPE_MAX = 0xffffffffffffffn;

    // Merge weights by address
    const weightMap = new Map();
    function addWeight(addr, weight) {
        const key = ethers.getAddress(addr);
        weightMap.set(key, (weightMap.get(key) || 0n) + weight);
    }
    compensations.forEach((c) => addWeight(c.address, BigInt(c.allocationInBillionParts)));
    postContribs.forEach((c) => addWeight(c.address, BigInt(c.allocationInBillionParts)));

    // Build merged array with numeric weights
    const raw = Array.from(weightMap.entries()).map(([address, weight]) => ({
        address,
        weight, // BigInt weight
        weightNum: Number(weight) // numeric for percentage
    }));

    // Compute totals
    totalWeight = raw.reduce((sum, e) => sum + e.weight, 0n);

    // First pass: floor allocation of TYPE_MAX
    let remaining = TYPE_MAX;
    let scaled = raw.map((e) => {
        const exact = (e.weight * TYPE_MAX) / totalWeight;
        remaining -= exact;
        return { ...e, exact };
    });

    // Sort by largest fractional remainder for tie-breaking
    scaled.sort((a, b) => {
        const ra = (a.weight * TYPE_MAX) % totalWeight;
        const rb = (b.weight * TYPE_MAX) % totalWeight;
        return rb > ra ? 1 : ra > rb ? -1 : 0;
    });

    // Distribute leftover 1's
    for (let i = 0; i < scaled.length && remaining > 0n; i++) {
        scaled[i].exact += 1n;
        remaining -= 1n;
    }

    // Verify sum
    const sumCheck = scaled.reduce((sum, e) => sum + e.exact, 0n);
    if (sumCheck !== TYPE_MAX) {
        throw new Error(`Allocation rounding sum ${sumCheck} != ${TYPE_MAX}`);
    }

    // Attach percentage
    return scaled.map((e) => ({
        address: e.address,
        exact: e.exact,
        percent: e.weightNum / 1e7
    }));
}

/**
 * Generate Solidity contract source from scaled allocations.
 * Lines are ordered from largest percent to smallest, with 2-decimal comments.
 */
function generateLibrary(scaled) {
    // Sort by percent desc
    const sorted = [...scaled].sort((a, b) => b.percent - a.percent);

    const fmt = (e) => `        allocations[${e.address}] = ${e.exact.toString()}; // ${e.percent.toPrecision(2)}%`;

    const lines = sorted.map(fmt).join("\n");

    return `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Contributors {
    /** @dev Total contributor allocation: ${(Number(totalWeight) / 1e7).toFixed(4)}%
     *  LP allocation: ${(100 - Number(totalWeight) / 1e7).toFixed(4)}%
     *  Sum of all allocations must be equal to type(uint56).max.
     */
    mapping(address => uint56) public allocations;

    constructor() {
${lines}
    }

    /// @notice Lookup your contributor allocation
    function getAllocation(address contributor) external view returns (uint56) {
        return allocations[contributor];
    }
}
`;
}

// Main script
try {
    const scaled = combineAllocations();
    const libraryCode = generateLibrary(scaled);
    fs.writeFileSync(OUTPUT_PATH, libraryCode);
    console.log(`Contributors.sol generated with ${scaled.length} entries`);
    console.log(
        `Set value in constant LP_ISSUANCE_FIRST_3_YEARS to ${(
            100_000_000_000_000_000n -
            totalWeight * 100_000_000n
        ).toString()}`
    );
} catch (error) {
    console.error("Error generating allocations:", error);
    process.exit(1);
}
