# Optimizations

-   Reduce Oracle queries? For example reduce checking the optimal Uniswap pool. Reduce TWAP length increments. Reduce interval between TWAP length increments.

# Periphery

-   Add getReserves function
-   Add donate() function which basically transfer TEA to Vault
-   Function that returns the amount of TEA and amount in the reserve LP.
-   Function that returns the amount of APE and amount in the reserve of apes.
-   Add getLPerCurrentAllocation and getLPerContributorAllocation which returns current issuance

# Core

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

-   ADD ORACLE TEST THAT CHECKS ON ETH PRICE FROM 9653500 UNTIL 1 DAY AND 6H LATER FOR MAX PRICE VOLATILITY. CHECK IF TRUNCATION IS ACTIVATED.
-   Add non-fuzzy mint test in Vault to study gas optimization.

# UI

-   Vaults allow minting APE to the point that it saturates them. However, do not allow that in the UI because we wish to stay in the power zone.

# Docs

-   Add a Ponzinomics section under Liquidity that mentions how LPers also pay fees to LPers.
