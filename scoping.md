## 1. Repository Links

-   https://github.com/SIR-trading/Core

## 2. Branches

-   master: audit-2024

## File paths to INCLUDE

**Core**

```
contracts/Vault.sol
contracts/TEA.sol
contracts/SystemState.sol
contracts/APE.sol
contracts/SIR.sol
contracts/Staker.sol
contracts/SystemControl.sol
contracts/Oracle.sol
contracts/SystemControlAccess.sol

contracts/libraries/VaultExternal.sol
contracts/libraries/TickMathPrecision.sol
contracts/libraries/Fees.sol
contracts/libraries/Contributors.sol
contracts/libraries/AddressClone.sol
```

## Priority files

✅ Identify files that should receive extra attention:

```
contracts/Vault.sol
contracts/TEA.sol
contracts/SystemState.sol
contracts/APE.sol
contracts/SIR.sol
contracts/Staker.sol
contracts/SystemControl.sol
contracts/Oracle.sol

contracts/libraries/VaultExternal.sol
contracts/libraries/TickMathPrecision.sol
```

## Areas of concern

✅ List specific issues or vulnerabilities you want the audit to focus on:

```
- Flash economic attacks.
- The architecture uses the singleton Vault, which means the same contract stores all positions of different ERC20 vaults. Ensure code on malicious ERC20's do not impact the state of other ERC20's.
- TickMathPrecision mods TickMath from Uniswap v3 so it can compute log_1.0001 with decimals. This makes it simpler to connect with Uv3 oracles. Verify the library is sound.
- Malicious user actions.
- Contract Oracle is a wrap around the Uniswap v3 oracle that allows us to get data from Uniswap v3 without having to manually control any parameters. It can autonomously change the fee tier it gets the price from. Verify it's complexity does not introduce any vulnerabilities.
- Verify leveraged positions are really convex assuming sufficient liquidity is available.
- Large gas optimizations
```
