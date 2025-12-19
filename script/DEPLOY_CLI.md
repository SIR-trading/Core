# MegaETH Testnet Deployment via Cast CLI

This guide replicates `DeployCore.s.sol` using individual `cast` commands.

## Prerequisites

```bash
# Set environment variables
PRIVATE_KEY=your_private_key
RPC_URL="https://timothy.megaeth.com/rpc"

## Constants (MegaETH Testnet - Chain 6343)
UNISWAP_FACTORY=0x94996d371622304F2eB85df1eb7f328F7B317C3E
WETH=0x4200000000000000000000000000000000000006
```

## Step 1: Deploy Oracle

```bash
ORACLE=$(forge create src/Oracle.sol:Oracle \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  --constructor-args "$UNISWAP_FACTORY" \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "Oracle: $ORACLE"
```

## Step 2: Deploy SystemControl

```bash
SYSTEM_CONTROL=$(forge create src/SystemControl.sol:SystemControl \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "SystemControl: $SYSTEM_CONTROL"
```

## Step 3: Deploy Contributors

```bash
CONTRIBUTORS=$(forge create src/Contributors.sol:Contributors \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "Contributors: $CONTRIBUTORS"
```

## Step 4: Deploy SIR

```bash
SIR=$(forge create src/SIR.sol:SIR \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  --constructor-args "$CONTRIBUTORS" "$WETH" "$SYSTEM_CONTROL" \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "SIR: $SIR"
```

## Step 5: Deploy APE Implementation

```bash
APE=$(forge create src/APE.sol:APE \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "APE: $APE"
```

## Step 6: Deploy VaultExternal Library

VaultExternal is a library that must be deployed first and linked when deploying Vault.

```bash
VAULT_EXTERNAL=$(forge create src/libraries/VaultExternal.sol:VaultExternal \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "VaultExternal: $VAULT_EXTERNAL"
```

## Step 7: Deploy Vault

Link VaultExternal library when deploying Vault:

```bash
VAULT=$(forge create src/Vault.sol:Vault \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  --libraries "src/libraries/VaultExternal.sol:VaultExternal:$VAULT_EXTERNAL" \
  --constructor-args "$SYSTEM_CONTROL" "$SIR" "$ORACLE" "$APE" "$WETH" \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "Vault: $VAULT"
```

## Step 8: Initialize SIR

```bash
cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  "$SIR" "initialize(address)" "$VAULT"
```

## Step 9: Initialize SystemControl

```bash
cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  "$SYSTEM_CONTROL" "initialize(address,address)" "$VAULT" "$SIR"
```

## Step 10: Allocate Contributors

Contributors must be allocated in batches. Use the allocation script or manual batches:

```bash
# Read addresses and amounts from allocations-deploy.json
# Then call allocate in batches

# Example single batch (adjust addresses and amounts):
cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  "$CONTRIBUTORS" "allocate(address[],uint24[])" \
  "[0xAddr1,0xAddr2,...]" "[100,200,...]"
```

For bulk allocation, use the separate allocation script:

```bash
forge script script/AllocateContributors.s.sol --rpc-url "$RPC_URL" --broadcast --private-key "$PRIVATE_KEY"
```

## Step 11: Verify Allocations

```bash
# Check remaining allocation (should be 0)
cast call --rpc-url "$RPC_URL" "$CONTRIBUTORS" "remainingAllocation()(uint24)"

# Check contributor count
cast call --rpc-url "$RPC_URL" "$CONTRIBUTORS" "contributorCount()(uint256)"
```

## Full Deployment Script (Bash)

Save deployed addresses to continue if interrupted:

```bash
#!/bin/bash
set -e

RPC_URL="https://timothy.megaeth.com/rpc"
UNISWAP_FACTORY=0x94996d371622304F2eB85df1eb7f328F7B317C3E
WETH=0x4200000000000000000000000000000000000006

echo "Deploying Oracle..."
ORACLE=$(forge create src/Oracle.sol:Oracle \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  --constructor-args "$UNISWAP_FACTORY" \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "Oracle: $ORACLE"
sleep 2

echo "Deploying SystemControl..."
SYSTEM_CONTROL=$(forge create src/SystemControl.sol:SystemControl \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "SystemControl: $SYSTEM_CONTROL"
sleep 2

echo "Deploying Contributors..."
CONTRIBUTORS=$(forge create src/Contributors.sol:Contributors \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "Contributors: $CONTRIBUTORS"
sleep 2

echo "Deploying SIR..."
SIR=$(forge create src/SIR.sol:SIR \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  --constructor-args "$CONTRIBUTORS" "$WETH" "$SYSTEM_CONTROL" \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "SIR: $SIR"
sleep 2

echo "Deploying APE..."
APE=$(forge create src/APE.sol:APE \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "APE: $APE"
sleep 2

echo "Deploying VaultExternal..."
VAULT_EXTERNAL=$(forge create src/libraries/VaultExternal.sol:VaultExternal \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "VaultExternal: $VAULT_EXTERNAL"
sleep 2

echo "Deploying Vault..."
VAULT=$(forge create src/Vault.sol:Vault \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  --libraries "src/libraries/VaultExternal.sol:VaultExternal:$VAULT_EXTERNAL" \
  --constructor-args "$SYSTEM_CONTROL" "$SIR" "$ORACLE" "$APE" "$WETH" \
  2>&1 | awk '/Deployed to:/ {print $3; exit}')
echo "Vault: $VAULT"
sleep 2

echo "Initializing SIR..."
cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  "$SIR" "initialize(address)" "$VAULT"
sleep 2

echo "Initializing SystemControl..."
cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --gas-price 10000000 --priority-gas-price 1000000 --gas-limit 1000000000 \
  "$SYSTEM_CONTROL" "initialize(address,address)" "$VAULT" "$SIR"

echo ""
echo "=== Deployment Complete ==="
echo "ORACLE=$ORACLE"
echo "SYSTEM_CONTROL=$SYSTEM_CONTROL"
echo "CONTRIBUTORS=$CONTRIBUTORS"
echo "SIR=$SIR"
echo "APE=$APE"
echo "VAULT_EXTERNAL=$VAULT_EXTERNAL"
echo "VAULT=$VAULT"
```

## Notes

-   Add `--gas-limit 50000000` if gas estimation fails
-   Add `--legacy` if EIP-1559 transactions fail
-   Use `sleep 2` between transactions to avoid nonce issues
-   MegaETH testnet chain ID: 6343
-   MegaETH supports up to 200M gas per transaction and 512KB contract size
