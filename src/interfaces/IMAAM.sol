// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import "@uniswap/v2-core/contracts/interfaces/IERC20.sol";

/**
    @notice MAAM is liquidity providers' token in the SIR protocol. It is also a rebasing token.
    The rebasing mechanism is not just a cosmetic feature but necessary for its function. Otherwise its totalSupply() would be unbounded
    due to the price fluctuations of the leverage + liquidations.
    @notice Highly modified from Solmate (https://github.com/Rari-Capital/solmate/blob/main/src/tokens/ERC20.sol)
    @dev Floating point operations on balances (_nonRebasingBalances) round down (to zero)
    Floating point operations on the total supply (nonRebasingSupply) round up (to positive infinity)
    For this reason, the sum of all internal floating-point balances may not be equal to the floating-poin supply (nonRebasingSupply),
    specially when the balances and supply in normal integer numbers occupy more than 113 bits (the accuracy of FP) 
 */
interface IMAAM is IERC20 {
    event Liquidation(uint256 amount);

    function nonRebasingSupply() external view returns (bytes16);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferAll(address to) external returns (bool);

    function nonRebasingSupplyExcludePOL() external view returns (bytes16);

    function balanceOf(address account) external view returns (uint256);

    function nonRebasingBalanceOf(address account) external view returns (bytes16);

    function parametersForSIRContract(address account)
        external
        view
        returns (
            bytes16,
            bytes16,
            bytes16
        );

    function numberOfLiquidations() external view returns (uint256);
}
