// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";
import {VaultStructs} from "../libraries/VaultStructs.sol";

// Libraries
import {FullMath} from "./FullMath.sol";

// Contracts
import {APE} from "../APE.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

import "forge-std/Test.sol";

library DeployerOfAPE {
    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId
    );

    // Deploy APE token
    function deploy(
        VaultStructs.TokenParameters storage tokenParameters,
        uint256 vaultId,
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external {
        /**
         * Set the parameters that will be read during the instantiation of the tokens.
         * This pattern is used to avoid passing arguments to the constructor explicitly.
         */
        tokenParameters.name = _generateName(debtToken, collateralToken, leverageTier);
        tokenParameters.symbol = string.concat("APE-", Strings.toString(vaultId));
        tokenParameters.decimals = IERC20(collateralToken).decimals();

        // Deploy APE
        new APE{salt: bytes32(vaultId)}();

        emit VaultInitialized(debtToken, collateralToken, leverageTier, vaultId);
    }

    /** @param addrDebtToken Address of the unclaimedRewards token
        @param addrCollateralToken Address of the collateral token
        @param leverageTier Ranges between -3 to 2.
     */

    function _generateName(
        address addrDebtToken,
        address addrCollateralToken,
        int8 leverageTier
    ) private view returns (string memory) {
        assert(leverageTier >= -3 && leverageTier <= 2);
        string memory leverageStr;
        if (leverageTier == -3) leverageStr = "1.125";
        else if (leverageTier == -2) leverageStr = "1.25";
        else if (leverageTier == -1) leverageStr = "1.5";
        else if (leverageTier == 0) leverageStr = "2";
        else if (leverageTier == 1) leverageStr = "3";
        else if (leverageTier == 2) leverageStr = "5";

        return
            string(
                abi.encodePacked(
                    "Tokenized ",
                    IERC20(addrCollateralToken).symbol(),
                    "/",
                    IERC20(addrDebtToken).symbol(),
                    " with x",
                    leverageStr,
                    " leverage"
                )
            );
    }
}
