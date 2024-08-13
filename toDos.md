# Gas Optimizations

-   Reduce Oracle queries? For example reduce checking the optimal Uniswap pool. Reduce TWAP length increments. Reduce interval between TWAP length increments.
-   Use constant bytes32 for symbol instead of string?
-   Use transient storage for transientTokenParameters in VaultExternal when ready in Solidity
-   Use `unchecked` when possible

# Periphery

-   Add getLPerCurrentAllocation and getLPerContributorAllocation which returns current issuance

# Marketing

    -   Allocate up to 1% of the token supply to @ProtocolGuild

# Tokenomics

-   Hard wire allocations with 30% of the tokens.
-   10% is allocated to a multisig for post-launch contributors and as treasury.
-   10% is for investors
-   10% for pre-launch contributors
-   No changing allocations post-launch

# UI

-   Vaults allow minting APE to the point that it saturates them. However, do not allow that in the UI because we wish to stay in the power zone.

# Docs

-   Add a Ponzinomics section under Liquidity that mentions how LPers also pay fees to LPers.
