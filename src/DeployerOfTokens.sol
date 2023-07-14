// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {FullMath} from "./libraries/FullMath.sol";
import {SyntheticToken, IERC20} from "./SyntheticToken.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {VaultStructs} from "./interfaces/VaultStructs.sol";

contract DeployerOfTokens {
    bytes16 private constant _SYMBOLS = "0123456789abcdef";

    VaultStructs.TokenParameters internal tokenParameters;

    // Deploy TEA and APE tokens
    function deploy(
        uint256 vaultId,
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external returns (SyntheticToken tea, SyntheticToken ape) {
        // Get salts that produce addresses that start with hex chars `7ea` and `a9e`
        bytes32 saltTEA = _getSaltTEA(vaultId);
        bytes32 saltAPE = _getSaltAPE(vaultId);

        /**
         * Set the parameters that will be read during the instantiation of the tokens.
         * This pattern is used to avoid passing arguments to the constructor explicitly.
         */
        tokenParameters = VaultStructs.TransientParameters({
            name: _generateNameTEA(debtToken, collateralToken, leverageTier),
            symbol: _generateSymbol("TEA", vaultId),
            decimals: IERC20(debtToken).decimals()
        });

        // Deploy TEA
        tea = new SyntheticToken{salt: saltTEA}();

        // Transient storage for APE token
        tokenParameters = VaultStructs.TransientParameters({
            name: _generateNameAPE(debtToken, collateralToken, leverageTier),
            symbol: _generateSymbol("APE", vaultId),
            decimals: IERC20(collateralToken).decimals()
        });

        // Deploy APE
        ape = new SyntheticToken{salt: saltAPE}();

        // Free memory
        delete tokenParameters;
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

    function _generateSymbol(string memory symbolPrefix, uint256 vaultId) private pure returns (string memory) {
        return string(abi.encodePacked(symbolPrefix, Strings.toString(vaultId)));
    }

    function _getSaltTEA(uint48 vaultId) private returns (bytes32 saltTEA) {
        /**
            DUMMY IMPLEMENTATION
            I WANT TO GET MINED SALTS THAT RETURN ADDRESSES WITH PREFIXES 7ea AND a9e 
         */
        saltTEA = bytes32(vaultId * 2);
    }

    function _getSaltAPE(uint48 vaultId) private returns (bytes32 saltAPE) {
        /**
            DUMMY IMPLEMENTATION
            I WANT TO GET MINED SALTS THAT RETURN ADDRESSES WITH PREFIXES 7ea AND a9e 
         */
        saltAPE = bytes32(vaultId * 2 + 1);
    }

    function getAddress(uint256 vaultId, bool isTEA) internal returns (address) {
        bytes32 salt = isTEA ? _getSaltTEA(vaultId) : _getSaltAPE(vaultId);

        return
            address(
                uint160(
                    uint(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                address(this),
                                salt,
                                keccak256(type(SyntheticToken).creationCode) // PRECOMPUTE FOR MAINNET LAUNCH
                            )
                        )
                    )
                )
            );
    }
}
