// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {Vault} from "src/Vault.sol";
import {Oracle} from "src/Oracle.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";

// import {APE} from "src/APE.sol";
// import {IERC20} from "src/interfaces/IERC20.sol";

contract VaultTest is Test {
    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId
    );

    address public systemControl = vm.addr(1);
    address public sir = vm.addr(2);

    Vault public vault;

    address public alice = vm.addr(3);

    address public debtToken = Addresses.ADDR_USDT;
    address public collateralToken = Addresses.ADDR_WETH;

    // function _predictAddress(
    //     address deployer,
    //     bytes32 salt,
    //     address oracle,
    //     address vaultExternal
    // ) internal view returns (address) {
    //     return
    //         address(
    //             uint160(
    //                 uint256(
    //                     keccak256(
    //                         abi.encodePacked(
    //                             bytes1(0xff),
    //                             deployer,
    //                             salt,
    //                             keccak256(
    //                                 abi.encodePacked(
    //                                     type(Vault).creationCode,
    //                                     abi.encode(systemControl, sir, oracle, vaultExternal)
    //                                 )
    //                             )
    //                         )
    //                     )
    //                 )
    //             )
    //         );
    // }

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        address oracle = address(new Oracle());

        // // Deploy VaultExternal
        // deployCodeTo("VaultExternal.sol", address(0x0000000000000000000000000000000000001234));

        // Deploy vault
        vault = new Vault(systemControl, sir, oracle);
    }

    function testFuzz_InitializeVault(int8 leverageTier) public {
        // Stay within the allowed range of -3 to 2
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER));

        vm.expectEmit();
        emit VaultInitialized(debtToken, collateralToken, leverageTier, 1);
        vault.initialize(VaultStructs.VaultParameters(debtToken, collateralToken, leverageTier));

        (uint144 reserve, int64 tickPriceSatX42, uint48 vaultId) = vault.vaultStates(
            debtToken,
            collateralToken,
            leverageTier
        );

        assertEq(reserve, 0);
        assertEq(tickPriceSatX42, 0);
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
    //     // Assuming SIR start is controlled by a vaultState variable or similar mechanism
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
    //     uint144 amountBurned = vault.burn(true, debtToken, collateralToken, validLeverageTier, amountMinted / 2);
    //     assertTrue(amountBurned > 0);
    //     // Additional checks for reserve updates can be added here
    // }
}
