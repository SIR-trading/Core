// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";
import {VaultStructs} from "./interfaces/VaultStructs.sol";

// Libraries
import {SaltedAddress} from "./libraries/SaltedAddress.sol";
import {FullMath} from "./libraries/FullMath.sol";

// Contracts
import {APE} from "./APE.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

library DeployerOfAPE {
    // Deploy APE token
    function deploy(
        VaultStructs.TokenParameters storage tokenParameters,
        uint256 vaultId,
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external returns (APE ape) {
        // Get salts that produce addresses that start with hex chars `a9e`
        bytes32 saltAPE = SaltedAddress.getSalt(vaultId);

        /**
         * Set the parameters that will be read during the instantiation of the tokens.
         * This pattern is used to avoid passing arguments to the constructor explicitly.
         */
        tokenParameters = VaultStructs.TokenParameters({
            name: _generateName(debtToken, collateralToken, leverageTier),
            symbol: _generateSymbol("APE", vaultId),
            decimals: IERC20(collateralToken).decimals()
        });

        // Deploy APE
        ape = new APE{salt: saltAPE}();
    }

    /**
     * @param addrDebtToken Address of the rewards token
     *     @param addrCollateralToken Address of the collateral token
     *     @param leverageTier Ranges between -3 to 10.
     *     @notice The target collateralization ratio for TEA is given by r = 1+2**(-2*leverageTier-1).
     */

    function _generateName(
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

    function _generateSymbol(string memory symbolPrefix, uint256 vaultId) private pure returns (string memory) {
        return string(abi.encodePacked(symbolPrefix, Strings.toString(vaultId)));
    }
}
