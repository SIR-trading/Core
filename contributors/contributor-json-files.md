# Contributor JSON Files

This document provides an overview of the `pre_mainnet.json` and `fundraising.json` files used in the allocation calculation script.

## `pre_mainnet.json`

The `pre_mainnet.json` file contains information about pre-mainnet contributors and their allocation. Each entry in this file represents a contributor and their allocation in parts of 20,000.

The file is an array of objects, where each object has the following properties:

-   `contributor`: The Ethereum address of the contributor.
-   `allocation`: The allocation of the contributor in parts of 20,000.

For example:

```json
[
    { "contributor": "0x0000000000000000000000000000000000000011", "allocation": 500 },
    { "contributor": "0x0000000000000000000000000000000000000012", "allocation": 30 },
    { "contributor": "0x0000000000000000000000000000000000000013", "allocation": 10 },
    { "contributor": "0x0000000000000000000000000000000000000014", "allocation": 10000 }
]
```

-   The contributor `0x0000000000000000000000000000000000000011` has an allocation of 500 parts out of 20,000, which represents 2.5% of the total issuance.
-   The sum of all allocations should total 20,000 parts, representing 20% of the total issuance.
-   The contributor `0x0000000000000000000000000000000000000014` with an allocation of 10,000 parts is the treasury address.

## `fundraising.json`

The `fundraising.json` file contains information about contributors who participated in the fundraising. Each entry in this file represents a contributor, their contribution in USD, and the number of Buterin Cards they locked.

The file is an array of objects, where each object has the following properties:

-   `contributor`: The Ethereum address of the contributor.
-   `contribution`: The contribution of the contributor in USD.
-   `num_bc`: The number of Buterin Cards locked by the contributor.

For example:

```json
[
    { "contributor": "0x0000000000000000000000000000000000000001", "contribution": 1000, "num_bc": 0 },
    { "contributor": "0x0000000000000000000000000000000000000002", "contribution": 10000, "num_bc": 4 },
    { "contributor": "0x0000000000000000000000000000000000000003", "contribution": 4269, "num_bc": 1 }
]
```

-   The contributor `0x0000000000000000000000000000000000000001` contributed $1000 and locked 0 Buterin Cards.
-   The contributor `0x0000000000000000000000000000000000000002` contributed $10,000 and locked 4 Buterin Cards, which gives them a 20% boost in allocation.
-   The total fundraising goal is $500,000, and the total issuance for fundraising contributors is 10% of the total issuance. Each Buterin Card locked provides a 5% boost to the contributor’s allocation.
-   The boost can increase a contributor's allocation beyond the initial percentage of the issuance, potentially increasing the total allocation beyond the intended 20%.

## Calculation of Allocations

-   Each pre-mainnet contributor’s allocation is calculated as a fraction of the total 20,000 parts.
-   Each fundraising contributor’s base allocation is calculated based on their contribution relative to the $500,000 goal. Each Buterin Card locked provides a 5% boost to the contributor’s allocation.
-   The combined allocations of pre-mainnet and fundraising contributors should total between 30% and 33% of the total issuance.

## Usage

The script reads these JSON files, processes the data, and generates a Solidity library with functions to retrieve the allocation for each contributor based on their Ethereum address.

Make sure the JSON files are formatted correctly and that the total allocations meet the specified constraints before running the script.
