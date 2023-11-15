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

    function mint(address to, uint256 amount) external {
        mint(to, VAULT_ID, amount);
    }

    function burn(address from, uint256 amount) external {
        burn(from, VAULT_ID, amount);
    }
}

contract SystemStateTest is Test, SystemCommons {
    uint40 constant VAULT_ID = 42;
    uint40 constant MAX_TS = 202824096036; // type(uint152).max/(100*10**18*2**48)
    SystemStateInstance systemState;

    address systemControl;
    address sir;
    address vaultExternal;

    address alice;
    address bob;

    constructor() SystemCommons(address(0)) {}

    function setUp() public {
        systemControl = vm.addr(1);
        sir = vm.addr(2);
        vaultExternal = vm.addr(3);

        alice = vm.addr(4);
        bob = vm.addr(5);

        systemState = new SystemStateInstance(systemControl, sir, vaultExternal);
    }

    function testFuzz_cumulativeSIRPerTEABeforeStart(uint16 tax, uint256 teaAmount) public {
        // Activate 1 vault
        vm.prank(systemControl);
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint16[] memory newTaxes = new uint16[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        // Mint some TEA
        systemState.mint(alice, teaAmount);

        skip(69 seconds);

        uint152 cumSIRPerTEA = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumSIRPerTEA, 0);
    }

    function testFuzz_cumulativeSIRPerTEANoTax(uint40 tsIssuanceStart, uint256 teaAmount) public {
        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, 0, 0, false, 0));

        // Mint some TEA
        systemState.mint(alice, teaAmount);

        skip(69 seconds);

        uint152 cumSIRPerTEA = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumSIRPerTEA, 0);
    }

    function testFuzz_cumulativeSIRPerTEANoTEA(uint40 tsIssuanceStart, uint16 tax) public {
        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, 0, 0, false, 0));

        // Activate 1 vault
        vm.prank(systemControl);
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
        systemState.mint(alice, teaAmount);

        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, 0, 0, false, 0));

        // Activate 1 vault
        vm.warp(tsUpdateVault);
        vm.prank(systemControl);
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

        uint104 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        assertEq(unclaimedSIR, (teaAmount * cumSIRPerTEA) >> 48);
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
        systemState.mint(alice, teaAmount);

        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, 0, 0, false, 0));

        // Activate 1 vault
        vm.warp(tsUpdateVault);
        vm.prank(systemControl);
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

        uint104 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        assertEq(unclaimedSIR, (teaAmount * cumSIRPerTEA) >> 48);
    }

    function test_unclaimedRewardsSplitBetweenTwo() public {
        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(1, 0, 0, false, 0));

        // Activate 1 vault
        vm.prank(systemControl);
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint16[] memory newTaxes = new uint16[](1);
        newTaxes[0] = 1;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, 1);

        // Mint some TEA
        systemState.mint(alice, 1);
        systemState.mint(bob, 1);

        vm.warp(1 + 2 * THREE_YEARS);

        uint104 unclaimedSIRAlice = systemState.unclaimedRewards(VAULT_ID, alice);
        uint104 unclaimedSIRBob = systemState.unclaimedRewards(VAULT_ID, alice);

        assertEq(unclaimedSIRAlice, ((uint256(AGG_ISSUANCE_VAULTS) + uint256(ISSUANCE)) * THREE_YEARS) / 2);
        assertEq(unclaimedSIRBob, ((uint256(AGG_ISSUANCE_VAULTS) + uint256(ISSUANCE)) * THREE_YEARS) / 2);
    }

    function test_unclaimedRewardsHalfTheTime() public {
        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(1, 0, 0, false, 0));

        // Activate 1 vault
        vm.prank(systemControl);
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint16[] memory newTaxes = new uint16[](1);
        newTaxes[0] = 1;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, 1);

        // Mint some TEA
        systemState.mint(alice, 1);

        vm.warp(1 + THREE_YEARS);
        systemState.mint(bob, 1);
        systemState.burn(alice, 1);

        vm.warp(1 + 2 * THREE_YEARS);
        uint104 unclaimedSIRAlice = systemState.unclaimedRewards(VAULT_ID, alice);
        uint104 unclaimedSIRBob = systemState.unclaimedRewards(VAULT_ID, bob);

        assertEq(unclaimedSIRAlice, uint256(AGG_ISSUANCE_VAULTS) * THREE_YEARS, "Alice unclaimed SIR is wrong");
        assertEq(unclaimedSIRBob, uint256(ISSUANCE) * THREE_YEARS, "Bob unclaimed SIR is wrong");
    }
}
