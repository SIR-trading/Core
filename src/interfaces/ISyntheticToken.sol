// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import "uniswap-v2-core/interfaces/IERC20.sol";

interface ISyntheticToken is IERC20 {
    event Liquidation(uint256 amount);

    function DEBT_TOKEN() external returns (address);

    function COLLATERAL_TOKEN() external returns (address);

    function LEVERAGE_TIER() external returns (int8);

    /**
     *  @notice All holders could potentially be liquidated.
     *  @return true if all balances and the token supply are 0
     */
    function isLiquidated() external view returns (bool);
}
