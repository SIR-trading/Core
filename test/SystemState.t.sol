// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {SystemState} from "src/SystemState.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {SystemCommons} from "src/SystemCommons.sol";

contract SystemStateInstance is SystemState {
    uint40 constant VAULT_ID = 42;

    constructor(
        address systemControl,
        address sir,
        address vaultExternal
    ) SystemState(systemControl, sir, vaultExternal) {}

    function updateLPerIssuanceParams(address lper0, address lper1) external returns (uint104 unclaimedRewards) {
        return updateLPerIssuanceParams(false, VAULT_ID, lper0, lper1);
    }

    function mint(uint256 amount) external {
        mint(tx.origin, VAULT_ID, amount);
    }
}

contract SystemStateTest is Test, SystemCommons {
    uint40 constant VAULT_ID = 42;
    uint40 constant MAX_TS = 5000000000; // 11 June 2128
    SystemStateInstance systemState;

    constructor() SystemCommons(address(0)) {}

    function setUp() public {
        systemState = new SystemStateInstance(vm.addr(1), vm.addr(2), vm.addr(3));
    }

    function testFuzz_cumulativeSIRPerTEABeforeStart(uint16 tax, uint256 teaAmount) public {
        // Activate 1 vault
        vm.prank(vm.addr(1));
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint16[] memory newTaxes = new uint16[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        // Mint some TEA
        systemState.mint(teaAmount);

        skip(69 seconds);

        uint152 cumSIRPerTEA = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumSIRPerTEA, 0);
    }

    function testFuzz_cumulativeSIRPerTEANoTax(uint40 tsIssuanceStart, uint256 teaAmount) public {
        // Set start of issuance
        vm.prank(vm.addr(1));
        systemState.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, 0, 0, false, 0));

        // Mint some TEA
        systemState.mint(teaAmount);

        skip(69 seconds);

        uint152 cumSIRPerTEA = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumSIRPerTEA, 0);
    }

    function testFuzz_cumulativeSIRPerTEANoTEA(uint40 tsIssuanceStart, uint16 tax) public {
        // Set start of issuance
        vm.prank(vm.addr(1));
        systemState.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, 0, 0, false, 0));

        // Activate 1 vault
        vm.prank(vm.addr(1));
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint16[] memory newTaxes = new uint16[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        skip(69 seconds);

        uint152 cumSIRPerTEA = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumSIRPerTEA, 0);
    }

    function testFuzz_cumulativeSIRPerTEAFirst3Years(
        uint40 tsIssuanceStart,
        uint40 tsUpdateVault,
        uint40 tsCheckVault,
        uint16 tax,
        uint256 teaAmount
    ) public {
        // tsIssuanceStart is not 0 because it is a special value whhich indicates issuance has not started
        tsIssuanceStart = uint40(bound(tsIssuanceStart, 1, type(uint40).max - 365 days * 3));
        // Checking the rewards within the first 3 years of issuance.
        tsCheckVault = uint40(
            bound(tsCheckVault, uint256(tsIssuanceStart) + 1, uint256(tsIssuanceStart) + 365 days * 3)
        );
        vm.assume(tax > 0);
        vm.assume(teaAmount > 0);

        // In this test we wish to update the vault before we check the cumulative SIR.
        tsUpdateVault = uint40(bound(tsUpdateVault, 0, tsCheckVault - 1));

        // Mint some TEA
        systemState.mint(teaAmount);

        // Set start of issuance
        vm.prank(vm.addr(1));
        systemState.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, 0, 0, false, 0));

        // Activate 1 vault
        vm.warp(tsUpdateVault);
        vm.prank(vm.addr(1));
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint16[] memory newTaxes = new uint16[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        vm.warp(tsCheckVault);
        uint152 cumSIRPerTEA = systemState.cumulativeSIRPerTEA(VAULT_ID);

        uint40 tsStart = tsIssuanceStart > tsUpdateVault ? tsIssuanceStart : tsUpdateVault;
        // console.log("test tsStart", tsStart);
        // console.log("test issuance", AGG_ISSUANCE_VAULTS);
        // console.log("test tsNow", block.timestamp);
        // vm.writeLine("./cumSIRPerTEA.log", vm.toString(cumSIRPerTEA));
        assertEq(cumSIRPerTEA, ((uint256(AGG_ISSUANCE_VAULTS) * (block.timestamp - tsStart)) << 48) / teaAmount);
    }

    function testFuzz_cumulativeSIRPerTEAAfter3Years(
        uint40 tsIssuanceStart,
        uint40 tsUpdateVault,
        uint40 tsCheckVault,
        uint16 tax,
        uint256 teaAmount
    ) public {
        // tsIssuanceStart is not 0 because it is a special value whhich indicates issuance has not started
        tsIssuanceStart = uint40(bound(tsIssuanceStart, 1, MAX_TS - 365 days * 3 - 1));
        // Checking the rewards after the first 3 years of issuance.
        tsCheckVault = uint40(bound(tsCheckVault, uint256(tsIssuanceStart) + 365 days * 3 + 1, MAX_TS));
        vm.assume(tax > 0);
        vm.assume(teaAmount > 0);

        // In this test we wish to update the vault before we check the cumulative SIR.
        tsUpdateVault = uint40(bound(tsUpdateVault, 0, tsCheckVault - 1));

        // Mint some TEA
        systemState.mint(teaAmount);

        // Set start of issuance
        vm.prank(vm.addr(1));
        systemState.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, 0, 0, false, 0));

        // Activate 1 vault
        vm.warp(tsUpdateVault);
        vm.prank(vm.addr(1));
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint16[] memory newTaxes = new uint16[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        vm.warp(tsCheckVault);
        uint152 cumSIRPerTEA = systemState.cumulativeSIRPerTEA(VAULT_ID);

        uint40 tsStart = tsIssuanceStart > tsUpdateVault ? tsIssuanceStart : tsUpdateVault;
        uint256 cumSIRPerTEA_test;
        if (tsStart < tsIssuanceStart + 365 days * 3) {
            cumSIRPerTEA_test =
                ((uint256(AGG_ISSUANCE_VAULTS) * (tsIssuanceStart + 365 days * 3 - tsStart)) << 48) /
                teaAmount;
            cumSIRPerTEA_test +=
                ((uint256(ISSUANCE) * (tsCheckVault - tsIssuanceStart - 365 days * 3)) << 48) /
                teaAmount;
        } else {
            cumSIRPerTEA_test = ((uint256(ISSUANCE) * (tsCheckVault - tsStart)) << 48) / teaAmount;
        }

        assertEq(cumSIRPerTEA, cumSIRPerTEA_test);
    }
}
