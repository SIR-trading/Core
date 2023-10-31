// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {DeployerOfAPE, VaultStructs} from "src/libraries/DeployerOfAPE.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SaltedAddress} from "src/libraries/SaltedAddress.sol";

contract DeployerOfAPETest is Test {
    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId
    );

    // IDeployerOfAPE deployer;
    VaultStructs.TokenParameters private _transientTokenParameters;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);
    }

    function testFuzz_deployETHvsUSDC(uint40 vaultId, int8 leverageTier) public {
        vm.assume(vaultId > 0);
        leverageTier = int8(bound(leverageTier, -3, 2)); // Only accepted values in the system

        vm.mockCall(
            address(this),
            abi.encodeWithSelector(IVault.latestTokenParams.selector),
            abi.encode(
                _transientTokenParameters.name,
                _transientTokenParameters.symbol,
                _transientTokenParameters.decimals,
                Addresses._ADDR_USDC,
                Addresses._ADDR_WETH,
                leverageTier
            )
        );

        vm.expectEmit();
        emit VaultInitialized(Addresses._ADDR_USDC, Addresses._ADDR_WETH, leverageTier, vaultId);
        DeployerOfAPE.deploy(
            _transientTokenParameters,
            vaultId,
            Addresses._ADDR_USDC,
            Addresses._ADDR_WETH,
            leverageTier
        );

        address ape = SaltedAddress.getAddress(vaultId);
        assertGt(ape.code.length, 0);
    }

    function testFuzz_deployUSDCvsALUSD(uint40 vaultId, int8 leverageTier) public {
        vm.assume(vaultId > 0);
        leverageTier = int8(bound(leverageTier, -3, 2)); // Only accepted values in the system

        vm.mockCall(
            address(this),
            abi.encodeWithSelector(IVault.latestTokenParams.selector),
            abi.encode(
                _transientTokenParameters.name,
                _transientTokenParameters.symbol,
                _transientTokenParameters.decimals,
                Addresses._ADDR_ALUSD,
                Addresses._ADDR_USDC,
                leverageTier
            )
        );

        vm.expectEmit();
        emit VaultInitialized(Addresses._ADDR_ALUSD, Addresses._ADDR_USDC, leverageTier, vaultId);
        DeployerOfAPE.deploy(
            _transientTokenParameters,
            vaultId,
            Addresses._ADDR_ALUSD,
            Addresses._ADDR_USDC,
            leverageTier
        );

        address ape = SaltedAddress.getAddress(vaultId);
        console.log("ape", ape);
        assertGt(ape.code.length, 0);
    }
}
