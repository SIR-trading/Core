// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {VaultStructs} from "./VaultStructs.sol";

// Libraries
import {TickMathPrecision} from "./TickMathPrecision.sol";
import {SaltedAddress} from "./SaltedAddress.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {SystemConstants} from "./SystemConstants.sol";

// Contracts
import {APE} from "../APE.sol";
import {Oracle} from "../Oracle.sol";

library VaultExternal {
    error VaultAlreadyInitialized();
    error LeverageTierOutOfRange();
    error VaultDoesNotExist();

    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId
    );

    // Deploy APE token
    function deployAPE(
        Oracle oracle,
        VaultStructs.State storage state,
        VaultStructs.Parameters[] storage paramsById,
        VaultStructs.TokenParameters storage transientTokenParameters,
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external {
        if (leverageTier > 2 || leverageTier < -3) revert LeverageTierOutOfRange();

        /**
         * 1. This will initialize the oracle for this pair of tokens if it has not been initialized before.
         * 2. It also will revert if there are no pools with liquidity, which implicitly solves the case where the user
         *    tries to instantiate an invalid pair of tokens like address(0)
         */
        oracle.initialize(debtToken, collateralToken);

        // Check the vault has not been initialized previously
        if (state.vaultId != 0) revert VaultAlreadyInitialized();

        // Next vault ID
        uint256 vaultId = paramsById.length;
        require(vaultId <= type(uint48).max); // It has to fit in a uint48

        // Push parameters before deploying tokens, because they are accessed by the tokens' constructors
        paramsById.push(VaultStructs.Parameters(debtToken, collateralToken, leverageTier));

        /**
         * Set the parameters that will be read during the instantiation of the tokens.
         * This pattern is used to avoid passing arguments to the constructor explicitly.
         */
        transientTokenParameters.name = _generateName(debtToken, collateralToken, leverageTier);
        transientTokenParameters.symbol = string.concat("APE-", Strings.toString(vaultId));
        transientTokenParameters.decimals = APE(collateralToken).decimals();

        // Deploy APE
        new APE{salt: bytes32(vaultId)}();

        // Save vaultId
        state.vaultId = uint48(vaultId);

        emit VaultInitialized(debtToken, collateralToken, leverageTier, vaultId);
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
                Strings.toString(APE(params.collateralToken).decimals()),
                "%2C%22chain_id%22%3A1%2C%22vault_id%22%3A",
                vaultIdStr,
                "%2C%22debt_token%22%3A%22",
                Strings.toHexString(params.debtToken),
                "%22%2C%22collateral_token%22%3A%22",
                Strings.toHexString(params.collateralToken),
                "%22%2C%22leverage_tier%22%3A",
                Strings.toString(params.leverageTier),
                "%2C%22total_supply%22%3A",
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
                    APE(addrCollateralToken).symbol(),
                    "/",
                    APE(addrDebtToken).symbol(),
                    " with x",
                    leverageStr,
                    " leverage"
                )
            );
    }

    function getReserves(
        bool isAPE,
        VaultStructs.State memory state,
        address collateralToken,
        int8 leverageTier,
        int64 tickPriceX42
    ) external view returns (VaultStructs.Reserves memory reserves, APE ape) {
        unchecked {
            reserves.tickPriceX42 = tickPriceX42;

            // Derive APE address if needed
            if (isAPE) ape = APE(SaltedAddress.getAddress(address(this), state.vaultId));

            // Reserve is empty only in the 1st mint
            if (state.reserve != 0) {
                assert(state.reserve >= 2);

                if (state.tickPriceSatX42 == type(int64).min) {
                    // type(int64).min represents -∞ => reserveLPers = 0
                    reserves.reserveApes = state.reserve - 1;
                    reserves.reserveLPers = 1;
                } else if (state.tickPriceSatX42 == type(int64).max) {
                    // type(int64).max represents +∞ => reserveApes = 0
                    reserves.reserveApes = 1;
                    reserves.reserveLPers = state.reserve - 1;
                } else {
                    uint8 absLeverageTier = leverageTier >= 0 ? uint8(leverageTier) : uint8(-leverageTier);

                    if (tickPriceX42 < state.tickPriceSatX42) {
                        /**
                         * POWER ZONE
                         * A = (price/priceSat)^(l-1) R/l
                         * price = 1.0001^tickPriceX42 and priceSat = 1.0001^tickPriceSatX42
                         * We use the fact that l = 1+2^leverageTier
                         * reserveApes is rounded up
                         */
                        int256 poweredTickPriceDiffX42 = leverageTier > 0
                            ? (int256(state.tickPriceSatX42) - tickPriceX42) << absLeverageTier
                            : (int256(state.tickPriceSatX42) - tickPriceX42) >> absLeverageTier;

                        if (poweredTickPriceDiffX42 > SystemConstants.MAX_TICK_X42) {
                            reserves.reserveApes = 1;
                        } else {
                            /** Rounds up reserveApes, rounds down reserveLPers.
                                Cannot overflow.
                                64 bits because getRatioAtTick returns a Q64.64 number.
                            */
                            uint256 poweredPriceRatioX64 = TickMathPrecision.getRatioAtTick(
                                int64(poweredTickPriceDiffX42)
                            );

                            reserves.reserveApes = uint144(
                                _divRoundUp(
                                    uint256(state.reserve) << (leverageTier >= 0 ? 64 : 64 + absLeverageTier),
                                    poweredPriceRatioX64 + (poweredPriceRatioX64 << absLeverageTier)
                                )
                            );

                            assert(reserves.reserveApes != 0); // It should never be 0 because it's rounded up. Important for the protocol that it is at least 1.
                        }

                        reserves.reserveLPers = state.reserve - reserves.reserveApes;
                    } else {
                        /**
                         * SATURATION ZONE
                         * LPers are 100% pegged to debt token.
                         * L = (priceSat/price) R/r
                         * price = 1.0001^tickPriceX42 and priceSat = 1.0001^tickPriceSatX42
                         * We use the fact that lr = 1+2^-leverageTier
                         * reserveLPers is rounded up
                         */
                        int256 tickPriceDiffX42 = int256(tickPriceX42) - state.tickPriceSatX42;

                        if (tickPriceDiffX42 > SystemConstants.MAX_TICK_X42) {
                            reserves.reserveLPers = 1;
                        } else {
                            /** Rounds up reserveLPers, rounds down reserveApes.
                                Cannot overflow.
                                64 bits because getRatioAtTick returns a Q64.64 number.
                            */
                            uint256 priceRatioX64 = TickMathPrecision.getRatioAtTick(int64(tickPriceDiffX42));

                            reserves.reserveLPers = uint144(
                                _divRoundUp(
                                    uint256(state.reserve) << (leverageTier < 0 ? 64 : 64 + absLeverageTier),
                                    priceRatioX64 + (priceRatioX64 << absLeverageTier)
                                )
                            );

                            assert(reserves.reserveLPers != 0); // It should never be 0 because it's rounded up. Important for the protocol that it is at least 1.
                        }

                        reserves.reserveApes = state.reserve - reserves.reserveLPers;
                    }
                }
            }
        }
    }

    function _divRoundUp(uint256 a, uint256 b) private pure returns (uint256) {
        unchecked {
            return (a - 1) / b + 1;
        }
    }
}
