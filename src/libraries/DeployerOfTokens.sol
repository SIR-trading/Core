// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import "../TEA.sol";
import "../APE.sol";

library DeployerOfTokens {
    // Deploy TEA
    function deploy(address debtToken, address collateralToken, int8 leverageTier)
        external
        returns (TEA tea, APE ape)
    {
        tea = new TEA{salt: hex"00"}(debtToken, collateralToken, leverageTier);
        ape = new APE{salt: hex"00"}(debtToken, collateralToken, leverageTier);
    }
}
