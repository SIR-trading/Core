# Allocations

Scripts for generating MegaETH contributor allocations based on SIR/HyperSIR holdings.

## Run Order

```bash
# 1. Generate snapshots (can run in parallel)
node ethereum-balance-snapshot.js
node hyperevm-balance-snapshot.js

# 2. Generate allocations
node generate-allocations.js
```

## Files

### Input Files

| File                         | Description                                                                                                        |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `ethereum-contributors.json` | Contributors with allocations on Ethereum. Must be included manually since unminted SIR has no on-chain trace      |
| `hyperevm-contributors.json` | Contributors with allocations on HyperEVM. Must be included manually since unminted HyperSIR has no on-chain trace |
| `megaeth-contributors.json`  | Fixed contributors with basis point allocations (e.g., Treasury, core team)                                        |

### Scripts

| File                           | Description                                                                                                                                                    |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ethereum-balance-snapshot.js` | Queries Ethereum for SIR holdings (wallet, staked, vault equity, rewards, Uniswap V3). Outputs `ethereum-snapshot.json`                                        |
| `hyperevm-balance-snapshot.js` | Queries HyperEVM for HyperSIR holdings. Outputs `hyperevm-snapshot.json`                                                                                       |
| `generate-allocations.js`      | Combines snapshots with TVL weights to compute MegaETH allocations. Fixed contributors get their basis points first, remainder distributed to weighted holders |

### Generated Files

| File                      | Description                                         |
| ------------------------- | --------------------------------------------------- |
| `ethereum-snapshot.json`  | SIR balances and percentages per address            |
| `hyperevm-snapshot.json`  | HyperSIR balances and percentages per address       |
| `allocations.json`        | Detailed allocations with breakdowns (for auditing) |
| `allocations-deploy.json` | Compact format for Foundry deployment scripts       |

## Allocation Formula

1. **Fixed contributors** receive allocations in basis points of total issuance (from `megaeth-contributors.json`)
2. **Weighted holders** split the remainder based on:
    ```
    weightedPercentage = (ethPercentage * TVL_SIR + hyperPercentage * TVL_HYPERSIR) / TOTAL_TVL
    ```
    This `weightedPercentage` represents the holder's share of the contributors pool (30% of total issuance).

Allocations are stored as `uint16` values summing to `type(uint16).max` (65,535).
