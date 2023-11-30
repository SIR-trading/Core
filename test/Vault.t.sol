// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {Vault} from "src/Vault.sol";
import {Oracle} from "src/Oracle.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {VaultEvents} from "src/interfaces/VaultEvents.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";

// import {APE} from "src/APE.sol";
// import {IERC20} from "src/interfaces/IERC20.sol";

contract VaultTest is Test, VaultEvents {
    address public systemControl = vm.addr(1);
    address public sir = vm.addr(2);
    address public vaultExternal = vm.addr(3);

    Vault public vault = Vault(vm.addr(4));

    address public alice = vm.addr(5);

    address public debtToken = Addresses.ADDR_USDT;
    address public collateralToken = Addresses.ADDR_WETH;

    function setUp() public {
        Oracle oracle = new Oracle();
        deployCodeTo("VaultExternal.sol", abi.encode(vm.addr(4)), vaultExternal);
        deployCodeTo("Vault.sol", abi.encode(systemControl, sir, address(oracle), vaultExternal), address(vault));

        vm.createSelectFork("mainnet", 18128102);
    }

    function testFuzz_InitializeVault(int8 leverageTier) public {
        // Stay within the allowed range of -3 to 2
        leverageTier = int8(_bound(leverageTier, -3, 2));

        vm.expectEmit();
        emit VaultInitialized(debtToken, collateralToken, leverageTier, 1);
        vault.initialize(debtToken, collateralToken, leverageTier);

        (, , , , uint40 vaultId, ) = vault.state(debtToken, collateralToken, leverageTier);
        assertEq(vaultId, 1);
    }

    // function testInitializeVaultInvalidLeverageTier(int8 leverageTier) public {
    //     vm.expectRevert("LeverageTierOutOfRange");
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, invalidLeverageTier);
    // }

    // function testReInitializeVault() public {
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    //     vm.expectRevert("VaultAlreadyInitialized");
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    // }

    // function testMintAPE() public {
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    //     uint256 amountMinted = vault.mint(true, debtToken, collateralToken, validLeverageTier);
    //     assertTrue(amountMinted > 0);
    //     // Additional checks for reserves and token balances can be added here
    // }

    // function testMintTEA() public {
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    //     uint256 amountMinted = vault.mint(false, debtToken, collateralToken, validLeverageTier);
    //     assertTrue(amountMinted > 0);
    //     // Additional checks for reserves and token balances can be added here
    // }

    // function testMintWithEmergencyStop() public {
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    //     // Simulate emergency stop
    //     vm.prank(systemControl);
    //     vault.updateSystemState(VaultStructs.SystemParameters(0, 0, 0, true, 0));
    //     vm.expectRevert(); // Expect specific revert message for emergency stop
    //     vault.mint(false, debtToken, collateralToken, validLeverageTier);
    // }

    // function testMintBeforeSIRStart() public {
    //     // Assuming SIR start is controlled by a state variable or similar mechanism
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    //     // Ensure SIR has not started
    //     vm.expectRevert(); // Expect specific revert message for SIR not started
    //     vault.mint(true, debtToken, collateralToken, validLeverageTier);
    // }

    // function testBurnAPE() public {
    //     // Setup and mint some APE
    //     vm.prank(systemControl);
    //     vault.initialize(debtToken, collateralToken, validLeverageTier);
    //     uint256 amountMinted = vault.mint(true, debtToken, collateralToken, validLeverageTier);
    //     // Burn a portion of the minted APE
    //     uint152 amountBurned = vault.burn(true, debtToken, collateralToken, validLeverageTier, amountMinted / 2);
    //     assertTrue(amountBurned > 0);
    //     // Additional checks for reserve updates can be added here
    // }
}
