// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {SystemState} from "src/SystemState.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {SystemConstants} from "src/SystemConstants.sol";

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

contract SystemStateTest is Test, SystemConstants {
    uint40 constant VAULT_ID = 42;
    uint40 constant MAX_TS = 599 * 365 days; // See SystemState.sol comments for explanation
    SystemStateInstance systemState;

    address systemControl;
    address sir;
    address vaultExternal;

    address alice;
    address bob;

    constructor() {}

    function setUp() public {
        systemControl = vm.addr(1);
        sir = vm.addr(2);
        vaultExternal = vm.addr(3);

        alice = vm.addr(4);
        bob = vm.addr(5);

        systemState = new SystemStateInstance(systemControl, sir, vaultExternal);
    }

    function testFuzz_cumulativeSIRPerTEABeforeStart(uint8 tax, uint256 teaAmount) public {
        teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);

        // Activate 1 vault
        vm.prank(systemControl);
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        // Mint some TEA
        systemState.mint(alice, teaAmount);

        skip(69 seconds);

        uint176 cumSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumSIRPerTEAx96, 0);
    }

    function testFuzz_cumulativeSIRPerTEANoTax(uint40 tsIssuanceStart, uint256 teaAmount) public {
        teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);

        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, 0, 0, false, 0));

        // Mint some TEA
        systemState.mint(alice, teaAmount);

        skip(69 seconds);

        uint176 cumSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumSIRPerTEAx96, 0);
    }

    function testFuzz_cumulativeSIRPerTEANoTEA(uint40 tsIssuanceStart, uint8 tax) public {
        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(tsIssuanceStart, 0, 0, false, 0));

        // Activate 1 vault
        vm.prank(systemControl);
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        skip(69 seconds);

        uint176 cumSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumSIRPerTEAx96, 0);
    }

    function testFuzz_cumulativeSIRPerTEAFirst3Years(
        uint40 tsIssuanceStart,
        uint40 tsUpdateVault,
        uint40 tsCheckVault,
        uint8 tax,
        uint256 teaAmount
    ) public {
        // tsIssuanceStart is not 0 because it is a special value whhich indicates issuance has not started
        tsIssuanceStart = uint40(_bound(tsIssuanceStart, 1, type(uint40).max - 365 days * 3));
        // Checking the rewards within the first 3 years of issuance.
        tsCheckVault = uint40(
            _bound(tsCheckVault, uint256(tsIssuanceStart) + 1, uint256(tsIssuanceStart) + 365 days * 3)
        );
        vm.assume(tax > 0);
        teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);

        // In this test we wish to update the vault before we check the cumulative SIR.
        tsUpdateVault = uint40(_bound(tsUpdateVault, 0, tsCheckVault - 1));

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
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        vm.warp(tsCheckVault);
        uint176 cumSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        uint40 tsStart = tsIssuanceStart > tsUpdateVault ? tsIssuanceStart : tsUpdateVault;
        // console.log("test tsStart", tsStart);
        // console.log("test issuance", AGG_ISSUANCE_VAULTS);
        // console.log("test tsNow", block.timestamp);
        // vm.writeLine("./cumSIRPerTEAx96.log", vm.toString(cumSIRPerTEAx96));
        assertEq(cumSIRPerTEAx96, ((uint256(AGG_ISSUANCE_VAULTS) * (block.timestamp - tsStart)) << 96) / teaAmount);

        uint104 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        assertEq(unclaimedSIR, (teaAmount * cumSIRPerTEAx96) >> 96);
    }

    function testFuzz_cumulativeSIRPerTEAAfter3Years(
        uint40 tsIssuanceStart,
        uint40 tsUpdateVault,
        uint40 tsCheckVault,
        uint8 tax,
        uint256 teaAmount
    ) public {
        // tsIssuanceStart is not 0 because it is a special value whhich indicates issuance has not started
        tsIssuanceStart = uint40(_bound(tsIssuanceStart, 1, MAX_TS - 365 days * 3 - 1));
        // Checking the rewards after the first 3 years of issuance.
        tsCheckVault = uint40(_bound(tsCheckVault, uint256(tsIssuanceStart) + 365 days * 3 + 1, MAX_TS));
        vm.assume(tax > 0);
        teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);

        // In this test we wish to update the vault before we check the cumulative SIR.
        tsUpdateVault = uint40(_bound(tsUpdateVault, 0, tsCheckVault - 1));

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
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        vm.warp(tsCheckVault);
        uint176 cumSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        uint40 tsStart = tsIssuanceStart > tsUpdateVault ? tsIssuanceStart : tsUpdateVault;
        uint256 cumSIRPerTEA_test;
        if (tsStart < tsIssuanceStart + 365 days * 3) {
            cumSIRPerTEA_test =
                ((uint256(AGG_ISSUANCE_VAULTS) * (tsIssuanceStart + 365 days * 3 - tsStart)) << 96) /
                teaAmount;
            cumSIRPerTEA_test +=
                ((uint256(ISSUANCE) * (tsCheckVault - tsIssuanceStart - 365 days * 3)) << 96) /
                teaAmount;
        } else {
            cumSIRPerTEA_test = ((uint256(ISSUANCE) * (tsCheckVault - tsStart)) << 96) / teaAmount;
        }

        assertEq(cumSIRPerTEAx96, cumSIRPerTEA_test, "Wrong accumulated SIR per TEA");

        uint104 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        assertEq(unclaimedSIR, (teaAmount * cumSIRPerTEAx96) >> 96, "Wrong unclaimed SIR");
    }

    function test_unclaimedRewardsSplitBetweenTwo() public {
        uint8 tax = type(uint8).max;
        uint256 teaAmount = TEA_MAX_SUPPLY / 2;

        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(1, 0, 0, false, 0));

        // Activate 1 vault
        vm.prank(systemControl);
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        // Mint some TEA
        systemState.mint(alice, teaAmount);
        systemState.mint(bob, teaAmount);

        vm.warp(1 + 2 * THREE_YEARS);

        uint104 unclaimedSIRAlice = systemState.unclaimedRewards(VAULT_ID, alice);
        uint104 unclaimedSIRBob = systemState.unclaimedRewards(VAULT_ID, alice);

        assertApproxEqAbs(
            unclaimedSIRAlice,
            ((uint256(AGG_ISSUANCE_VAULTS) + uint256(ISSUANCE)) * THREE_YEARS) / 2,
            1,
            "Alice unclaimed SIR is wrong"
        );
        assertApproxEqAbs(
            unclaimedSIRBob,
            ((uint256(AGG_ISSUANCE_VAULTS) + uint256(ISSUANCE)) * THREE_YEARS) / 2,
            1,
            "Bob unclaimed SIR is wrong"
        );
    }

    function test_unclaimedRewardsHalfTheTime() public {
        uint8 tax = type(uint8).max;
        uint256 teaAmount = TEA_MAX_SUPPLY;

        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(1, 0, 0, false, 0));

        // Activate 1 vault
        vm.prank(systemControl);
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        // Mint some TEA
        systemState.mint(alice, teaAmount);

        vm.warp(1 + THREE_YEARS);
        systemState.burn(alice, teaAmount);
        systemState.mint(bob, teaAmount);

        vm.warp(1 + 2 * THREE_YEARS);
        uint104 unclaimedSIRAlice = systemState.unclaimedRewards(VAULT_ID, alice);
        uint104 unclaimedSIRBob = systemState.unclaimedRewards(VAULT_ID, bob);

        assertApproxEqAbs(
            unclaimedSIRAlice,
            uint256(AGG_ISSUANCE_VAULTS) * THREE_YEARS,
            1,
            "Alice unclaimed SIR is wrong"
        );
        assertApproxEqAbs(unclaimedSIRBob, uint256(ISSUANCE) * THREE_YEARS, 1, "Bob unclaimed SIR is wrong");
    }

    function test_updateLPerIssuanceParamsBySIR() public {
        uint8 tax = type(uint8).max;
        uint256 teaAmount = TEA_MAX_SUPPLY;

        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(1, 0, 0, false, 0));

        // Activate 1 vault
        vm.prank(systemControl);
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        // Mint some TEA
        systemState.mint(alice, teaAmount);

        // Reset rewards
        vm.warp(1 + 2 * THREE_YEARS);
        vm.prank(sir);
        uint104 unclaimedSIRAlice = systemState.claimSIR(VAULT_ID, alice);

        assertApproxEqAbs(unclaimedSIRAlice, (uint256(AGG_ISSUANCE_VAULTS) + uint256(ISSUANCE)) * THREE_YEARS, 1);
        assertEq(systemState.unclaimedRewards(VAULT_ID, alice), 0);
    }

    function test_updateLPerIssuanceFailsCuzNotSir(address addr) public {
        vm.assume(addr != sir);

        uint8 tax = type(uint8).max;
        uint256 teaAmount = TEA_MAX_SUPPLY;

        // Set start of issuance
        vm.prank(systemControl);
        systemState.updateSystemState(VaultStructs.SystemParameters(1, 0, 0, false, 0));

        // Activate 1 vault
        vm.prank(systemControl);
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = tax;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

        // Mint some TEA
        systemState.mint(alice, teaAmount);

        // Reset rewards
        vm.warp(1 + 2 * THREE_YEARS);
        vm.prank(addr);
        vm.expectRevert();
        systemState.claimSIR(VAULT_ID, alice);
    }

    // ALSO CHECK MINT, BURN AND TRANSFER OF TEA
}

///////////////////////////////////////////////
//// I N V A R I A N T //// T E S T I N G ////
/////////////////////////////////////////////

contract SystemStateHandler is Test, SystemConstants {
    uint40 public startTime;
    uint40 public currentTime; // Necessary because Forge invariant testing does not keep track block.timestamp

    uint40 constant VAULT_ID = 42;
    uint public totalClaimedSIR;
    uint public totalSIRMaxError;
    uint40 public totalTimeWithoutIssuanceFirst3Years;
    uint40 public totalTimeWithoutIssuanceAfter3Years;

    uint256 private _numUpdatesCumSIRPerTEA;
    mapping(uint256 idUser => uint256) private _numUpdatesCumSIRPerTEAForUser;

    SystemStateInstance private _systemState;

    modifier advanceTime(uint24 timeSkip) {
        vm.warp(currentTime);
        if (_systemState.totalSupply(VAULT_ID) == 0) {
            if (currentTime < startTime + 365 days * 3) {
                if (currentTime + timeSkip <= startTime + 365 days * 3) {
                    totalTimeWithoutIssuanceFirst3Years += timeSkip;
                } else {
                    totalTimeWithoutIssuanceFirst3Years += startTime + 365 days * 3 - currentTime;
                    totalTimeWithoutIssuanceAfter3Years += currentTime + timeSkip - (startTime + 365 days * 3);
                }
            } else {
                totalTimeWithoutIssuanceAfter3Years += timeSkip;
            }
        }
        currentTime += timeSkip;
        _;
        vm.warp(currentTime);
    }

    constructor(uint40 currentTime_) {
        startTime = currentTime_;
        currentTime = currentTime_;
        vm.warp(currentTime_);

        // We DO need the system control to start the emission of SIR.
        // We DO need the SIR address to be able to claim SIR.
        // We do NOT vault external in this test.
        _systemState = new SystemStateInstance(address(this), address(this), address(0));

        // Start issuance
        _systemState.updateSystemState(
            VaultStructs.SystemParameters(currentTime, uint16(0), uint8(0), false, uint16(0))
        );

        // Activate one vault (VERY IMPORTANT to do it after updateSystemState)
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = 1;
        _systemState.updateVaults(new uint40[](0), newVaults, newTaxes, 1);
    }

    function _idToAddr(uint id) private pure returns (address) {
        id = _bound(id, 1, 5);
        return vm.addr(id);
    }

    function transfer(uint256 from, uint256 to, uint256 amount, uint24 timeSkip) external advanceTime(timeSkip) {
        address fromAddr = _idToAddr(from);
        address toAddr = _idToAddr(to);
        uint256 preBalance = _systemState.balanceOf(fromAddr, VAULT_ID);
        amount = _bound(amount, 0, preBalance);
        console.log("action: transfer", amount);

        vm.prank(fromAddr);
        _systemState.safeTransferFrom(fromAddr, toAddr, VAULT_ID, amount, "");

        // Update totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[from] + 1;
        totalSIRMaxError += (preBalance * _numUpdatesCumSIRPerTEA) / 2 ** 96 + 1;
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[to] + 1;
        totalSIRMaxError += (preBalance * numUpdates) / 2 ** 96 + 1;

        // Update indexes
        _numUpdatesCumSIRPerTEAForUser[from] = _numUpdatesCumSIRPerTEA;
        _numUpdatesCumSIRPerTEAForUser[to] = _numUpdatesCumSIRPerTEA;
    }

    function mint(uint256 user, uint256 amount, uint24 timeSkip) external advanceTime(timeSkip) {
        address addr = _idToAddr(user);

        uint256 preBalance = _systemState.balanceOf(addr, VAULT_ID);

        uint256 totalSupply = _systemState.totalSupply(VAULT_ID);
        amount = _bound(amount, 0, TEA_MAX_SUPPLY - totalSupply);
        console.log("action: mint", amount, "to user", addr);

        _systemState.mint(addr, amount);

        // Update totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[user] + 1;
        totalSIRMaxError += (preBalance * numUpdates) / 2 ** 96 + 1;

        // Update index
        _numUpdatesCumSIRPerTEAForUser[user] = _numUpdatesCumSIRPerTEA;

        // Vault's cumulative SIR per TEA is updated
        _numUpdatesCumSIRPerTEA++;
    }

    function burn(uint256 user, uint256 amount, uint24 timeSkip) external advanceTime(timeSkip) {
        address addr = _idToAddr(user);
        uint256 preBalance = _systemState.balanceOf(addr, VAULT_ID);
        amount = _bound(amount, 0, preBalance);
        console.log("action: burn", amount);

        _systemState.burn(addr, amount);

        // Update totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[user] + 1;
        totalSIRMaxError += (preBalance * numUpdates) / 2 ** 96 + 1;

        // Update index
        _numUpdatesCumSIRPerTEAForUser[user] = _numUpdatesCumSIRPerTEA;

        // Vault's cumulative SIR per TEA is updated
        _numUpdatesCumSIRPerTEA++;
    }

    function claim(uint256 user, uint24 timeSkip) external advanceTime(timeSkip) {
        address addr = _idToAddr(user);
        uint256 preBalance = _systemState.balanceOf(addr, VAULT_ID);

        uint256 unclaimedSIR = _systemState.claimSIR(VAULT_ID, addr);
        console.log("action: claim", unclaimedSIR);
        totalClaimedSIR += unclaimedSIR;

        // Update totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[user] + 1;
        totalSIRMaxError += (preBalance * numUpdates) / 2 ** 96 + 1;

        // Update index
        _numUpdatesCumSIRPerTEAForUser[user] = _numUpdatesCumSIRPerTEA;
    }

    // function cumulativeSIRPerTEA() external view returns (uint176 cumSIRPerTEAx96) {
    //     return _systemState.cumulativeSIRPerTEA(VAULT_ID);
    // }

    function issuanceFirst3Years() external pure returns (uint256) {
        return ISSUANCE;
    }

    function issuanceAfter3Years() external pure returns (uint256) {
        return AGG_ISSUANCE_VAULTS;
    }

    function totalUnclaimedSIR() external view returns (uint256) {
        return
            _systemState.unclaimedRewards(VAULT_ID, _idToAddr(1)) +
            _systemState.unclaimedRewards(VAULT_ID, _idToAddr(2)) +
            _systemState.unclaimedRewards(VAULT_ID, _idToAddr(3)) +
            _systemState.unclaimedRewards(VAULT_ID, _idToAddr(4)) +
            _systemState.unclaimedRewards(VAULT_ID, _idToAddr(5));
    }
}

contract SystemStateInvariantTest is Test {
    SystemStateHandler private _systemStateHandler;

    modifier updateTime() {
        uint40 currentTime = _systemStateHandler.currentTime();
        vm.warp(currentTime);
        _;
    }

    function setUp() public {
        uint40 startTime = uint40(block.timestamp);
        if (startTime == 0) {
            startTime = 1;
        }

        _systemStateHandler = new SystemStateHandler(startTime);

        targetContract(address(_systemStateHandler));
    }

    // function invariant_cumulativeSIRPerTEA() public updateTime {
    //     assertEq(_systemStateHandler.cumSIRMaxError(), 0);
    // }

    function invariant_cumulativeSIR() public updateTime {
        uint256 totalSIR;
        uint40 startTime = _systemStateHandler.startTime();
        uint40 currentTime = _systemStateHandler.currentTime();
        vm.warp(currentTime);
        if (currentTime < startTime + 365 days * 3) {
            totalSIR =
                _systemStateHandler.issuanceFirst3Years() *
                (currentTime - startTime - _systemStateHandler.totalTimeWithoutIssuanceFirst3Years());
        } else {
            totalSIR =
                _systemStateHandler.issuanceFirst3Years() *
                (365 days * 3 - _systemStateHandler.totalTimeWithoutIssuanceFirst3Years()) +
                _systemStateHandler.issuanceAfter3Years() *
                (currentTime - startTime - 365 days * 3 - _systemStateHandler.totalTimeWithoutIssuanceAfter3Years());
        }

        assertLe(
            _systemStateHandler.totalClaimedSIR() + _systemStateHandler.totalUnclaimedSIR(),
            totalSIR,
            "Total SIR is too high"
        );

        uint256 totalSIRMaxError = _systemStateHandler.totalSIRMaxError();
        console.log("time elapsed", (currentTime - startTime) / (3600 * 24), "days");
        console.log(
            "total time without issuance",
            (_systemStateHandler.totalTimeWithoutIssuanceFirst3Years() +
                _systemStateHandler.totalTimeWithoutIssuanceAfter3Years()) / (3600 * 24)
        );
        console.log("total SIR", _systemStateHandler.totalClaimedSIR() + _systemStateHandler.totalUnclaimedSIR());
        console.log("expected total SIR", totalSIR);
        console.log("max error", _systemStateHandler.totalSIRMaxError());
        assertGe(
            _systemStateHandler.totalClaimedSIR() + _systemStateHandler.totalUnclaimedSIR(),
            totalSIR > totalSIRMaxError ? totalSIR - totalSIRMaxError : 0,
            "Total SIR is too low"
        );
        console.log("---------------------------------------");
    }
}

// INVARIANT TEST THAT CHECKS THAT SUM OF UNCLAIMED REWARDS MATCHES THE ISSUANCE
