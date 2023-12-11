// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";
import {VaultStructs} from "./VaultStructs.sol";

// Libraries
import {TickMathPrecision} from "./TickMathPrecision.sol";

// Contracts
import {APE} from "../APE.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

library VaultExternal {
    // Deploy APE token
    function deployAPE(
        VaultStructs.Parameters[] storage paramsById,
        VaultStructs.TokenParameters storage _transientTokenParameters,
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external returns (uint256 vaultId) {
        // Next vault ID
        vaultId = paramsById.length;
        require(vaultId <= type(uint40).max); // It has to fit in a uint40

        // Push parameters before deploying tokens, because they are accessed by the tokens' constructors
        paramsById.push(VaultStructs.Parameters(debtToken, collateralToken, leverageTier));

        /**
         * Set the parameters that will be read during the instantiation of the tokens.
         * This pattern is used to avoid passing arguments to the constructor explicitly.
         */
        _transientTokenParameters.name = _generateName(debtToken, collateralToken, leverageTier);
        _transientTokenParameters.symbol = string.concat("APE-", Strings.toString(vaultId));
        _transientTokenParameters.decimals = IERC20(collateralToken).decimals();

        // Deploy APE
        new APE{salt: bytes32(vaultId)}();
    }

    function teaURI(
        VaultStructs.Parameters[] storage paramsById,
        uint256 vaultId,
        uint256 totalSupply
    ) external view returns (string memory) {
        string memory vaultIdStr = Strings.toString(vaultId);

        VaultStructs.Parameters memory params = paramsById[vaultId];

        return
            string.concat(
                "data:application/json;charset=UTF-8,%7B%22name%22%3A%22LP%20Token%20for%20APE-",
                vaultIdStr,
                "%22%2C%22symbol%22%3A%22TEA-",
                vaultIdStr,
                "%22%2C%22decimals%22%3A",
                Strings.toString(IERC20(params.collateralToken).decimals()),
                "%2C%22chainId%22%3A1%2C%22debtToken%22%3A%22",
                Strings.toHexString(params.debtToken),
                "%22%2C%22collateralToken%22%3A%22",
                Strings.toHexString(params.collateralToken),
                "%22%2C%22leverageTier%22%3A",
                Strings.toString(params.leverageTier),
                "%2C%22totalSupply%22%3A",
                Strings.toString(totalSupply),
                "%7D"
            );
    }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

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

    /// @dev Make sure before calling that apesReserve + lpReserve does not OF uint152
    function updateState(
        VaultStructs.State memory state_,
        VaultStructs.Reserves memory reserves,
        int8 leverageTier
    ) external pure {
        unchecked {
            state_.daoFees = reserves.daoFees;
            state_.totalReserves = reserves.apesReserve + reserves.lpReserve;

            if (state_.totalReserves == 0) return; // When the reserve is empty, tickPriceSatX42 is undetermined

            // Compute tickPriceSatX42
            if (reserves.apesReserve == 0) {
                state_.tickPriceSatX42 = type(int64).max;
            } else if (reserves.lpReserve == 0) {
                state_.tickPriceSatX42 = type(int64).min;
            } else {
                /**
                 * Decide if we are in the power or saturation zone
                 * Condition for power zone: A < (l-1) L where l=1+2^leverageTier
                 */
                uint8 absLeverageTier = leverageTier >= 0 ? uint8(leverageTier) : uint8(-leverageTier);
                bool isPowerZone;
                if (leverageTier > 0) {
                    if (
                        uint256(reserves.apesReserve) << absLeverageTier < reserves.lpReserve
                    ) // Cannot OF because apesReserve is an uint152, and |leverageTier|<=3
                    {
                        isPowerZone = true;
                    } else {
                        isPowerZone = false;
                    }
                } else {
                    if (
                        reserves.apesReserve < uint256(reserves.lpReserve) << absLeverageTier
                    ) // Cannot OF because apesReserve is an uint152, and |leverageTier|<=3
                    {
                        isPowerZone = true;
                    } else {
                        isPowerZone = false;
                    }
                }

                if (isPowerZone) {
                    /**
                     * PRICE IN POWER ZONE
                     * priceSat = price*(R/(lA))^(r-1)
                     */

                    int256 tickRatioX42 = TickMathPrecision.getTickAtRatio(
                        leverageTier >= 0 ? state_.totalReserves : uint256(state_.totalReserves) << absLeverageTier, // Cannot OF cuz totalReserves is uint152, and |leverageTier|<=3
                        (uint256(reserves.apesReserve) << absLeverageTier) + reserves.apesReserve // Cannot OF cuz apesReserve is uint152, and |leverageTier|<=3
                    );

                    // Compute saturation price
                    int256 temptickPriceSatX42 = state_.tickPriceX42 +
                        (leverageTier >= 0 ? tickRatioX42 >> absLeverageTier : tickRatioX42 << absLeverageTier);

                    // Check if overflow
                    if (temptickPriceSatX42 > type(int64).max) state_.tickPriceSatX42 = type(int64).max;
                    else state_.tickPriceSatX42 = int64(temptickPriceSatX42);
                } else {
                    /**
                     * PRICE IN SATURATION ZONE
                     * priceSat = r*price*L/R
                     */
                    int256 tickRatioX42 = TickMathPrecision.getTickAtRatio(
                        leverageTier >= 0 ? uint256(state_.totalReserves) << absLeverageTier : state_.totalReserves,
                        (uint256(reserves.lpReserve) << absLeverageTier) + reserves.lpReserve
                    );

                    // Compute saturation price
                    int256 temptickPriceSatX42 = state_.tickPriceX42 - tickRatioX42;

                    // Check if underflow
                    if (temptickPriceSatX42 < type(int64).min) state_.tickPriceSatX42 = type(int64).min;
                    else state_.tickPriceSatX42 = int64(temptickPriceSatX42);
                }
            }
        }
    }
}
