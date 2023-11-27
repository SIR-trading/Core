// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {SystemState} from "src/SystemState.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {SystemConstants} from "src/SystemConstants.sol";

library ErrorComputation {
    function maxErrorBalanceSIR(uint256 balance, uint256 numUpdatesCumSIRPerTea) internal pure returns (uint256) {
        return ((balance * numUpdatesCumSIRPerTea) >> 96) + 1;
    }

    function maxErrorCumSIRPerTEA(uint256 numUpdatesCumSIRPerTea) internal pure returns (uint256) {
        return numUpdatesCumSIRPerTea;
    }
}

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

    function testFuzz_mintBeforeStart(uint8 tax, uint256 teaAmount) public {
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

    function testFuzz_mintNoTax(uint40 tsIssuanceStart, uint256 teaAmount) public {
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

    function testFuzz_noMint(uint40 tsIssuanceStart, uint8 tax) public {
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

    function testFuzz_mintFirst3Years(
        uint40 tsIssuanceStart,
        uint40 tsUpdateVault,
        uint40 tsCheckVault,
        uint8 tax,
        uint256 teaAmount
    ) public {
        // tsIssuanceStart is not 0 because it is a special value whhich indicates issuance has not started
        tsIssuanceStart = uint40(_bound(tsIssuanceStart, 1, type(uint40).max - THREE_YEARS));
        // Checking the rewards within the first 3 years of issuance.
        tsCheckVault = uint40(
            _bound(tsCheckVault, uint256(tsIssuanceStart) + 1, uint256(tsIssuanceStart) + THREE_YEARS)
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
        assertApproxEqAbs(
            cumSIRPerTEAx96,
            ((uint256(ISSUANCE_FIRST_3_YEARS) * (block.timestamp - tsStart)) << 96) / teaAmount,
            ErrorComputation.maxErrorCumSIRPerTEA(tsCheckVault > THREE_YEARS ? 2 : 1)
        );

        uint104 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = (teaAmount * cumSIRPerTEAx96) >> 96;
        assertLe(unclaimedSIR, unclaimedSIRTheoretical);
        assertGe(
            unclaimedSIR,
            unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, tsCheckVault > THREE_YEARS ? 2 : 1)
        );
    }

    function testFuzz_mintAfter3Years(
        uint40 tsIssuanceStart,
        uint40 tsUpdateVault,
        uint40 tsCheckVault,
        uint8 tax,
        uint256 teaAmount
    ) public {
        // tsIssuanceStart is not 0 because it is a special value whhich indicates issuance has not started
        tsIssuanceStart = uint40(_bound(tsIssuanceStart, 1, MAX_TS - THREE_YEARS - 1));

        // Checking the rewards after the first 3 years of issuance.
        tsCheckVault = uint40(_bound(tsCheckVault, uint256(tsIssuanceStart) + THREE_YEARS + 1, MAX_TS));
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
        uint256 cumSIRPerTEATheoretical;
        if (tsStart < tsIssuanceStart + THREE_YEARS) {
            cumSIRPerTEATheoretical =
                ((uint256(ISSUANCE_FIRST_3_YEARS) * (tsIssuanceStart + THREE_YEARS - tsStart)) << 96) /
                teaAmount;
            cumSIRPerTEATheoretical +=
                ((uint256(ISSUANCE) * (tsCheckVault - tsIssuanceStart - THREE_YEARS)) << 96) /
                teaAmount;
        } else {
            cumSIRPerTEATheoretical = ((uint256(ISSUANCE) * (tsCheckVault - tsStart)) << 96) / teaAmount;
        }

        assertLe(cumSIRPerTEAx96, cumSIRPerTEATheoretical, "Wrong accumulated SIR per TEA");
        assertGe(
            cumSIRPerTEAx96,
            cumSIRPerTEATheoretical - ErrorComputation.maxErrorCumSIRPerTEA(tsCheckVault > THREE_YEARS ? 2 : 1), // Passing 3 years causes two updates in cumSIRPerTEAx96
            "Wrong accumulated SIR per TEA"
        );

        uint104 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = (teaAmount * cumSIRPerTEAx96) >> 96;
        assertLe(unclaimedSIR, unclaimedSIRTheoretical, "Wrong unclaimed SIR");
        assertGe(
            unclaimedSIR,
            unclaimedSIRTheoretical -
                ErrorComputation.maxErrorBalanceSIR(teaAmount, tsCheckVault > THREE_YEARS ? 2 : 1), // Passing 3 years causes two updates in cumSIRPerTEAx96
            "Wrong unclaimed SIR"
        );
    }

    function testFuzz_mintTwoUsers(uint256 teaAmount) public {
        uint8 tax = type(uint8).max;
        teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY / 2);

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
        console.log("TEA amount: ", teaAmount);
        systemState.mint(alice, teaAmount);
        systemState.mint(bob, teaAmount);

        vm.warp(1 + 2 * THREE_YEARS);

        uint104 unclaimedSIRAlice = systemState.unclaimedRewards(VAULT_ID, alice);
        uint104 unclaimedSIRBob = systemState.unclaimedRewards(VAULT_ID, alice);

        uint256 unclaimedSIRTheoretical = ((uint256(ISSUANCE_FIRST_3_YEARS) + uint256(ISSUANCE)) * THREE_YEARS) / 2;
        console.log("unclaimedSIRTheoretical", unclaimedSIRTheoretical);
        assertLe(unclaimedSIRAlice, unclaimedSIRTheoretical, "Alice unclaimed SIR is wrong");
        assertGe(
            unclaimedSIRAlice,
            unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 2), // Passing 3 years causes two updates in cumSIRPerTEAx96
            "Alice unclaimed SIR is wrong"
        );

        assertLe(unclaimedSIRBob, unclaimedSIRTheoretical, "Alice unclaimed SIR is wrong");
        assertGe(
            unclaimedSIRBob,
            unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 2), // Passing 3 years causes two updates in cumSIRPerTEAx96
            "Bob unclaimed SIR is wrong"
        );
    }

    function testFuzz_mintTwoUsersSequentially(uint256 teaAmount) public {
        uint8 tax = type(uint8).max;
        teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);

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

        uint256 unclaimedSIRAliceTheoretical = uint256(ISSUANCE_FIRST_3_YEARS) * THREE_YEARS;
        assertLe(unclaimedSIRAlice, unclaimedSIRAliceTheoretical, "Alice unclaimed SIR is wrong");
        assertGe(
            unclaimedSIRAlice,
            unclaimedSIRAliceTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 1),
            "Alice unclaimed SIR is wrong"
        );

        uint256 unclaimedSIRBobTheoretical = uint256(ISSUANCE) * THREE_YEARS;
        assertLe(unclaimedSIRBob, unclaimedSIRBobTheoretical, "Bob unclaimed SIR is wrong");
        assertGe(
            unclaimedSIRBob,
            unclaimedSIRBobTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 1),
            "Bob unclaimed SIR is wrong"
        );
    }

    function testFuzz_claimSIR(uint256 teaAmount) public {
        uint8 tax = type(uint8).max;
        teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);

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

        uint unclaimedSIRAliceTheoretical = (uint256(ISSUANCE_FIRST_3_YEARS) + uint256(ISSUANCE)) * THREE_YEARS;
        assertLe(unclaimedSIRAlice, unclaimedSIRAliceTheoretical);
        assertGe(unclaimedSIRAlice, unclaimedSIRAliceTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 2));

        assertEq(systemState.unclaimedRewards(VAULT_ID, alice), 0);
    }

    function testFuzz_claimSIRFailsCuzNotSir(address addr) public {
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
    uint40 public currentTimeBefore;

    uint40 constant VAULT_ID = 42;
    uint public totalClaimedSIR;
    uint public _totalSIRMaxError;
    uint40 public totalTimeWithoutIssuanceFirst3Years;
    uint40 public totalTimeWithoutIssuanceAfter3Years;

    uint256 private _numUpdatesCumSIRPerTEA;
    mapping(uint256 idUser => uint256) private _numUpdatesCumSIRPerTEAForUser;

    SystemStateInstance private _systemState;

    modifier advanceTime(uint24 timeSkip) {
        currentTimeBefore = currentTime;
        vm.warp(currentTime);
        if (_systemState.totalSupply(VAULT_ID) == 0) {
            if (currentTime < startTime + THREE_YEARS) {
                if (currentTime + timeSkip <= startTime + THREE_YEARS) {
                    totalTimeWithoutIssuanceFirst3Years += timeSkip;
                } else {
                    totalTimeWithoutIssuanceFirst3Years += startTime + THREE_YEARS - currentTime;
                    totalTimeWithoutIssuanceAfter3Years += currentTime + timeSkip - (startTime + THREE_YEARS);
                }
            } else {
                totalTimeWithoutIssuanceAfter3Years += timeSkip;
            }
        }
        currentTime += timeSkip;
        vm.warp(currentTime);
        _;
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

        vm.prank(fromAddr);
        _systemState.safeTransferFrom(fromAddr, toAddr, VAULT_ID, amount, "");

        bool crossThreeYears = currentTimeBefore < startTime + THREE_YEARS && currentTime > startTime + THREE_YEARS;

        // Update _totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[from] + 1;
        if (crossThreeYears) numUpdates++;
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(preBalance, numUpdates);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[to] + 1;
        if (crossThreeYears) numUpdates++;
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(preBalance, numUpdates);

        // Update indexes
        _numUpdatesCumSIRPerTEAForUser[from] = _numUpdatesCumSIRPerTEA;
        _numUpdatesCumSIRPerTEAForUser[to] = _numUpdatesCumSIRPerTEA;
    }

    function mint(uint256 user, uint256 amount, uint24 timeSkip) external advanceTime(timeSkip) {
        address addr = _idToAddr(user);

        uint256 preBalance = _systemState.balanceOf(addr, VAULT_ID);

        uint256 totalSupply = _systemState.totalSupply(VAULT_ID);
        amount = _bound(amount, 0, TEA_MAX_SUPPLY - totalSupply);

        _systemState.mint(addr, amount);

        bool crossThreeYears = currentTimeBefore < startTime + THREE_YEARS && currentTime > startTime + THREE_YEARS;

        // Update _totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[user] + 1;
        if (crossThreeYears) numUpdates++;
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(preBalance, numUpdates);

        // Update index
        _numUpdatesCumSIRPerTEAForUser[user] = _numUpdatesCumSIRPerTEA;

        // Vault's cumulative SIR per TEA is updated
        if (crossThreeYears) _numUpdatesCumSIRPerTEA++;
        _numUpdatesCumSIRPerTEA++;
    }

    function burn(uint256 user, uint256 amount, uint24 timeSkip) external advanceTime(timeSkip) {
        address addr = _idToAddr(user);
        uint256 preBalance = _systemState.balanceOf(addr, VAULT_ID);
        amount = _bound(amount, 0, preBalance);

        _systemState.burn(addr, amount);

        bool crossThreeYears = currentTimeBefore < startTime + THREE_YEARS && currentTime > startTime + THREE_YEARS;

        // Update _totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[user] + 1;
        if (crossThreeYears) numUpdates++;
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(preBalance, numUpdates);

        // Update index
        _numUpdatesCumSIRPerTEAForUser[user] = _numUpdatesCumSIRPerTEA;

        // Vault's cumulative SIR per TEA is updated
        if (crossThreeYears) _numUpdatesCumSIRPerTEA++;
        _numUpdatesCumSIRPerTEA++;
    }

    function claim(uint256 user, uint24 timeSkip) external advanceTime(timeSkip) {
        address addr = _idToAddr(user);
        uint256 balance = _systemState.balanceOf(addr, VAULT_ID);

        uint256 unclaimedSIR = _systemState.claimSIR(VAULT_ID, addr);
        totalClaimedSIR += unclaimedSIR;

        bool crossThreeYears = currentTimeBefore < startTime + THREE_YEARS && currentTime > startTime + THREE_YEARS;

        // Update _totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[user] + 1;
        if (crossThreeYears) numUpdates++;
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(balance, numUpdates);

        // Update index
        _numUpdatesCumSIRPerTEAForUser[user] = _numUpdatesCumSIRPerTEA;
    }

    function issuanceFirst3Years() external pure returns (uint256) {
        return ISSUANCE_FIRST_3_YEARS;
    }

    function issuanceAfter3Years() external pure returns (uint256) {
        return ISSUANCE;
    }

    function totalUnclaimedSIR() external view returns (uint256) {
        return
            _systemState.unclaimedRewards(VAULT_ID, _idToAddr(1)) +
            _systemState.unclaimedRewards(VAULT_ID, _idToAddr(2)) +
            _systemState.unclaimedRewards(VAULT_ID, _idToAddr(3)) +
            _systemState.unclaimedRewards(VAULT_ID, _idToAddr(4)) +
            _systemState.unclaimedRewards(VAULT_ID, _idToAddr(5));
    }

    function totalSIRMaxError() external view returns (uint256 maxError) {
        uint256 numUpdates;
        uint256 balance;
        maxError = _totalSIRMaxError;

        balance = _systemState.balanceOf(_idToAddr(1), VAULT_ID);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[1];
        maxError += (balance * numUpdates) / 2 ** 96 + 1;

        balance = _systemState.balanceOf(_idToAddr(2), VAULT_ID);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[2];
        maxError += (balance * numUpdates) / 2 ** 96 + 1;

        balance = _systemState.balanceOf(_idToAddr(3), VAULT_ID);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[3];
        maxError += (balance * numUpdates) / 2 ** 96 + 1;

        balance = _systemState.balanceOf(_idToAddr(4), VAULT_ID);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[4];
        maxError += (balance * numUpdates) / 2 ** 96 + 1;

        balance = _systemState.balanceOf(_idToAddr(5), VAULT_ID);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[5];
        maxError += (balance * numUpdates) / 2 ** 96 + 1;
    }
}

contract SystemStateInvariantTest is Test, SystemConstants {
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

    function invariant_cumulativeSIR() public updateTime {
        uint256 totalSIR;
        uint40 startTime = _systemStateHandler.startTime();
        uint40 currentTime = _systemStateHandler.currentTime();
        vm.warp(currentTime);

        if (currentTime < startTime + THREE_YEARS) {
            totalSIR =
                _systemStateHandler.issuanceFirst3Years() *
                (currentTime - startTime - _systemStateHandler.totalTimeWithoutIssuanceFirst3Years());
        } else {
            totalSIR =
                _systemStateHandler.issuanceFirst3Years() *
                (THREE_YEARS - _systemStateHandler.totalTimeWithoutIssuanceFirst3Years()) +
                _systemStateHandler.issuanceAfter3Years() *
                (currentTime - startTime - THREE_YEARS - _systemStateHandler.totalTimeWithoutIssuanceAfter3Years());
        }

        assertLe(
            _systemStateHandler.totalClaimedSIR() + _systemStateHandler.totalUnclaimedSIR(),
            totalSIR,
            "Total SIR is too high"
        );

        uint256 totalSIRMaxError = _systemStateHandler.totalSIRMaxError();
        assertGe(
            _systemStateHandler.totalClaimedSIR() + _systemStateHandler.totalUnclaimedSIR(),
            totalSIR > totalSIRMaxError ? totalSIR - totalSIRMaxError : 0,
            "Total SIR is too low"
        );
    }
}
