// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Smart contracts
import "./SyntheticToken.sol";

contract TEA is SyntheticToken {
    constructor(
        address debtToken,
        address collateralToken,
        int8 leverageTier
    )
        SyntheticToken(
            _generateName(debtToken, collateralToken, leverageTier),
            "TEA",
            IERC20(debtToken).decimals(),
            debtToken,
            collateralToken,
            leverageTier
        )
    {}

    /**
        @param addrDebtToken Address of the rewards token
        @param addrCollateralToken Address of the collateral token
        @param leverageTier Ranges between -3 to 10.
        @notice The target collateralization ratio for TEA is given by r = 1+2**(-2*leverageTier-1).
     */
    function _generateName(
        address addrDebtToken,
        address addrCollateralToken,
        int8 leverageTier
    ) private view returns (string memory) {
        string memory collateralizationStr;
        if (leverageTier == 6) collateralizationStr = "101.5625";
        else if (leverageTier == 5) collateralizationStr = "103.125";
        else if (leverageTier == 4) collateralizationStr = "106.25";
        else if (leverageTier == 3) collateralizationStr = "112.5";
        else if (leverageTier == 2) collateralizationStr = "125";
        else if (leverageTier == 1) collateralizationStr = "150";
        else if (leverageTier == 0) collateralizationStr = "200";
        else if (leverageTier < 0) return Strings.toString(100 * (1 + uint256(int256(-leverageTier))));
        else {
            // Get collateralization string without decimal point
            bytes memory nonDecimalPoinStr = bytes(
                Strings.toString(
                    FullMath.mulDiv(
                        1 + 2**uint256(int256(leverageTier)),
                        10**uint256(int256(leverageTier)),
                        2**uint256(int256(leverageTier))
                    )
                )
            );

            // Add decimal point
            bytes memory decimalPartStr = new bytes(nonDecimalPoinStr.length - 6);
            for (uint256 i = 0; i < decimalPartStr.length; i++) decimalPartStr[i] = nonDecimalPoinStr[i + 6];
            collateralizationStr = string(abi.encodePacked("100.", decimalPartStr));
        }

        return
            string(
                abi.encodePacked(
                    "Stable token pegged to ",
                    IERC20(addrDebtToken).symbol(),
                    " backed by ",
                    IERC20(addrCollateralToken).symbol(),
                    " with a ",
                    collateralizationStr,
                    "% collateralization ratio"
                )
            );
    }
}
