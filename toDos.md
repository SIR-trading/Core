# Emergency Admin Withdrawals

When only withdrawals are allowed. Add a time interval after which the owner can withdraw all the funds without interacting with the oracle.
This is to save the TVL if the oracle is buggy and reverts.

# Optimizations

Minimize # hot SLOADs

# Periphery

-   Add quoting functions
-   Add getReserves function
-   Add donate() function which basically transfer TEA to Vault
-   Function that returns the amount of TEA and amount in the reserve LP.
-   Function that returns the amount of APE and amount in the reserve of apes.

# Core

-   Consider adding more leverage tiers by rerunning tests
-   Index VaultStates by vaultId instead of by VaultParameters. That way I can save gas by just passing vaultId to the mint and burn functions.

# Marketing

-   Airdrops? https://twitter.com/sassal0x/status/1756839032070508746
    -   Airdrop tokens to ETH stakers (in particular, home stakers)
    -   Allocate up to 1% of the token supply to @ProtocolGuild

# SIR contracts

-   Hard wire allocations with 30% of the tokens.
-   10% is allocated to a multisig for post-launch contributors and as treasury.
-   10% is for investors
-   10% for pre-launch contributors
-   No changing allocations post-launch

# Tests

-   Test Vault state divergence as it is updated consecutively without minting or burning anything.
-   Why is the price not updated on every block?!

# UI

-   Vaults allow minting APE to the point that it saturates them. However, do not allow that in the UI because we wish to stay in the power zone.
