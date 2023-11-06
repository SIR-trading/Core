// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {Strings} from "openzeppelin/utils/Strings.sol";

library ExternalFunctions {
    function uri(
        uint256 vaultId,
        address debtToken,
        address collateralToken,
        int8 leverageTier,
        uint256 totalSupply
    ) external view returns (string memory) {
        string memory vaultIdStr = Strings.toString(vaultId);
        return
            string.concat(
                "data:application/json;charset=UTF-8,%7B%22name%22%3A%22LP%20Token%20for%20APE-",
                vaultIdStr,
                "%22%2C%22symbol%22%3A%22TEA-",
                vaultIdStr,
                "%22%2C%22decimals%22%3A",
                Strings.toString(IERC20(collateralToken).decimals()),
                "%2C%22chainId%22%3A1%2C%22debtToken%22%3A%22",
                Strings.toHexString(debtToken),
                "%22%2C%22collateralToken%22%3A%22",
                Strings.toHexString(collateralToken),
                "%22%2C%22leverageTier%22%3A",
                Strings.toString(leverageTier),
                "%2C%22totalSupply%22%3A",
                Strings.toString(totalSupply),
                "%7D"
            );
    }
}
