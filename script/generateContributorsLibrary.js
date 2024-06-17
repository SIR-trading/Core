const fs = require("fs");
const path = require("path");

// Load JSON data
const preMainnetPath = path.join(__dirname, "../contributors/pre_mainnet.json");
const fundraisingPath = path.join(__dirname, "../contributors/fundraising.json");

const preMainnetData = JSON.parse(fs.readFileSync(preMainnetPath, "utf8"));
const fundraisingData = JSON.parse(fs.readFileSync(fundraisingPath, "utf8"));

// Constants
const TOTAL_PREMAINNET_ALLOCATION = 20000; // 10% of total issuance to pre-mainnet contributors + 10% to a treasury
const FUNDRAISING_PERCENTAGE = 10; // 10% of the total issuance at least
const BC_BOOST = 0.05; // 5% boost per BC
const MAX_NUM_BC = 6; // Maximum number of BCs for boost

// Calculate total contribution sum for fundraising goal
const FUNDRAISING_TOTAL = fundraisingData.reduce((sum, { contribution }) => sum + contribution, 0);

// Calculate total allocation for pre-mainnet contributors
const totalPreMainnetAllocation = preMainnetData.reduce((sum, { allocation }) => sum + allocation, 0);
if (totalPreMainnetAllocation !== TOTAL_PREMAINNET_ALLOCATION) {
    throw new Error(
        `Total pre-mainnet allocation must be ${TOTAL_PREMAINNET_ALLOCATION}, but got ${totalPreMainnetAllocation}`
    );
}

// Calculate total allocation for fundraising contributors
const fundraisingAllocations = fundraisingData.map(({ contributor, contribution, num_bc }) => {
    const baseAllocation = (contribution / FUNDRAISING_TOTAL) * (FUNDRAISING_PERCENTAGE / 100);
    let boost = 1 + BC_BOOST * Math.min(num_bc, MAX_NUM_BC);
    return {
        contributor,
        allocation: baseAllocation * boost
    };
});

// Combine all allocations
const allAllocations = [
    ...preMainnetData.map(({ contributor, allocation }) => ({
        contributor,
        allocation: (allocation / TOTAL_PREMAINNET_ALLOCATION) * 0.2 // 20% of total issuance
    })),
    ...fundraisingAllocations
];

// Check if the sum of all allocations is within the expected range (30-33%)
const totalAllocation = allAllocations.reduce((sum, { allocation }) => sum + allocation, 0);
if (totalAllocation < 0.3 || totalAllocation > 0.33) {
    throw new Error(
        `Total allocation must be between 30% and 33% of total issuance, but got ${totalAllocation * 100}%`
    );
}
console.log(`Total allocation: ${totalAllocation * 100}%`);

// Normalize allocations to type(uint56).max
const typeMax = 0xffffffffffffff; // type(uint56).max
const scaledAllocations = allAllocations.map(({ contributor, allocation }) => ({
    contributor,
    allocation: Math.round((allocation * typeMax) / totalAllocation).toString()
}));

// Generate Solidity library
const libraryContent = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Contributors {
    /** @dev This library is generated by the script \`generate-contributors.js\`.
        @dev An allocation of type(uint56).max means 100% of the issuance reserved for contributors. 
        @dev Sum of all allocations should be equal to type(uint56).max or less.
    */
    function getAllocation(address contributor) internal pure returns (uint56) {
${scaledAllocations
    .map(
        ({ contributor, allocation }, i) =>
            `        ${
                i == 0 ? "" : "else "
            }if (contributor == address(${contributor.toLowerCase()})) return ${allocation};`
    )
    .join("\n")}
        
        return 0;
    }
}
`;

// Write the Solidity library to a file
const outputPath = path.join(__dirname, "../src/libraries", "Contributors.sol");
fs.writeFileSync(outputPath, libraryContent);
console.log("Library Contributors.sol successfully.");

// Update SystemConstants.sol with new LP_ISSUANCE_FIRST_3_YEARS
const systemConstantsPath = path.join(__dirname, "../src/libraries/SystemConstants.sol");
let systemConstantsContent = fs.readFileSync(systemConstantsPath, "utf8");

// Update SystemConstants.sol with new LP_ISSUANCE_FIRST_3_YEARS
const totalAllocationInt = Math.round((1 - totalAllocation) * 1e17);
const updatedLpIssuance = `uint72 internal constant LP_ISSUANCE_FIRST_3_YEARS = uint72((uint256(${totalAllocationInt}) * ISSUANCE) / 1e17);`;

systemConstantsContent = systemConstantsContent.replace(
    /uint72 internal constant LP_ISSUANCE_FIRST_3_YEARS =[\s\S]*?;/,
    updatedLpIssuance
);

fs.writeFileSync(systemConstantsPath, systemConstantsContent);
console.log("SystemConstants.sol updated successfully.");
