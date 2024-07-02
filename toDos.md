# Emergency Admin Withdrawals

When only withdrawals are allowed. Add a time interval after which the owner can withdraw all the funds without interacting with the oracle.
This is to save the TVL if the oracle is buggy and reverts.

# Optimizations

-   Reduce Oracle queries? For example reduce checking the optimal Uniswap pool. Reduce TWAP length increments. Reduce interval between TWAP length increments.
-   By accessing parameters by vaultId instead of VaultParameters we can probably save a 600n gas.

# Periphery

-   Add quoting functions
-   Add getReserves function
-   Add donate() function which basically transfer TEA to Vault
-   Function that returns the amount of TEA and amount in the reserve LP.
-   Function that returns the amount of APE and amount in the reserve of apes.
-   Add getLPerCurrentAllocation and getLPerContributorAllocation which returns current issuance

# Core

-   Make all external functions accept and return structs (when available) rather than their separate parameters?
-   Make an event that shows where all the fees are going for every mint/burn? E.g., Mint(uint48 collateralDeposited, collateralFeeToStakers,collateralFeeToLPers,collateralFeeToPOL)

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
