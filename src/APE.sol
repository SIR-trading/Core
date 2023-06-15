// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Smart contracts
import "./SyntheticToken.sol";

contract APE is SyntheticToken {
    constructor(address debtToken, address collateralToken, int8 leverageTier)
        SyntheticToken( 
            _generateName(debtToken, collateralToken, leverageTier),
            "APE",
            IERC20(collateralToken).decimals(),
            debtToken,
            collateralToken,
            leverageTier
        )
    {}

    /**
     * @param addrDebtToken Address of the rewards token
     *     @param addrCollateralToken Address of the collateral token
     *     @param leverageTier Ranges between -3 to 10.
     *     @notice The target collateralization ratio for TEA is given by r = 1+2**(-2*leverageTier-1).
     */

    function _generateName(address addrDebtToken, address addrCollateralToken, int8 leverageTier)
        private
        view
        returns (string memory)
    {
        string memory leverageStr;
        if (leverageTier >= 0) {
            return Strings.toString(1 + 2 ** uint256(int256(leverageTier)));
        } else {
            // Get leverage tier string without decimal point
            uint256 negLeverageTier = uint256(int256(-leverageTier));
            bytes memory nonDecimalPoinStr = bytes(
                Strings.toString(FullMath.mulDiv(1 + 2 ** negLeverageTier, 10 ** negLeverageTier, 2 ** negLeverageTier))
            );

            // Add decimal point
            bytes memory decimalPartStr = new bytes(nonDecimalPoinStr.length - 2);
            for (uint256 i = 0; i < decimalPartStr.length; i++) {
                decimalPartStr[i] = nonDecimalPoinStr[i + 2];
            }
            leverageStr = string(abi.encodePacked("1.", decimalPartStr));
        }

        return string(
            abi.encodePacked(
                "Tokenized ",
                IERC20(addrCollateralToken).symbol(),
                " / ",
                IERC20(addrDebtToken).symbol(),
                " with x",
                leverageStr,
                " leverage"
            )
        );
    }
}
