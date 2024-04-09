# Emergency Admin Withdrawals

When only withdrawals are allowed. Add a time interval after which the owner can withdraw all the funds without interacting with the oracle.
This is to save the TVL if the oracle is buggy and reverts.

# Optimizations

Minimize # hot SLOADs

# Periphery

-   Add quoting functions
-   Add getReserves function
-   Add donate() function which basically transfer TEA to Vault

# Core

-   Do not distribute SIR to POL. Easy to hack without extra gas in the current implementation because totalSupply and vaultBalance share the same slot.
-   Remove SIR withdrawal functions since there is no SIR to collect.
-   Code Staker which is allowed to withdraw fees. Staker inherits SIR? Stakers do not get SIR from POL.
-   Consider adding more leverage tiers by rerunning tests

# Marketing

-   Airdrops? https://twitter.com/sassal0x/status/1756839032070508746
    -   Airdrop tokens to ETH stakers (in particular, home stakers)
    -   Allocate up to 1% of the token supply to @ProtocolGuild

# Contributors

-   Consider not allowing changes on contributors allocations at mainnet
-   Instead allocate a fix amount of SIR to post mainnet.

# SIR contracts

-   Hard wire allocations with 30% of the tokens.
-   10% is allocated to a multisig for post-launch contributors and as treasury.
-   10% is for investors
-   10% for pre-launch contributors
-   No changing allocations post-launch
