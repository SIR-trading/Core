// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {SyntheticToken, IERC20} from "../SyntheticToken.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

library DeployerOfTokens {
    // Deploy TEA and APE tokens
    function deploy(
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external returns (SyntheticToken tea, SyntheticToken ape) {
        tea = new SyntheticToken{salt: hex"00"}();
        ape = new SyntheticToken{salt: hex"01"}();
        tea.initialize(
            _generateNameTEA(debtToken, collateralToken, leverageTier),
            "TEA",
            IERC20(debtToken).decimals(),
            debtToken,
            collateralToken,
            leverageTier
        );
        ape.initialize(
            _generateNameAPE(debtToken, collateralToken, leverageTier),
            "APE",
            IERC20(collateralToken).decimals(),
            debtToken,
            collateralToken,
            leverageTier
        );
    }

    /**
     * @param addrDebtToken Address of the rewards token
     *     @param addrCollateralToken Address of the collateral token
     *     @param leverageTier Ranges between -3 to 10.
     *     @notice The target collateralization ratio for TEA is given by r = 1+2**(-2*leverageTier-1).
     */

    function _generateNameAPE(
        address addrDebtToken,
        address addrCollateralToken,
        int8 leverageTier
    ) private view returns (string memory) {
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

        return
            string(
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

    /**
     * @param addrDebtToken Address of the rewards token
     *     @param addrCollateralToken Address of the collateral token
     *     @param leverageTier Ranges between -3 to 10.
     *     @notice The target collateralization ratio for TEA is given by r = 1+2**(-2*leverageTier-1).
     */
    function _generateNameTEA(
        address addrDebtToken,
        address addrCollateralToken,
        int8 leverageTier
    ) private view returns (string memory) {
        string memory collateralizationStr;
        if (leverageTier == 6) {
            collateralizationStr = "101.5625";
        } else if (leverageTier == 5) {
            collateralizationStr = "103.125";
        } else if (leverageTier == 4) {
            collateralizationStr = "106.25";
        } else if (leverageTier == 3) {
            collateralizationStr = "112.5";
        } else if (leverageTier == 2) {
            collateralizationStr = "125";
        } else if (leverageTier == 1) {
            collateralizationStr = "150";
        } else if (leverageTier == 0) {
            collateralizationStr = "200";
        } else if (leverageTier < 0) {
            return Strings.toString(100 * (1 + uint256(int256(-leverageTier))));
        } else {
            // Get collateralization string without decimal point
            bytes memory nonDecimalPoinStr = bytes(
                Strings.toString(
                    FullMath.mulDiv(
                        1 + 2 ** uint256(int256(leverageTier)),
                        10 ** uint256(int256(leverageTier)),
                        2 ** uint256(int256(leverageTier))
                    )
                )
            );

            // Add decimal point
            bytes memory decimalPartStr = new bytes(nonDecimalPoinStr.length - 6);
            for (uint256 i = 0; i < decimalPartStr.length; i++) {
                decimalPartStr[i] = nonDecimalPoinStr[i + 6];
            }
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
