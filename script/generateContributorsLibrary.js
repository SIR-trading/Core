const fs = require("fs");
const path = require("path");
require("dotenv").config();

// Configuration
const FUNDRAISING_PERCENTAGE = 10; // 10% of total tokens for fundraising
const SALE_CAP_USD = 100000; // $100,000 sale cap
const BC_BOOST_PER_CENT = 6; // 6% boost per NFT
const TREASURY_ADDRESS = process.env.TREASURY_ADDRESS; // Add your treasury address here

// File paths
const SPICE_PATH = path.join(__dirname, "../contributors/spice-contributors.json");
const FUNDRAISING_PATH = path.join(__dirname, "../contributors/usd-contributors.json");
const OUTPUT_PATH = path.join(__dirname, "../src/libraries/Contributors.sol");

// Load and process data
const spiceContributors = JSON.parse(fs.readFileSync(SPICE_PATH, "utf8"));
const fundraisingData = JSON.parse(fs.readFileSync(FUNDRAISING_PATH, "utf8"));

function logAllocations(allocations) {
    console.log("\nAllocation Breakdown:");
    allocations.forEach(({ address, allocation, ens }) => {
        const ensInfo = ens ? ` (ENS: ${ens})` : "";
        console.log(`- ${address}: ${allocation.toFixed(2)}%${ensInfo}`);
    });
}

// Process spice contributors (convert basis points to percentage)
const processSpice = () =>
    spiceContributors.map((c) => ({
        address: c.address,
        allocation: c.allocation / 100 // Convert basis points to percentage
    }));

// Combine allocations
const combineAllocations = () => {
    const allocations = new Map();

    // Helper to add allocations with ENS
    const addAllocation = (address, allocation, ens) => {
        const key = address.toLowerCase();
        const existing = allocations.get(key) || { allocation: 0, ens: "" };

        allocations.set(key, {
            address,
            allocation: existing.allocation + allocation,
            ens: ens || existing.ens // Preserve existing ENS if any
        });
    };

    // Process spice contributors (no ENS)
    processSpice().forEach(({ address, allocation }) => addAllocation(address, allocation, ""));

    // Process fundraising contributors (with ENS)
    fundraisingData.contributors.forEach((c) => {
        const baseRatio = c.contribution / SALE_CAP_USD;
        const baseAllocation = baseRatio * FUNDRAISING_PERCENTAGE;
        const boost = 1 + (c.lock_nfts * BC_BOOST_PER_CENT) / 100;
        addAllocation(c.address, baseAllocation * boost, c.ens);
    });

    // Add treasury allocation
    addAllocation(TREASURY_ADDRESS, 10, "");

    return Array.from(allocations.values()).sort((a, b) => b.allocation - a.allocation);
};

function calculateLpAllocation(totalContributorAllocation) {
    // Convert percentages to fractions
    const totalContributorFraction = totalContributorAllocation / 100;
    const lpFraction = 1 - totalContributorFraction; // This is now < 1

    // Scale to 1e17 (17 decimal places) for Solidity fixed-point math
    const scaledLpFraction = Math.round(lpFraction * 1e17);

    return {
        percentage: lpFraction * 100, // For display purposes
        fraction: scaledLpFraction.toString().padStart(17, "0")
    };
}

// Generate Solidity library
const generateLibrary = (allocations) => {
    const TYPE_MAX = 0xffffffffffffffn; // uint56.max as BigInt
    const totalContributorPercentage = allocations.reduce((sum, c) => sum + c.allocation, 0);

    // Convert allocations to basis points (integer math)
    const allocationData = allocations.map((c) => {
        const basisPoints = BigInt(Math.round(c.allocation * 100));
        return {
            ...c,
            basisPoints: basisPoints
        };
    });

    // Calculate total basis points
    const totalBasisPoints = allocationData.reduce((sum, c) => sum + c.basisPoints, 0n);

    // Calculate allocations with remainders
    let remaining = TYPE_MAX;
    const allocationList = allocationData.map((c) => {
        const exact = (c.basisPoints * TYPE_MAX) / totalBasisPoints;
        remaining -= exact;
        return {
            ...c,
            exact: exact,
            remainder: Number((c.basisPoints * TYPE_MAX) % totalBasisPoints)
        };
    });

    // Distribute remaining units to largest remainders first
    allocationList.sort((a, b) => b.remainder - a.remainder);
    for (let i = 0; remaining > 0n; i = (i + 1) % allocationList.length) {
        allocationList[i].exact += 1n;
        remaining -= 1n;
    }

    // Final validation
    const finalTotal = allocationList.reduce((sum, c) => sum + c.exact, 0n);
    if (finalTotal !== TYPE_MAX) {
        throw new Error(`Allocation sum mismatch: ${finalTotal} vs ${TYPE_MAX}`);
    }

    // Calculate LP allocation details
    const lpAllocation = calculateLpAllocation(totalContributorPercentage);

    console.log("\nTotal Allocation Breakdown:");
    console.log(`- Contributors: ${totalContributorPercentage.toFixed(7)}%`);
    console.log(`- LP Pool: ${lpAllocation.percentage.toFixed(7)}%`);
    console.log(`- LP Fraction (1e17 precision): ${lpAllocation.fraction}`);

    return `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Contributors {
    /** @dev Total contributor allocation: ${totalContributorPercentage.toFixed(2)}%
        @dev LP allocation: ${lpAllocation.percentage.toFixed(2)}%
        @dev Sum of all allocations must be equal to type(uint56).max.
     */
    function getAllocation(address contributor) internal pure returns (uint56) {
${allocationList
    .map(
        (c, i) =>
            `        ${i === 0 ? "" : "else "}if (contributor == address(${c.address})) return ${c.exact.toString()};`
    )
    .join("\n")}
        
        return 0;
    }
}`;
};

// Main execution
try {
    const allocations = combineAllocations();
    logAllocations(allocations); // Add this line

    const libraryCode = generateLibrary(allocations);
    fs.writeFileSync(OUTPUT_PATH, libraryCode);
    console.log(`\nSuccessfully generated Contributors.sol with ${allocations.length} entries`);
} catch (error) {
    console.error("Error generating allocations:", error);
    process.exit(1);
}
