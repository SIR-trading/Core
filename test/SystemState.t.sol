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

contract SystemStateWrapper is SystemState {
    uint40 constant VAULT_ID = 42;

    uint128 private _totalSupply;
    uint128 private _balanceVault;
    mapping(address => uint256) private _balances;

    constructor(address systemControl, address sir) SystemState(systemControl, sir) {}

    /** SystemState's most important function is
            updateLPerIssuanceParams
        which is called when tansfering/minting/burning TEA.
        It only cares about the current _balances and the total supply of TEA,
        plus some system parameters.
     */
    function transfer(address from, address to, uint256 amount) external {
        // Get _balances
        LPersBalances memory lpersBalances = LPersBalances(from, _balances[from], to, _balances[to]);

        // Update SIR issuance
        updateLPerIssuanceParams(
            false,
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            _totalSupply,
            lpersBalances
        );

        // Transfer TEA
        _balances[from] -= amount;
        _balances[to] += amount;
    }

    /// @dev Mints TEA for POL only
    function mintPol(uint256 amountPol) external {
        // Get _balances
        LPersBalances memory lpersBalances = LPersBalances(address(this), _balanceVault, address(0), 0);

        // Update SIR issuance
        updateLPerIssuanceParams(
            false,
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            _totalSupply,
            lpersBalances
        );

        // Mint TEA
        unchecked {
            _balanceVault += uint128(amountPol);
            require(_totalSupply + amountPol <= TEA_MAX_SUPPLY, "Max supply exceeded");
            _totalSupply += uint128(amountPol);
        }
    }

    /// @dev Mints TEA to the given address and for POL
    function mint(address to, uint256 amount, uint256 amountPol) external {
        // Get _balances
        LPersBalances memory lpersBalances = LPersBalances(
            to,
            _balances[to],
            address(this), // We also update balance of vault
            _balanceVault
        );

        // Update SIR issuance
        updateLPerIssuanceParams(
            false,
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            _totalSupply,
            lpersBalances
        );

        // Mint TEA
        unchecked {
            _balances[to] += amount;
            require(_totalSupply + amount <= TEA_MAX_SUPPLY, "Max supply exceeded");
            _totalSupply += uint128(amount);

            _balanceVault += uint128(amountPol);
            require(_totalSupply + amountPol <= TEA_MAX_SUPPLY, "Max supply exceeded");
            _totalSupply += uint128(amountPol);
        }
    }

    /// @dev Burns TEA to the given address and means TEA for POL
    function burn(address from, uint256 amount, uint256 amountPol) external {
        // Get _balances
        LPersBalances memory lpersBalances = LPersBalances(
            from,
            _balances[from],
            address(this), // We also update balance of vault
            _balanceVault
        );

        // Update SIR issuance
        updateLPerIssuanceParams(
            false,
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            _totalSupply,
            lpersBalances
        );

        // Burn TEA
        _balances[from] -= amount;
        unchecked {
            _totalSupply -= uint128(amount);
        }

        // Mint TEA for POL
        unchecked {
            _balanceVault += uint128(amountPol);
            require(_totalSupply + amountPol <= TEA_MAX_SUPPLY, "Max supply exceeded");
            _totalSupply += uint128(amountPol);
        }
    }

    function balanceOf(address owner, uint256 vaultId) public view override returns (uint256) {
        assert(vaultId == VAULT_ID);

        return owner == address(this) ? _balanceVault : _balances[owner];
    }

    function totalSupply(uint256 vaultId) public view override returns (uint256) {
        assert(vaultId == VAULT_ID);

        return _totalSupply;
    }

    function cumulativeSIRPerTEA(uint256 vaultId) public view override returns (uint176 cumSIRPerTEAx96) {
        assert(vaultId == VAULT_ID);

        return cumulativeSIRPerTEA(systemParams, vaultIssuanceParams[vaultId], _totalSupply);
    }
}

contract SystemStateTest is Test, SystemConstants {
    uint40 constant VAULT_ID = 42;
    uint40 constant MAX_TS = 599 * 365 days; // See SystemState.sol comments for explanation
    SystemStateWrapper systemState;

    uint40 tsStart;

    address systemControl;
    address sir;

    address alice;
    address bob;

    function _activateTax() private {
        vm.prank(systemControl);
        uint40[] memory oldVaults = new uint40[](0);
        uint40[] memory newVaults = new uint40[](1);
        newVaults[0] = VAULT_ID;
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = 1;
        systemState.updateVaults(oldVaults, newVaults, newTaxes, 1);
    }

    function _updateTaxMintAndCheckRewards(
        uint40 tsUpdateTax,
        uint40 tsMint,
        uint40 tsCheckRewards,
        bool checkFirst3Years,
        uint256 teaAmount,
        uint256 teaAmountPOL
    ) private returns (uint256 durationBefore3Years, uint256 durationAfter3Years, uint176 cumSIRPerTEAx96) {
        if (tsUpdateTax < tsMint) {
            if (checkFirst3Years) {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsMint, tsStart + THREE_YEARS));
                durationBefore3Years = tsCheckRewards - tsMint;
            } else if (tsMint > tsStart + THREE_YEARS) {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsMint, MAX_TS));
                durationAfter3Years = tsCheckRewards - tsMint;
            } else {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsStart + THREE_YEARS, MAX_TS));
                durationBefore3Years = tsStart + THREE_YEARS - tsMint;
                durationAfter3Years = tsCheckRewards - (tsStart + THREE_YEARS);
            }

            // Activate tax
            vm.warp(tsUpdateTax);
            _activateTax();

            // Mint some TEA
            vm.warp(tsMint);
            systemState.mint(alice, teaAmount, teaAmountPOL);
        } else {
            if (checkFirst3Years) {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsUpdateTax, tsStart + THREE_YEARS));
                durationBefore3Years = tsCheckRewards - tsUpdateTax;
            } else if (tsUpdateTax > tsStart + THREE_YEARS) {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsUpdateTax, MAX_TS));
                durationAfter3Years = tsCheckRewards - tsUpdateTax;
            } else {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsStart + THREE_YEARS, MAX_TS));
                durationBefore3Years = tsStart + THREE_YEARS - tsUpdateTax;
                durationAfter3Years = tsCheckRewards - (tsStart + THREE_YEARS);
            }

            // Mint some TEA
            vm.warp(tsMint);
            systemState.mint(alice, teaAmount, teaAmountPOL);

            // Activate tax
            vm.warp(tsUpdateTax);
            _activateTax();
        }

        // Get cumulative SIR per TEA
        vm.warp(tsCheckRewards);
        cumSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);
    }

    function setUp() public {
        systemControl = vm.addr(1);
        sir = vm.addr(2);

        alice = vm.addr(4);
        bob = vm.addr(5);

        systemState = new SystemStateWrapper(systemControl, sir);
        tsStart = uint40(block.timestamp);
    }

    function testFuzz_noMint(uint40 tsUpdateTax, uint40 tsCheckRewards) public {
        tsUpdateTax = uint40(_bound(tsUpdateTax, 0, MAX_TS));
        tsCheckRewards = uint40(_bound(tsCheckRewards, tsUpdateTax, MAX_TS));

        // Activate tax
        vm.warp(tsUpdateTax);
        _activateTax();

        // Get cumulative SIR per TEA
        vm.warp(tsUpdateTax);
        uint176 cumSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumSIRPerTEAx96, 0);
    }

    function testFuzz_mintNoTax(
        uint40 tsUpdateMint,
        uint40 tsCheckRewards,
        uint256 teaAmount,
        uint256 teaAmountPOL
    ) public {
        tsUpdateMint = uint40(_bound(tsUpdateMint, 0, MAX_TS));
        tsCheckRewards = uint40(_bound(tsCheckRewards, tsUpdateMint, MAX_TS));

        teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, TEA_MAX_SUPPLY - teaAmount);

        // Mint some TEA
        vm.warp(tsUpdateMint);
        systemState.mint(alice, teaAmount, teaAmountPOL);

        // Get cumulative SIR per TEA
        vm.warp(tsCheckRewards);
        uint176 cumSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumSIRPerTEAx96, 0);
    }

    function testFuzz_mintAndCheckFirst3Years(
        uint40 tsUpdateTax,
        uint40 tsMint,
        uint40 tsCheckRewards,
        uint256 teaAmount,
        uint256 teaAmountPOL
    ) public {
        // Tax and mint before the 3 years have passed
        tsUpdateTax = uint40(_bound(tsUpdateTax, tsStart, tsStart + THREE_YEARS));
        tsMint = uint40(_bound(tsMint, tsStart, tsStart + THREE_YEARS));

        teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, TEA_MAX_SUPPLY - teaAmount);

        (uint256 duration, , uint176 cumSIRPerTEAx96) = _updateTaxMintAndCheckRewards(
            tsUpdateTax,
            tsMint,
            tsCheckRewards,
            true,
            teaAmount,
            teaAmountPOL
        );

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumSIRPerTEAx96,
            ((ISSUANCE_FIRST_3_YEARS * duration) << 96) / (teaAmount + teaAmountPOL),
            ErrorComputation.maxErrorCumSIRPerTEA(1)
        );

        // Check rewards for Alice
        uint104 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = (ISSUANCE_FIRST_3_YEARS * duration * teaAmount) / (teaAmount + teaAmountPOL);
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 1));
        }

        // Check rewards for POL
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, address(systemState));
        unclaimedSIRTheoretical = (ISSUANCE_FIRST_3_YEARS * duration * teaAmountPOL) / (teaAmount + teaAmountPOL);
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmountPOL, 1));
        }
    }

    function testFuzz_mintAfterFirst3Years(
        uint40 tsUpdateTax,
        uint40 tsMint,
        uint40 tsCheckRewards,
        uint256 teaAmount,
        uint256 teaAmountPOL
    ) public {
        // Tax and mint after the first 3 years
        tsUpdateTax = uint40(_bound(tsUpdateTax, tsStart + THREE_YEARS, MAX_TS));
        tsMint = uint40(_bound(tsMint, tsStart + THREE_YEARS, MAX_TS));

        teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, TEA_MAX_SUPPLY - teaAmount);

        (, uint256 duration, uint176 cumSIRPerTEAx96) = _updateTaxMintAndCheckRewards(
            tsUpdateTax,
            tsMint,
            tsCheckRewards,
            false,
            teaAmount,
            teaAmountPOL
        );

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumSIRPerTEAx96,
            ((ISSUANCE * duration) << 96) / (teaAmount + teaAmountPOL),
            ErrorComputation.maxErrorCumSIRPerTEA(1)
        );

        // Check rewards for Alice
        uint104 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = (ISSUANCE * duration * teaAmount) / (teaAmount + teaAmountPOL);
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 1));
        }

        // Check rewards for POL
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, address(systemState));
        unclaimedSIRTheoretical = (ISSUANCE * duration * teaAmountPOL) / (teaAmount + teaAmountPOL);
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmountPOL, 1));
        }
    }

    function testFuzz_mintBefore3YearsAndCheckAfter3Years(
        uint40 tsUpdateTax,
        uint40 tsMint,
        uint40 tsCheckRewards,
        uint256 teaAmount,
        uint256 teaAmountPOL
    ) public {
        // Tax and mint before the 3 years have passed
        tsUpdateTax = uint40(_bound(tsUpdateTax, tsStart, tsStart + THREE_YEARS));
        tsMint = uint40(_bound(tsMint, tsStart, tsStart + THREE_YEARS));

        teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, TEA_MAX_SUPPLY - teaAmount);

        (
            uint256 durationBefore3Years,
            uint256 durationAfter3Years,
            uint176 cumSIRPerTEAx96
        ) = _updateTaxMintAndCheckRewards(tsUpdateTax, tsMint, tsCheckRewards, false, teaAmount, teaAmountPOL);

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumSIRPerTEAx96,
            ((ISSUANCE_FIRST_3_YEARS * durationBefore3Years + ISSUANCE * durationAfter3Years) << 96) /
                (teaAmount + teaAmountPOL),
            ErrorComputation.maxErrorCumSIRPerTEA(2)
        );

        // Check rewards for Alice
        uint104 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = ((ISSUANCE_FIRST_3_YEARS *
            durationBefore3Years +
            ISSUANCE *
            durationAfter3Years) * teaAmount) / (teaAmount + teaAmountPOL);
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 2));
        }

        // Check rewards for POL
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, address(systemState));
        unclaimedSIRTheoretical =
            ((ISSUANCE_FIRST_3_YEARS * durationBefore3Years + ISSUANCE * durationAfter3Years) * teaAmountPOL) /
            (teaAmount + teaAmountPOL);
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmountPOL, 2));
        }
    }

    //     function testFuzz_mintTwoUsers(uint256 teaAmount) public {
    //         uint8 tax = type(uint8).max;
    //         teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY / 2);

    //         // Set start of issuance
    //         vm.prank(systemControl);
    //         systemState.updateSystemState(VaultStructs.SystemParameters(1, 0, 0, false, 0));

    //         // Activate 1 vault
    //         vm.prank(systemControl);
    //         uint40[] memory oldVaults = new uint40[](0);
    //         uint40[] memory newVaults = new uint40[](1);
    //         newVaults[0] = VAULT_ID;
    //         uint8[] memory newTaxes = new uint8[](1);
    //         newTaxes[0] = tax;
    //         systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

    //         // Mint some TEA
    //         console.log("TEA amount: ", teaAmount);
    //         systemState.mint(alice, teaAmount);
    //         systemState.mint(bob, teaAmount);

    //         vm.warp(1 + 2 * THREE_YEARS);

    //         uint104 unclaimedSIRAlice = systemState.unclaimedRewards(VAULT_ID, alice);
    //         uint104 unclaimedSIRBob = systemState.unclaimedRewards(VAULT_ID, alice);

    //         uint256 unclaimedSIRTheoretical = ((uint256(ISSUANCE_FIRST_3_YEARS) + uint256(ISSUANCE)) * THREE_YEARS) / 2;
    //         console.log("unclaimedSIRTheoretical", unclaimedSIRTheoretical);
    //         assertLe(unclaimedSIRAlice, unclaimedSIRTheoretical, "Alice unclaimed SIR is wrong");
    //         assertGe(
    //             unclaimedSIRAlice,
    //             unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 2), // Passing 3 years causes two updates in cumSIRPerTEAx96
    //             "Alice unclaimed SIR is wrong"
    //         );

    //         assertLe(unclaimedSIRBob, unclaimedSIRTheoretical, "Alice unclaimed SIR is wrong");
    //         assertGe(
    //             unclaimedSIRBob,
    //             unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 2), // Passing 3 years causes two updates in cumSIRPerTEAx96
    //             "Bob unclaimed SIR is wrong"
    //         );
    //     }

    //     function testFuzz_mintTwoUsersSequentially(uint256 teaAmount) public {
    //         uint8 tax = type(uint8).max;
    //         teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);

    //         // Set start of issuance
    //         vm.prank(systemControl);
    //         systemState.updateSystemState(VaultStructs.SystemParameters(1, 0, 0, false, 0));

    //         // Activate 1 vault
    //         vm.prank(systemControl);
    //         uint40[] memory oldVaults = new uint40[](0);
    //         uint40[] memory newVaults = new uint40[](1);
    //         newVaults[0] = VAULT_ID;
    //         uint8[] memory newTaxes = new uint8[](1);
    //         newTaxes[0] = tax;
    //         systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

    //         // Mint some TEA
    //         systemState.mint(alice, teaAmount);

    //         vm.warp(1 + THREE_YEARS);
    //         systemState.burn(alice, teaAmount);
    //         systemState.mint(bob, teaAmount);

    //         vm.warp(1 + 2 * THREE_YEARS);
    //         uint104 unclaimedSIRAlice = systemState.unclaimedRewards(VAULT_ID, alice);
    //         uint104 unclaimedSIRBob = systemState.unclaimedRewards(VAULT_ID, bob);

    //         uint256 unclaimedSIRAliceTheoretical = uint256(ISSUANCE_FIRST_3_YEARS) * THREE_YEARS;
    //         assertLe(unclaimedSIRAlice, unclaimedSIRAliceTheoretical, "Alice unclaimed SIR is wrong");
    //         assertGe(
    //             unclaimedSIRAlice,
    //             unclaimedSIRAliceTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 1),
    //             "Alice unclaimed SIR is wrong"
    //         );

    //         uint256 unclaimedSIRBobTheoretical = uint256(ISSUANCE) * THREE_YEARS;
    //         assertLe(unclaimedSIRBob, unclaimedSIRBobTheoretical, "Bob unclaimed SIR is wrong");
    //         assertGe(
    //             unclaimedSIRBob,
    //             unclaimedSIRBobTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 1),
    //             "Bob unclaimed SIR is wrong"
    //         );
    //     }

    //     function testFuzz_claimSIR(uint256 teaAmount) public {
    //         uint8 tax = type(uint8).max;
    //         teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);

    //         // Set start of issuance
    //         vm.prank(systemControl);
    //         systemState.updateSystemState(VaultStructs.SystemParameters(1, 0, 0, false, 0));

    //         // Activate 1 vault
    //         vm.prank(systemControl);
    //         uint40[] memory oldVaults = new uint40[](0);
    //         uint40[] memory newVaults = new uint40[](1);
    //         newVaults[0] = VAULT_ID;
    //         uint8[] memory newTaxes = new uint8[](1);
    //         newTaxes[0] = tax;
    //         systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

    //         // Mint some TEA
    //         systemState.mint(alice, teaAmount);

    //         // Reset rewards
    //         vm.warp(1 + 2 * THREE_YEARS);
    //         vm.prank(sir);
    //         uint104 unclaimedSIRAlice = systemState.claimSIR(VAULT_ID, alice);

    //         uint unclaimedSIRAliceTheoretical = (uint256(ISSUANCE_FIRST_3_YEARS) + uint256(ISSUANCE)) * THREE_YEARS;
    //         assertLe(unclaimedSIRAlice, unclaimedSIRAliceTheoretical);
    //         assertGe(unclaimedSIRAlice, unclaimedSIRAliceTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 2));

    //         assertEq(systemState.unclaimedRewards(VAULT_ID, alice), 0);
    //     }

    //     function testFuzz_claimSIRFailsCuzNotSir(address addr) public {
    //         vm.assume(addr != sir);

    //         uint8 tax = type(uint8).max;
    //         uint256 teaAmount = TEA_MAX_SUPPLY;

    //         // Set start of issuance
    //         vm.prank(systemControl);
    //         systemState.updateSystemState(VaultStructs.SystemParameters(1, 0, 0, false, 0));

    //         // Activate 1 vault
    //         vm.prank(systemControl);
    //         uint40[] memory oldVaults = new uint40[](0);
    //         uint40[] memory newVaults = new uint40[](1);
    //         newVaults[0] = VAULT_ID;
    //         uint8[] memory newTaxes = new uint8[](1);
    //         newTaxes[0] = tax;
    //         systemState.updateVaults(oldVaults, newVaults, newTaxes, tax);

    //         // Mint some TEA
    //         systemState.mint(alice, teaAmount);

    //         // Reset rewards
    //         vm.warp(1 + 2 * THREE_YEARS);
    //         vm.prank(addr);
    //         vm.expectRevert();
    //         systemState.claimSIR(VAULT_ID, alice);
    //     }

    //     function testFuzz_transferAll(uint256 teaAmount) public {
    //         teaAmount = _bound(teaAmount, 1, TEA_MAX_SUPPLY);

    //         // Mint for Alice for two years
    //         testFuzz_mintFirst3Years(1, 1, 1 + 365 days * 2, 1, teaAmount);

    //         // Transfer some to Bob
    //         vm.prank(alice);
    //         systemState.safeTransferFrom(alice, bob, VAULT_ID, teaAmount, "");

    //         skip(365 days * 2);

    //         uint104 unclaimedSIRAlice = systemState.unclaimedRewards(VAULT_ID, alice);
    //         uint104 unclaimedSIRBob = systemState.unclaimedRewards(VAULT_ID, bob);

    //         uint256 unclaimedSIRAliceTheoretical = uint256(ISSUANCE_FIRST_3_YEARS) * 365 days * 2;
    //         uint256 unclaimedSIRBobTheoretical = (uint256(ISSUANCE_FIRST_3_YEARS) + uint256(ISSUANCE)) * 365 days;

    //         assertLe(unclaimedSIRAlice, unclaimedSIRAliceTheoretical);
    //         assertGe(unclaimedSIRAlice, unclaimedSIRAliceTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 1)); // 1 update during safeTransferFrom

    //         assertLe(unclaimedSIRBob, unclaimedSIRBobTheoretical);
    //         assertGe(unclaimedSIRBob, unclaimedSIRBobTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 2)); // 1 update crossing 3 years + 1 update when calling unclaimedRewards
    //     }

    //     function testFuzz_transferSome(uint256 teaAmount, uint256 transferAmount) public {
    //         teaAmount = _bound(teaAmount, 2, TEA_MAX_SUPPLY);
    //         transferAmount = _bound(transferAmount, 1, teaAmount - 1);

    //         // Mint for Alice for two years
    //         testFuzz_mintFirst3Years(1, 1, 1 + 365 days * 2, 1, teaAmount);

    //         // Transfer some to Bob
    //         vm.prank(alice);
    //         systemState.safeTransferFrom(alice, bob, VAULT_ID, transferAmount, "");

    //         skip(365 days * 2);

    //         uint104 unclaimedSIRAlice = systemState.unclaimedRewards(VAULT_ID, alice);
    //         uint104 unclaimedSIRBob = systemState.unclaimedRewards(VAULT_ID, bob);

    //         uint256 unclaimedSIRTheoretical = uint256(ISSUANCE_FIRST_3_YEARS) * THREE_YEARS + uint256(ISSUANCE) * 365 days;

    //         assertLe(unclaimedSIRAlice + unclaimedSIRBob, unclaimedSIRTheoretical);
    //         assertGe(
    //             unclaimedSIRAlice + unclaimedSIRBob,
    //             unclaimedSIRTheoretical -
    //                 ErrorComputation.maxErrorBalanceSIR(teaAmount, 1) - // 1 update during safeTransferFrom
    //                 ErrorComputation.maxErrorBalanceSIR(teaAmount - transferAmount, 2) - // 1 update crossing 3 years + 1 update when calling unclaimedRewards
    //                 ErrorComputation.maxErrorBalanceSIR(transferAmount, 2) // 1 update crossing 3 years + 1 update when calling unclaimedRewards
    //         );
    //     }
    // }

    // ///////////////////////////////////////////////
    // //// I N V A R I A N T //// T E S T I N G ////
    // /////////////////////////////////////////////

    // contract SystemStateHandler is Test, SystemConstants {
    //     uint40 public startTime;
    //     uint40 public currentTime; // Necessary because Forge invariant testing does not keep track block.timestamp
    //     uint40 public currentTimeBefore;

    //     uint40 constant VAULT_ID = 42;
    //     uint public totalClaimedSIR;
    //     uint public _totalSIRMaxError;
    //     uint40 public totalTimeWithoutIssuanceFirst3Years;
    //     uint40 public totalTimeWithoutIssuanceAfter3Years;

    //     uint256 private _numUpdatesCumSIRPerTEA;
    //     mapping(uint256 idUser => uint256) private _numUpdatesCumSIRPerTEAForUser;

    //     SystemStateWrapper private _systemState;

    //     modifier advanceTime(uint24 timeSkip) {
    //         currentTimeBefore = currentTime;
    //         vm.warp(currentTime);
    //         if (_systemState.totalSupply(VAULT_ID) == 0) {
    //             if (currentTime < startTime + THREE_YEARS) {
    //                 if (currentTime + timeSkip <= startTime + THREE_YEARS) {
    //                     totalTimeWithoutIssuanceFirst3Years += timeSkip;
    //                 } else {
    //                     totalTimeWithoutIssuanceFirst3Years += startTime + THREE_YEARS - currentTime;
    //                     totalTimeWithoutIssuanceAfter3Years += currentTime + timeSkip - (startTime + THREE_YEARS);
    //                 }
    //             } else {
    //                 totalTimeWithoutIssuanceAfter3Years += timeSkip;
    //             }
    //         }
    //         currentTime += timeSkip;
    //         vm.warp(currentTime);
    //         _;
    //     }

    //     constructor(uint40 currentTime_) {
    //         startTime = currentTime_;
    //         currentTime = currentTime_;
    //         vm.warp(currentTime_);

    //         // We DO need the system control to start the emission of SIR.
    //         // We DO need the SIR address to be able to claim SIR.
    //         // We do NOT vault external in this test.
    //         _systemState = new SystemStateWrapper(address(this), address(this), address(0));

    //         // Start issuance
    //         _systemState.updateSystemState(
    //             VaultStructs.SystemParameters(currentTime, uint16(0), uint8(0), false, uint16(0))
    //         );

    //         // Activate one vault (VERY IMPORTANT to do it after updateSystemState)
    //         uint40[] memory newVaults = new uint40[](1);
    //         newVaults[0] = VAULT_ID;
    //         uint8[] memory newTaxes = new uint8[](1);
    //         newTaxes[0] = 1;
    //         _systemState.updateVaults(new uint40[](0), newVaults, newTaxes, 1);
    //     }

    //     function _idToAddr(uint id) private pure returns (address) {
    //         id = _bound(id, 1, 5);
    //         return vm.addr(id);
    //     }

    //     function _updateCumSIRPerTEA() private {
    //         bool crossThreeYears = currentTimeBefore < startTime + THREE_YEARS && currentTime > startTime + THREE_YEARS;
    //         if (crossThreeYears) _numUpdatesCumSIRPerTEA += 2;
    //         else _numUpdatesCumSIRPerTEA++;
    //     }

    //     function transfer(uint256 from, uint256 to, uint256 amount, uint24 timeSkip) external advanceTime(timeSkip) {
    //         address fromAddr = _idToAddr(from);
    //         address toAddr = _idToAddr(to);
    //         uint256 preBalance = _systemState.balanceOf(fromAddr, VAULT_ID);
    //         amount = _bound(amount, 0, preBalance);

    //         vm.prank(fromAddr);
    //         _systemState.safeTransferFrom(fromAddr, toAddr, VAULT_ID, amount, "");

    //         // Vault's cumulative SIR per TEA is updated
    //         _updateCumSIRPerTEA();

    //         // Update _totalSIRMaxError
    //         uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[from];
    //         _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(preBalance, numUpdates);
    //         numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[to];
    //         _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(preBalance, numUpdates);

    //         // Update indexes
    //         _numUpdatesCumSIRPerTEAForUser[from] = _numUpdatesCumSIRPerTEA;
    //         _numUpdatesCumSIRPerTEAForUser[to] = _numUpdatesCumSIRPerTEA;
    //     }

    //     function mint(uint256 user, uint256 amount, uint24 timeSkip) external advanceTime(timeSkip) {
    //         address addr = _idToAddr(user);

    //         uint256 preBalance = _systemState.balanceOf(addr, VAULT_ID);

    //         uint256 totalSupply = _systemState.totalSupply(VAULT_ID);
    //         amount = _bound(amount, 0, TEA_MAX_SUPPLY - totalSupply);

    //         _systemState.mint(addr, amount);

    //         // Vault's cumulative SIR per TEA is updated
    //         _updateCumSIRPerTEA();

    //         // Update _totalSIRMaxError
    //         uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[user];
    //         _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(preBalance, numUpdates);

    //         // Update index
    //         _numUpdatesCumSIRPerTEAForUser[user] = _numUpdatesCumSIRPerTEA;
    //     }

    //     function burn(uint256 user, uint256 amount, uint24 timeSkip) external advanceTime(timeSkip) {
    //         address addr = _idToAddr(user);
    //         uint256 preBalance = _systemState.balanceOf(addr, VAULT_ID);
    //         amount = _bound(amount, 0, preBalance);

    //         _systemState.burn(addr, amount);

    //         // Vault's cumulative SIR per TEA is updated
    //         _updateCumSIRPerTEA();

    //         // Update _totalSIRMaxError
    //         uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[user];
    //         _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(preBalance, numUpdates);

    //         // Update index
    //         _numUpdatesCumSIRPerTEAForUser[user] = _numUpdatesCumSIRPerTEA;
    //     }

    //     function claim(uint256 user, uint24 timeSkip) external advanceTime(timeSkip) {
    //         address addr = _idToAddr(user);
    //         uint256 balance = _systemState.balanceOf(addr, VAULT_ID);

    //         uint256 unclaimedSIR = _systemState.claimSIR(VAULT_ID, addr);
    //         totalClaimedSIR += unclaimedSIR;

    //         // Vault's cumulative SIR per TEA is updated
    //         _updateCumSIRPerTEA();

    //         // Update _totalSIRMaxError
    //         uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[user];
    //         _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(balance, numUpdates);

    //         // Update index
    //         _numUpdatesCumSIRPerTEAForUser[user] = _numUpdatesCumSIRPerTEA;
    //     }

    //     function issuanceFirst3Years() external pure returns (uint256) {
    //         return ISSUANCE_FIRST_3_YEARS;
    //     }

    //     function issuanceAfter3Years() external pure returns (uint256) {
    //         return ISSUANCE;
    //     }

    //     function totalUnclaimedSIR() external view returns (uint256) {
    //         return
    //             _systemState.unclaimedRewards(VAULT_ID, _idToAddr(1)) +
    //             _systemState.unclaimedRewards(VAULT_ID, _idToAddr(2)) +
    //             _systemState.unclaimedRewards(VAULT_ID, _idToAddr(3)) +
    //             _systemState.unclaimedRewards(VAULT_ID, _idToAddr(4)) +
    //             _systemState.unclaimedRewards(VAULT_ID, _idToAddr(5));
    //     }

    //     function totalSIRMaxError() external view returns (uint256 maxError) {
    //         uint256 numUpdates;
    //         uint256 balance;
    //         maxError = _totalSIRMaxError;

    //         // Vault's cumulative SIR per TEA is updated
    //         bool crossThreeYears = currentTimeBefore < startTime + THREE_YEARS && currentTime > startTime + THREE_YEARS;
    //         uint256 numUpdatesCumSIRPerTEA = crossThreeYears ? _numUpdatesCumSIRPerTEA + 2 : _numUpdatesCumSIRPerTEA + 1;

    //         for (uint256 i = 1; i <= 5; i++) {
    //             balance = _systemState.balanceOf(_idToAddr(i), VAULT_ID);
    //             if (balance > 0) {
    //                 numUpdates = numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[i];
    //                 maxError += ErrorComputation.maxErrorBalanceSIR(balance, numUpdates);
    //             }
    //         }
    //     }
    // }

    // contract SystemStateInvariantTest is Test, SystemConstants {
    //     SystemStateHandler private _systemStateHandler;

    //     modifier updateTime() {
    //         uint40 currentTime = _systemStateHandler.currentTime();
    //         vm.warp(currentTime);
    //         _;
    //     }

    //     function setUp() public {
    //         uint40 startTime = uint40(block.timestamp);
    //         if (startTime == 0) {
    //             startTime = 1;
    //         }

    //         _systemStateHandler = new SystemStateHandler(startTime);

    //         targetContract(address(_systemStateHandler));
    //     }

    //     function invariant_cumulativeSIR() public updateTime {
    //         uint256 totalSIR;
    //         uint40 startTime = _systemStateHandler.startTime();
    //         uint40 currentTime = _systemStateHandler.currentTime();
    //         vm.warp(currentTime);

    //         if (currentTime < startTime + THREE_YEARS) {
    //             totalSIR =
    //                 _systemStateHandler.issuanceFirst3Years() *
    //                 (currentTime - startTime - _systemStateHandler.totalTimeWithoutIssuanceFirst3Years());
    //         } else {
    //             totalSIR =
    //                 _systemStateHandler.issuanceFirst3Years() *
    //                 (THREE_YEARS - _systemStateHandler.totalTimeWithoutIssuanceFirst3Years()) +
    //                 _systemStateHandler.issuanceAfter3Years() *
    //                 (currentTime - startTime - THREE_YEARS - _systemStateHandler.totalTimeWithoutIssuanceAfter3Years());
    //         }

    //         assertLe(
    //             _systemStateHandler.totalClaimedSIR() + _systemStateHandler.totalUnclaimedSIR(),
    //             totalSIR,
    //             "Total SIR is too high"
    //         );

    //         uint256 totalSIRMaxError = _systemStateHandler.totalSIRMaxError();
    //         assertGe(
    //             _systemStateHandler.totalClaimedSIR() + _systemStateHandler.totalUnclaimedSIR(),
    //             totalSIR > totalSIRMaxError ? totalSIR - totalSIRMaxError : 0,
    //             "Total SIR is too low"
    //         );
    //     }
}
