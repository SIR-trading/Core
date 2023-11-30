// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";
import {VaultStructs} from "./libraries/VaultStructs.sol";
import {VaultEvents} from "./interfaces/VaultEvents.sol";

// Contracts
import {APE} from "./APE.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

contract VaultExternal is VaultEvents {
    address public immutable VAULT;

    modifier onlyVault() {
        require(msg.sender == VAULT);
        _;
    }

    VaultStructs.Parameters[] public paramsById; // Never used in Vault.sol. Just for users to access vault parameters by vault ID.

    // Used to pass parameters to the APE token constructor
    VaultStructs.TokenParameters private _transientTokenParameters;

    constructor(address vault_) {
        VAULT = vault_;

        /** We rely on vaultId == 0 to test if a particular vault exists.
            To make sure vault Id 0 is never used, we push one empty element as first entry.
         */
        paramsById.push(VaultStructs.Parameters(address(0), address(0), 0));
    }

    function latestTokenParams()
        external
        view
        returns (
            string memory name,
            string memory symbol,
            uint8 decimals,
            address debtToken,
            address collateralToken,
            int8 leverageTier
        )
    {
        name = _transientTokenParameters.name;
        symbol = _transientTokenParameters.symbol;
        decimals = _transientTokenParameters.decimals;

        VaultStructs.Parameters memory params = paramsById[paramsById.length - 1];
        debtToken = params.debtToken;
        collateralToken = params.collateralToken;
        leverageTier = params.leverageTier;
    }

    // Deploy APE token
    function deployAPE(
        address debtToken,
        address collateralToken,
        int8 leverageTier
    ) external onlyVault returns (uint256 vaultId) {
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

        emit VaultInitialized(debtToken, collateralToken, leverageTier, vaultId);
    }

    function teaURI(uint256 vaultId, uint256 totalSupply) external view returns (string memory) {
        string memory vaultIdStr = Strings.toString(vaultId);
        return
            string.concat(
                "data:application/json;charset=UTF-8,%7B%22name%22%3A%22LP%20Token%20for%20APE-",
                vaultIdStr,
                "%22%2C%22symbol%22%3A%22TEA-",
                vaultIdStr,
                "%22%2C%22decimals%22%3A",
                Strings.toString(IERC20(paramsById[vaultId].collateralToken).decimals()),
                "%2C%22chainId%22%3A1%2C%22debtToken%22%3A%22",
                Strings.toHexString(paramsById[vaultId].debtToken),
                "%22%2C%22collateralToken%22%3A%22",
                Strings.toHexString(paramsById[vaultId].collateralToken),
                "%22%2C%22leverageTier%22%3A",
                Strings.toString(paramsById[vaultId].leverageTier),
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
}
