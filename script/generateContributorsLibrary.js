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
    const addAllocation = (address, allocation, ens, source) => {
        const key = address.toLowerCase();
        const existing = allocations.get(key) || { allocation: 0, ens: "", source };

        allocations.set(key, {
            address,
            allocation: existing.allocation + allocation,
            ens: ens || existing.ens,
            source: existing.source || source
        });
    };

    // Process spice contributors (no ENS)
    processSpice().forEach(({ address, allocation }) => addAllocation(address, allocation, "", "spice"));

    // Process fundraising contributors (with ENS)
    fundraisingData.contributors.forEach((c) => {
        const baseRatio = c.contribution / SALE_CAP_USD;
        const baseAllocation = baseRatio * FUNDRAISING_PERCENTAGE;
        const boost = 1 + (c.lock_nfts * BC_BOOST_PER_CENT) / 100;
        addAllocation(c.address, baseAllocation * boost, c.ens, "usd");
    });

    // Add treasury allocation
    addAllocation(TREASURY_ADDRESS, 10, "", "treasury");

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
function generateLibrary(allocations) {
    // uint56 max
    const TYPE_MAX = 0xffffffffffffffn;

    // Sum of all percentage allocations (e.g. 31.87)
    const totalContributorPercentage = allocations.reduce((sum, c) => sum + c.allocation, 0);

    // Compute exact uint56 shares with largest-remainder rounding
    let remaining = TYPE_MAX;
    const scaled = allocations.map((c) => {
        // exact share proportional to allocation%
        const exact = BigInt(Math.floor((c.allocation * Number(TYPE_MAX)) / totalContributorPercentage));
        remaining -= exact;
        return { ...c, exact };
    });
    // Sort by fractional remainder descending
    scaled
        .sort((a, b) => {
            const ra = (a.allocation * Number(TYPE_MAX)) % totalContributorPercentage;
            const rb = (b.allocation * Number(TYPE_MAX)) % totalContributorPercentage;
            return rb - ra;
        })
        .forEach((c, i) => {
            if (remaining > 0n) {
                scaled[i].exact += 1n;
                remaining -= 1n;
            }
        });
    // Sanity check
    const sumCheck = scaled.reduce((acc, c) => acc + c.exact, 0n);
    if (sumCheck !== TYPE_MAX) {
        throw new Error(`Allocation rounding sum ${sumCheck} != ${TYPE_MAX}`);
    }

    // Partition by source
    const presale = scaled.filter((c) => c.source === "usd");
    const spice = scaled.filter((c) => c.source === "spice");
    const treasury = scaled.filter((c) => c.source === "treasury");

    // Helper to format each assignment line
    const fmt = (c) => `        allocations[${c.address}] = ${c.exact.toString()}; // ${c.allocation.toFixed(4)}%`;

    // Build the Solidity text
    return `// SPDX-License-Identifier: MIT
  pragma solidity ^0.8.0;
  
  contract Contributors {
      /** @dev Total contributor allocation: ${totalContributorPercentage.toFixed(2)}%
       *  LP allocation: ${(100 - totalContributorPercentage).toFixed(2)}%
       *  Sum of all allocations must be equal to type(uint56).max.
       */
      mapping(address => uint56) public allocations;
  
      constructor() {
          // -------- Presale Contributors --------
  ${presale.map(fmt).join("\n")}
  
          // -------- Spice Contributors --------
  ${spice.map(fmt).join("\n")}
  
          // -------- Treasury --------
  ${treasury.map(fmt).join("\n")}
      }
  
      /// @notice Lookup your contributor allocation
      function getAllocation(address contributor) external view returns (uint56) {
          return allocations[contributor];
      }
  }
  `;
}

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
