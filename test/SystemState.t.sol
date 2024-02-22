// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {SystemState} from "src/SystemState.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {FullMath} from "src/libraries/FullMath.sol";
import {ErrorComputation} from "./ErrorComputation.sol";

contract SystemStateWrapper is SystemState {
    uint48 constant VAULT_ID = 42;

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
            supplyExcludeVault(VAULT_ID),
            lpersBalances
        );

        // Transfer TEA
        _balances[from] -= amount;
        _balances[to] += amount;
    }

    function donate(address from, uint256 amount) external {
        // Get _balances
        LPersBalances memory lpersBalances = LPersBalances(from, _balances[from], address(this), _balanceVault);

        // Update SIR issuance
        updateLPerIssuanceParams(
            false,
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            supplyExcludeVault(VAULT_ID),
            lpersBalances
        );

        // Transfer TEA
        _balances[from] -= amount;
        _balanceVault += uint128(amount);
    }

    /// @dev Mints TEA for POL only
    function mintPol(uint256 amountPol) external {
        // Mint TEA
        unchecked {
            _balanceVault += uint128(amountPol);
            require(_totalSupply + amountPol <= SystemConstants.TEA_MAX_SUPPLY, "Max supply exceeded");
            _totalSupply += uint128(amountPol);
        }
    }

    /// @dev Mints TEA to the given address and for POL
    function mint(address to, uint256 amount, uint256 amountPol) external {
        // Get _balances
        LPersBalances memory lpersBalances = LPersBalances(to, _balances[to], address(this), _balanceVault);

        // Update SIR issuance
        updateLPerIssuanceParams(
            false,
            VAULT_ID,
            systemParams,
            vaultIssuanceParams[VAULT_ID],
            supplyExcludeVault(VAULT_ID),
            lpersBalances
        );

        // Mint TEA
        unchecked {
            _balances[to] += amount;
            require(_totalSupply + amount <= SystemConstants.TEA_MAX_SUPPLY, "Max supply exceeded");
            _totalSupply += uint128(amount);

            _balanceVault += uint128(amountPol);
            require(_totalSupply + amountPol <= SystemConstants.TEA_MAX_SUPPLY, "Max supply exceeded");
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
            supplyExcludeVault(VAULT_ID),
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
            require(_totalSupply + amountPol <= SystemConstants.TEA_MAX_SUPPLY, "Max supply exceeded");
            _totalSupply += uint128(amountPol);
        }
    }

    function balanceOf(address owner, uint256 vaultId) public view override returns (uint256) {
        assert(vaultId == VAULT_ID);

        return owner == address(this) ? _balanceVault : _balances[owner];
    }

    function totalSupply(uint256 vaultId) public view returns (uint256) {
        assert(vaultId == VAULT_ID);

        return _totalSupply;
    }

    function supplyExcludeVault(uint256 vaultId) internal view override returns (uint256) {
        assert(vaultId == VAULT_ID);

        return _totalSupply - _balanceVault;
    }

    function cumulativeSIRPerTEA(uint256 vaultId) public view override returns (uint176) {
        if (vaultId == VAULT_ID)
            return cumulativeSIRPerTEA(systemParams, vaultIssuanceParams[vaultId], supplyExcludeVault(VAULT_ID));
        return type(uint176).max / uint176(vaultId); // To make it somewhat arbitrary
    }
}

contract SystemStateTest is Test {
    uint48 constant VAULT_ID = 42;
    uint40 constant MAX_TS = 599 * 365 days; // See SystemState.sol comments for explanation
    SystemStateWrapper systemState;

    uint40 tsStart;

    address systemControl;
    address sir;

    address alice;
    address bob;

    function _activateTax() private {
        vm.prank(systemControl);
        uint48[] memory oldVaults = new uint48[](0);
        uint48[] memory newVaults = new uint48[](1);
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
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsMint, tsStart + SystemConstants.THREE_YEARS));
                durationBefore3Years = tsCheckRewards - tsMint;
            } else if (tsMint > tsStart + SystemConstants.THREE_YEARS) {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsMint, MAX_TS));
                durationAfter3Years = tsCheckRewards - tsMint;
            } else {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsStart + SystemConstants.THREE_YEARS, MAX_TS));
                durationBefore3Years = tsStart + SystemConstants.THREE_YEARS - tsMint;
                durationAfter3Years = tsCheckRewards - (tsStart + SystemConstants.THREE_YEARS);
            }

            // Activate tax
            vm.warp(tsUpdateTax);
            _activateTax();

            // Mint some TEA
            vm.warp(tsMint);
            if (teaAmount > 0) systemState.mint(alice, teaAmount, teaAmountPOL);
            else systemState.mintPol(teaAmountPOL);
        } else {
            if (checkFirst3Years) {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsUpdateTax, tsStart + SystemConstants.THREE_YEARS));
                durationBefore3Years = tsCheckRewards - tsUpdateTax;
            } else if (tsUpdateTax > tsStart + SystemConstants.THREE_YEARS) {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsUpdateTax, MAX_TS));
                durationAfter3Years = tsCheckRewards - tsUpdateTax;
            } else {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsStart + SystemConstants.THREE_YEARS, MAX_TS));
                durationBefore3Years = tsStart + SystemConstants.THREE_YEARS - tsUpdateTax;
                durationAfter3Years = tsCheckRewards - (tsStart + SystemConstants.THREE_YEARS);
            }

            // Mint some TEA
            vm.warp(tsMint);
            if (teaAmount > 0) systemState.mint(alice, teaAmount, teaAmountPOL);
            else systemState.mintPol(teaAmountPOL);

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

        teaAmount = _bound(teaAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmount);

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
        tsUpdateTax = uint40(_bound(tsUpdateTax, tsStart, tsStart + SystemConstants.THREE_YEARS));
        tsMint = uint40(_bound(tsMint, tsStart, tsStart + SystemConstants.THREE_YEARS));

        teaAmount = _bound(teaAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmount);

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
            ((SystemConstants.ISSUANCE_FIRST_3_YEARS * duration) << 96) / teaAmount,
            ErrorComputation.maxErrorCumSIRPerTEA(1)
        );

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = SystemConstants.ISSUANCE_FIRST_3_YEARS * duration;
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 1));
        }

        // Check no rewards for POL
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, address(systemState));
        assertEq(unclaimedSIR, 0);
    }

    function testFuzz_mintAfterFirst3Years(
        uint40 tsUpdateTax,
        uint40 tsMint,
        uint40 tsCheckRewards,
        uint256 teaAmount,
        uint256 teaAmountPOL
    ) public {
        // Tax and mint after the first 3 years
        tsUpdateTax = uint40(_bound(tsUpdateTax, tsStart + SystemConstants.THREE_YEARS, MAX_TS));
        tsMint = uint40(_bound(tsMint, tsStart + SystemConstants.THREE_YEARS, MAX_TS));

        teaAmount = _bound(teaAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmount);

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
            ((SystemConstants.ISSUANCE * duration) << 96) / teaAmount,
            ErrorComputation.maxErrorCumSIRPerTEA(1)
        );

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = SystemConstants.ISSUANCE * duration;
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 1));
        }

        // Check rewards for POL
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, address(systemState));
        assertEq(unclaimedSIR, 0);
    }

    function testFuzz_mint(
        uint40 tsUpdateTax,
        uint40 tsMint,
        uint40 tsCheckRewards,
        uint256 teaAmount,
        uint256 teaAmountPOL
    ) public {
        // Tax and mint before the 3 years have passed
        tsUpdateTax = uint40(_bound(tsUpdateTax, tsStart, tsStart + SystemConstants.THREE_YEARS));
        tsMint = uint40(_bound(tsMint, tsStart, tsStart + SystemConstants.THREE_YEARS));

        teaAmount = _bound(teaAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmount);

        (
            uint256 durationBefore3Years,
            uint256 durationAfter3Years,
            uint176 cumSIRPerTEAx96
        ) = _updateTaxMintAndCheckRewards(tsUpdateTax, tsMint, tsCheckRewards, false, teaAmount, teaAmountPOL);

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumSIRPerTEAx96,
            ((SystemConstants.ISSUANCE_FIRST_3_YEARS *
                durationBefore3Years +
                SystemConstants.ISSUANCE *
                durationAfter3Years) << 96) / teaAmount,
            ErrorComputation.maxErrorCumSIRPerTEA(2)
        );

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = SystemConstants.ISSUANCE_FIRST_3_YEARS *
            durationBefore3Years +
            SystemConstants.ISSUANCE *
            durationAfter3Years;
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 2));
        }

        // Check rewards for POL
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, address(systemState));
        assertEq(unclaimedSIR, 0);
    }

    function testFuzz_mintTwoUsersSequentially(uint256 teaAmount, uint256 teaAmountPOL, uint256 teaAmountPOL2) public {
        teaAmount = _bound(teaAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, (SystemConstants.TEA_MAX_SUPPLY - teaAmount) / 2);
        teaAmountPOL2 = _bound(teaAmountPOL2, 0, teaAmount);
        vm.assume(teaAmount + 2 * teaAmountPOL + teaAmountPOL2 <= SystemConstants.TEA_MAX_SUPPLY);

        // Activate tax
        vm.warp(tsStart);
        _activateTax();

        // Mint TEA for Alice
        systemState.mint(alice, teaAmount, teaAmountPOL);

        // Burn TEA from Alice
        vm.warp(tsStart + 2 * SystemConstants.THREE_YEARS);
        systemState.burn(alice, teaAmount, teaAmountPOL2);

        // Mint TEA for Bob
        systemState.mint(bob, teaAmount, teaAmountPOL);

        vm.warp(1 + 4 * SystemConstants.THREE_YEARS);

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = uint256(SystemConstants.ISSUANCE_FIRST_3_YEARS + SystemConstants.ISSUANCE) *
            SystemConstants.THREE_YEARS;
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 2));
        }

        // Check rewards for Bob
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, bob);
        unclaimedSIRTheoretical = uint256(2) * SystemConstants.ISSUANCE * SystemConstants.THREE_YEARS;
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 3));
        }

        // Check rewards for POL
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, address(systemState));
        assertEq(unclaimedSIR, 0);
    }

    function testFuzz_burnAll(
        uint40 tsMint,
        uint40 tsBurn,
        uint40 tsCheckRewards,
        uint256 teaAmount,
        uint256 teaAmountPOL,
        uint256 teaAmountPOL2
    ) public {
        // Adjust timestamps
        tsMint = uint40(_bound(tsMint, tsStart, MAX_TS));
        tsBurn = uint40(_bound(tsBurn, tsMint, MAX_TS));
        tsCheckRewards = uint40(_bound(tsCheckRewards, tsBurn, MAX_TS));

        // Adjust amounts
        teaAmount = _bound(teaAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmount);
        teaAmountPOL2 = _bound(teaAmountPOL2, 0, teaAmount);
        vm.assume(teaAmountPOL + teaAmountPOL2 > 0);

        // Activate tax
        _activateTax();

        // Mint some TEA
        vm.warp(tsMint);
        systemState.mint(alice, teaAmount, teaAmountPOL);

        // Burn some TEA
        vm.warp(tsBurn);
        systemState.burn(alice, teaAmount, teaAmountPOL2);

        // Get cumulative SIR per TEA
        vm.warp(tsCheckRewards);
        uint176 cumSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        uint256 durationBeforeBurnBefore3Years;
        uint256 durationBeforeBurnAfter3Years;
        if (tsMint < tsStart + SystemConstants.THREE_YEARS && tsBurn < tsStart + SystemConstants.THREE_YEARS) {
            durationBeforeBurnBefore3Years = tsBurn - tsMint;
        } else if (tsMint >= tsStart + SystemConstants.THREE_YEARS) {
            durationBeforeBurnAfter3Years = tsBurn - tsMint;
        } else {
            durationBeforeBurnBefore3Years = tsStart + SystemConstants.THREE_YEARS - tsMint;
            durationBeforeBurnAfter3Years = tsBurn - (tsStart + SystemConstants.THREE_YEARS);
        }

        uint256 durationAfterBurnBefore3Years;
        uint256 durationAfterBurnAfter3Years;
        if (tsBurn < tsStart + SystemConstants.THREE_YEARS && tsCheckRewards < tsStart + SystemConstants.THREE_YEARS) {
            durationAfterBurnBefore3Years = tsCheckRewards - tsBurn;
        } else if (tsBurn >= tsStart + SystemConstants.THREE_YEARS) {
            durationAfterBurnAfter3Years = tsCheckRewards - tsBurn;
        } else {
            durationAfterBurnBefore3Years = tsStart + SystemConstants.THREE_YEARS - tsBurn;
            durationAfterBurnAfter3Years = tsCheckRewards - (tsStart + SystemConstants.THREE_YEARS);
        }

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumSIRPerTEAx96,
            ((SystemConstants.ISSUANCE_FIRST_3_YEARS *
                durationBeforeBurnBefore3Years +
                SystemConstants.ISSUANCE *
                durationBeforeBurnAfter3Years) << 96) / teaAmount,
            ErrorComputation.maxErrorCumSIRPerTEA(3)
        );

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = SystemConstants.ISSUANCE_FIRST_3_YEARS *
            durationBeforeBurnBefore3Years +
            SystemConstants.ISSUANCE *
            durationBeforeBurnAfter3Years;
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 3));
        }

        // Check rewards for POL
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, address(systemState));
        assertEq(unclaimedSIR, 0);
    }

    function testFuzz_burnSome(
        uint40 tsMint,
        uint40 tsBurn,
        uint40 tsCheckRewards,
        uint256 teaAmount,
        uint256 teaAmountToBurn,
        uint256 teaAmountPOL,
        uint256 teaAmountPOL2
    ) public {
        // Adjust timestamps
        tsMint = uint40(_bound(tsMint, tsStart, MAX_TS));
        tsBurn = uint40(_bound(tsBurn, tsMint, MAX_TS));
        tsCheckRewards = uint40(_bound(tsCheckRewards, tsBurn, MAX_TS));

        // Adjust amounts
        teaAmount = _bound(teaAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountToBurn = _bound(teaAmountToBurn, 0, teaAmount - 1);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmount);
        teaAmountPOL2 = _bound(
            teaAmountPOL2,
            0,
            SystemConstants.TEA_MAX_SUPPLY - teaAmount + teaAmountToBurn - teaAmountPOL
        );
        vm.assume(teaAmountPOL + teaAmountPOL2 > 0);

        // Activate tax
        _activateTax();

        // Mint some TEA
        vm.warp(tsMint);
        systemState.mint(alice, teaAmount, teaAmountPOL);

        // Burn some TEA
        vm.warp(tsBurn);
        systemState.burn(alice, teaAmountToBurn, teaAmountPOL2);

        // Get cumulative SIR per TEA
        vm.warp(tsCheckRewards);
        uint176 cumSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        uint256 durationBeforeBurnBefore3Years;
        uint256 durationBeforeBurnAfter3Years;
        if (tsMint < tsStart + SystemConstants.THREE_YEARS && tsBurn < tsStart + SystemConstants.THREE_YEARS) {
            durationBeforeBurnBefore3Years = tsBurn - tsMint;
        } else if (tsMint >= tsStart + SystemConstants.THREE_YEARS) {
            durationBeforeBurnAfter3Years = tsBurn - tsMint;
        } else {
            durationBeforeBurnBefore3Years = tsStart + SystemConstants.THREE_YEARS - tsMint;
            durationBeforeBurnAfter3Years = tsBurn - (tsStart + SystemConstants.THREE_YEARS);
        }

        uint256 durationAfterBurnBefore3Years;
        uint256 durationAfterBurnAfter3Years;
        if (tsBurn < tsStart + SystemConstants.THREE_YEARS && tsCheckRewards < tsStart + SystemConstants.THREE_YEARS) {
            durationAfterBurnBefore3Years = tsCheckRewards - tsBurn;
        } else if (tsBurn >= tsStart + SystemConstants.THREE_YEARS) {
            durationAfterBurnAfter3Years = tsCheckRewards - tsBurn;
        } else {
            durationAfterBurnBefore3Years = tsStart + SystemConstants.THREE_YEARS - tsBurn;
            durationAfterBurnAfter3Years = tsCheckRewards - (tsStart + SystemConstants.THREE_YEARS);
        }

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumSIRPerTEAx96,
            ((SystemConstants.ISSUANCE_FIRST_3_YEARS *
                durationBeforeBurnBefore3Years +
                SystemConstants.ISSUANCE *
                durationBeforeBurnAfter3Years) << 96) /
                teaAmount +
                ((SystemConstants.ISSUANCE_FIRST_3_YEARS *
                    durationAfterBurnBefore3Years +
                    SystemConstants.ISSUANCE *
                    durationAfterBurnAfter3Years) << 96) /
                (teaAmount - teaAmountToBurn),
            ErrorComputation.maxErrorCumSIRPerTEA(3)
        );

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = SystemConstants.ISSUANCE_FIRST_3_YEARS *
            (durationBeforeBurnBefore3Years + durationAfterBurnBefore3Years) +
            SystemConstants.ISSUANCE *
            (durationBeforeBurnAfter3Years + durationAfterBurnAfter3Years);
        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(
                unclaimedSIR,
                unclaimedSIRTheoretical -
                    ErrorComputation.maxErrorBalanceSIR(teaAmount, 2) -
                    ErrorComputation.maxErrorBalanceSIR(teaAmount - teaAmountToBurn, 2)
            );
        }

        // Check rewards for POL
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, address(systemState));
        assertEq(unclaimedSIR, 0);
    }

    function testFuzz_transfer(
        uint40 tsMint,
        uint40 tsTransfer,
        uint40 tsCheckRewards,
        uint256 teaAmountMint,
        uint256 teaAmountPOL,
        uint256 teaAmountTransfer
    ) public {
        // Adjust timestamps
        tsMint = uint40(_bound(tsMint, tsStart, MAX_TS));
        tsTransfer = uint40(_bound(tsTransfer, tsMint, MAX_TS));
        tsCheckRewards = uint40(_bound(tsCheckRewards, tsTransfer, MAX_TS));

        // Adjust amounts
        teaAmountMint = _bound(teaAmountMint, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmountMint);
        teaAmountTransfer = _bound(teaAmountTransfer, 0, teaAmountMint);

        // Activate tax
        _activateTax();

        // Mint some TEA
        vm.warp(tsMint);
        systemState.mint(alice, teaAmountMint, teaAmountPOL);

        // Transfer some TEA
        vm.warp(tsTransfer);
        systemState.transfer(alice, bob, teaAmountTransfer);

        // Get cumulative SIR per TEA
        vm.warp(tsCheckRewards);
        uint176 cumSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        uint256 durationAliceBefore3Years;
        uint256 durationAliceAfter3Years;
        if (tsMint < tsStart + SystemConstants.THREE_YEARS && tsTransfer < tsStart + SystemConstants.THREE_YEARS) {
            durationAliceBefore3Years = tsTransfer - tsMint;
        } else if (tsMint >= tsStart + SystemConstants.THREE_YEARS) {
            durationAliceAfter3Years = tsTransfer - tsMint;
        } else {
            durationAliceBefore3Years = tsStart + SystemConstants.THREE_YEARS - tsMint;
            durationAliceAfter3Years = tsTransfer - (tsStart + SystemConstants.THREE_YEARS);
        }

        uint256 durationBobBefore3Years;
        uint256 durationBobAfter3Years;
        if (
            tsTransfer < tsStart + SystemConstants.THREE_YEARS && tsCheckRewards < tsStart + SystemConstants.THREE_YEARS
        ) {
            durationBobBefore3Years = tsCheckRewards - tsTransfer;
        } else if (tsTransfer >= tsStart + SystemConstants.THREE_YEARS) {
            durationBobAfter3Years = tsCheckRewards - tsTransfer;
        } else {
            durationBobBefore3Years = tsStart + SystemConstants.THREE_YEARS - tsTransfer;
            durationBobAfter3Years = tsCheckRewards - (tsStart + SystemConstants.THREE_YEARS);
        }

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumSIRPerTEAx96,
            ((SystemConstants.ISSUANCE_FIRST_3_YEARS *
                (durationAliceBefore3Years + durationBobBefore3Years) +
                SystemConstants.ISSUANCE *
                (durationAliceAfter3Years + durationBobAfter3Years)) << 96) / teaAmountMint,
            ErrorComputation.maxErrorCumSIRPerTEA(3)
        );

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = (SystemConstants.ISSUANCE_FIRST_3_YEARS *
            durationAliceBefore3Years +
            SystemConstants.ISSUANCE *
            durationAliceAfter3Years) +
            ((SystemConstants.ISSUANCE_FIRST_3_YEARS *
                durationBobBefore3Years +
                SystemConstants.ISSUANCE *
                durationBobAfter3Years) * (teaAmountMint - teaAmountTransfer)) /
            teaAmountMint;

        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(
                unclaimedSIR,
                unclaimedSIRTheoretical -
                    ErrorComputation.maxErrorBalanceSIR(teaAmountMint, 2) -
                    ErrorComputation.maxErrorBalanceSIR(teaAmountMint - teaAmountTransfer, 2)
            );
        }

        // Check rewards for Bob
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, bob);
        unclaimedSIRTheoretical =
            ((SystemConstants.ISSUANCE_FIRST_3_YEARS *
                durationBobBefore3Years +
                SystemConstants.ISSUANCE *
                durationBobAfter3Years) * teaAmountTransfer) /
            teaAmountMint;

        if (unclaimedSIRTheoretical == 0) assertEq(unclaimedSIR, 0);
        else {
            assertLe(unclaimedSIR, unclaimedSIRTheoretical);
            assertGe(unclaimedSIR, unclaimedSIRTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmountTransfer, 3));
        }
    }

    function testFuzz_claimSIR(uint40 tsMint, uint40 tsCheckRewards, uint256 teaAmount, uint256 teaAmountPOL) public {
        // Adjust timestamps
        tsMint = uint40(_bound(tsMint, tsStart, MAX_TS));
        tsCheckRewards = uint40(_bound(tsCheckRewards, tsMint, MAX_TS));

        // Adjust amounts
        teaAmount = _bound(teaAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmount);
        vm.assume(teaAmount + teaAmountPOL > 0);

        // Activate tax
        _activateTax();

        // Mint some TEA
        vm.warp(tsMint);
        systemState.mint(alice, teaAmount, teaAmountPOL);

        // Reset rewards
        vm.warp(tsCheckRewards);
        vm.prank(sir);
        uint144 unclaimedSIRAlice = systemState.claimSIR(VAULT_ID, alice);

        uint256 durationBefore3Years;
        uint256 durationAfter3Years;
        if (tsMint < tsStart + SystemConstants.THREE_YEARS && tsCheckRewards < tsStart + SystemConstants.THREE_YEARS) {
            durationBefore3Years = tsCheckRewards - tsMint;
        } else if (tsMint >= tsStart + SystemConstants.THREE_YEARS) {
            durationAfter3Years = tsCheckRewards - tsMint;
        } else {
            durationBefore3Years = tsStart + SystemConstants.THREE_YEARS - tsMint;
            durationAfter3Years = tsCheckRewards - (tsStart + SystemConstants.THREE_YEARS);
        }

        uint256 unclaimedSIRAliceTheoretical = (durationBefore3Years *
            SystemConstants.ISSUANCE_FIRST_3_YEARS +
            durationAfter3Years *
            SystemConstants.ISSUANCE);

        if (unclaimedSIRAliceTheoretical == 0) assertEq(unclaimedSIRAlice, 0);
        else {
            assertLe(unclaimedSIRAlice, unclaimedSIRAliceTheoretical);
            assertGe(
                unclaimedSIRAlice,
                unclaimedSIRAliceTheoretical - ErrorComputation.maxErrorBalanceSIR(teaAmount, 2)
            );
        }

        assertEq(systemState.unclaimedRewards(VAULT_ID, alice), 0);
    }

    function testFuzz_claimSIRFailsCuzNotSir(
        uint40 tsMint,
        uint40 tsCheckRewards,
        uint256 teaAmount,
        uint256 teaAmountPOL
    ) public {
        // Adjust timestamps
        tsMint = uint40(_bound(tsMint, tsStart, MAX_TS));
        tsCheckRewards = uint40(_bound(tsCheckRewards, tsMint, MAX_TS));

        // Adjust amounts
        teaAmount = _bound(teaAmount, 0, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmount);
        vm.assume(teaAmount + teaAmountPOL > 0);

        // Activate tax
        _activateTax();

        // Mint some TEA
        vm.warp(tsMint);
        systemState.mint(alice, teaAmount, teaAmountPOL);

        // Reset rewards
        vm.warp(tsCheckRewards);
        vm.expectRevert();
        systemState.claimSIR(VAULT_ID, alice);
    }

    function testFuzz_updateSystem(uint16 baseFee, uint8 lpFee, bool mintingStopped, uint16 numVaults) public {
        numVaults = uint16(_bound(numVaults, 0, uint16(type(uint8).max) ** 2));

        // Update system vaultState
        vm.prank(systemControl);
        systemState.updateSystemState(baseFee, lpFee, mintingStopped);

        // Update vaults
        uint48[] memory oldVaults = new uint48[](0);
        uint48[] memory newVaults = new uint48[](numVaults); // Max # of vaults
        uint8[] memory newTaxes = new uint8[](numVaults);
        for (uint256 i = 0; i < numVaults; i++) {
            newVaults[i] = uint48(i + 1);
            newTaxes[i] = 1;
        }
        vm.prank(systemControl);
        systemState.updateVaults(oldVaults, newVaults, newTaxes, numVaults);

        // Check system vaultState
        (uint40 tsIssuanceStart_, uint16 baseFee_, uint8 lpFee_, bool mintingStopped_, uint16 cumTax_) = systemState
            .systemParams();

        assertEq(tsIssuanceStart_, tsStart);
        assertEq(baseFee_, baseFee);
        assertEq(lpFee_, lpFee);
        assertEq(mintingStopped_, mintingStopped);
        assertEq(cumTax_, numVaults);

        // Update vaults to only 1 with max tax
        uint48[] memory veryNewVaults = new uint48[](1); // Max # of vaults
        uint8[] memory veryNewTaxes = new uint8[](1);
        veryNewVaults[0] = 1;
        veryNewTaxes[0] = type(uint8).max;
        vm.prank(systemControl);
        systemState.updateVaults(newVaults, veryNewVaults, veryNewTaxes, type(uint8).max);

        // Check system vaultState
        (tsIssuanceStart_, baseFee_, lpFee_, mintingStopped_, cumTax_) = systemState.systemParams();

        assertEq(tsIssuanceStart_, tsStart);
        assertEq(baseFee_, baseFee);
        assertEq(lpFee_, lpFee);
        assertEq(mintingStopped_, mintingStopped);
        assertEq(cumTax_, type(uint8).max);
    }

    function testFuzz_updateSystemStateNotSystemControl(uint16 baseFee, uint8 lpFee, bool mintingStopped) public {
        // Update system vaultState
        vm.expectRevert();
        systemState.updateSystemState(baseFee, lpFee, mintingStopped);
    }

    function testFuzz_updateSystemVaultsNotSystemControl(uint16 numVaults) public {
        numVaults = uint16(_bound(numVaults, 0, uint16(type(uint8).max) ** 2));

        // Update vaults
        uint48[] memory oldVaults = new uint48[](0);
        uint48[] memory newVaults = new uint48[](numVaults); // Max # of vaults
        uint8[] memory newTaxes = new uint8[](numVaults);
        for (uint256 i = 0; i < numVaults; i++) {
            newVaults[i] = uint48(i + 1);
            newTaxes[i] = 1;
        }
        vm.expectRevert();
        systemState.updateVaults(oldVaults, newVaults, newTaxes, numVaults);
    }
}

///////////////////////////////////////////////
//// I N V A R I A N T //// T E S T I N G ////
/////////////////////////////////////////////

contract SystemStateHandler is Test {
    uint40 public startTime;
    uint40 public currentTime; // Necessary because Forge invariant testing does not keep track block.timestamp
    uint40 public currentTimeBefore;

    uint40 public constant VAULT_ID = 42;
    uint256 public totalClaimedSIR;
    uint256 private _totalSIRMaxError;
    uint40 public totalTimeWithoutIssuanceFirst3Years;
    uint40 public totalTimeWithoutIssuanceAfter3Years;

    uint256 private _numUpdatesCumSIRPerTEA;
    mapping(address user => uint256) private _numUpdatesCumSIRPerTEAForUser;

    SystemStateWrapper public systemState;

    uint256 public vaultBalanceOld;

    modifier advanceTime(uint24 timeSkip) {
        vaultBalanceOld = systemState.balanceOf(address(systemState), VAULT_ID);

        currentTimeBefore = currentTime;
        vm.warp(currentTime);
        if (systemState.totalSupply(VAULT_ID) == 0) {
            if (currentTime < startTime + SystemConstants.THREE_YEARS) {
                if (currentTime + timeSkip <= startTime + SystemConstants.THREE_YEARS) {
                    totalTimeWithoutIssuanceFirst3Years += timeSkip;
                } else {
                    totalTimeWithoutIssuanceFirst3Years += startTime + SystemConstants.THREE_YEARS - currentTime;
                    totalTimeWithoutIssuanceAfter3Years +=
                        currentTime +
                        timeSkip -
                        (startTime + SystemConstants.THREE_YEARS);
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
        systemState = new SystemStateWrapper(address(this), address(this));

        // Activate one vault (VERY IMPORTANT to do it after updateSystemState)
        uint48[] memory newVaults = new uint48[](1);
        newVaults[0] = VAULT_ID;
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = 69;
        systemState.updateVaults(new uint48[](0), newVaults, newTaxes, 69);
    }

    function _idToAddr(uint id) private pure returns (address) {
        id = _bound(id, 1, 5);
        return vm.addr(id);
    }

    function _updateCumSIRPerTEA() private {
        bool crossThreeYears = currentTimeBefore <= startTime + SystemConstants.THREE_YEARS &&
            currentTime > startTime + SystemConstants.THREE_YEARS;
        if (crossThreeYears) _numUpdatesCumSIRPerTEA += 2;
        else _numUpdatesCumSIRPerTEA++;
    }

    function transfer(uint256 from, uint256 to, uint256 amount, uint24 timeSkip) external advanceTime(timeSkip) {
        address fromAddr = _idToAddr(from);
        address toAddr = _idToAddr(to);
        uint256 preBalance = systemState.balanceOf(fromAddr, VAULT_ID);
        amount = _bound(amount, 0, preBalance);

        vm.prank(fromAddr);
        systemState.transfer(fromAddr, toAddr, amount);

        // Vault's cumulative SIR per TEA is updated
        _updateCumSIRPerTEA();

        // Update totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[fromAddr];
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(preBalance, numUpdates);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[toAddr];
        uint256 toBalance = systemState.balanceOf(toAddr, VAULT_ID);
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(toBalance, numUpdates);

        // Update indexes
        _numUpdatesCumSIRPerTEAForUser[fromAddr] = _numUpdatesCumSIRPerTEA;
        _numUpdatesCumSIRPerTEAForUser[toAddr] = _numUpdatesCumSIRPerTEA;
    }

    function mint(uint256 user, uint256 amount, uint256 amountPOL, uint24 timeSkip) external advanceTime(timeSkip) {
        address addr = _idToAddr(user);

        uint256 preBalance = systemState.balanceOf(addr, VAULT_ID);
        uint256 vaultPreBalance = systemState.balanceOf(address(systemState), VAULT_ID);

        uint256 totalSupply = systemState.totalSupply(VAULT_ID);
        amount = _bound(amount, 0, SystemConstants.TEA_MAX_SUPPLY - totalSupply);
        amountPOL = _bound(amountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - totalSupply - amount);

        systemState.mint(addr, amount, amountPOL);

        // Vault's cumulative SIR per TEA is updated
        _updateCumSIRPerTEA();

        // Update totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[addr];
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(preBalance, numUpdates);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[address(systemState)];
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(vaultPreBalance, numUpdates);

        // Update index
        _numUpdatesCumSIRPerTEAForUser[addr] = _numUpdatesCumSIRPerTEA;
        _numUpdatesCumSIRPerTEAForUser[address(systemState)] = _numUpdatesCumSIRPerTEA;
    }

    function burn(uint256 user, uint256 amount, uint256 amountPOL, uint24 timeSkip) external advanceTime(timeSkip) {
        address addr = _idToAddr(user);
        uint256 preBalance = systemState.balanceOf(addr, VAULT_ID);
        amount = _bound(amount, 0, preBalance);
        uint256 vaultPreBalance = systemState.balanceOf(address(systemState), VAULT_ID);
        amountPOL = _bound(amountPOL, 0, amount);

        systemState.burn(addr, amount, amountPOL);

        // Vault's cumulative SIR per TEA is updated
        _updateCumSIRPerTEA();

        // Update totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[addr];
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(preBalance, numUpdates);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[address(systemState)];
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(vaultPreBalance, numUpdates);

        // Update index
        _numUpdatesCumSIRPerTEAForUser[addr] = _numUpdatesCumSIRPerTEA;
        _numUpdatesCumSIRPerTEAForUser[address(systemState)] = _numUpdatesCumSIRPerTEA;
    }

    function claim(uint256 user, uint24 timeSkip) external advanceTime(timeSkip) {
        address addr = _idToAddr(user);
        uint256 balance = systemState.balanceOf(addr, VAULT_ID);

        uint256 unclaimedSIR = systemState.claimSIR(VAULT_ID, addr);
        totalClaimedSIR += unclaimedSIR;

        // Vault's cumulative SIR per TEA is updated
        _updateCumSIRPerTEA();

        // Update totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[addr];
        _totalSIRMaxError += ErrorComputation.maxErrorBalanceSIR(balance, numUpdates);

        // Update index
        _numUpdatesCumSIRPerTEAForUser[addr] = _numUpdatesCumSIRPerTEA;
    }

    function issuanceFirst3Years() external pure returns (uint256) {
        return SystemConstants.ISSUANCE_FIRST_3_YEARS;
    }

    function issuanceAfter3Years() external pure returns (uint256) {
        return SystemConstants.ISSUANCE;
    }

    function totalUnclaimedSIR() external view returns (uint256) {
        return
            systemState.unclaimedRewards(VAULT_ID, _idToAddr(1)) +
            systemState.unclaimedRewards(VAULT_ID, _idToAddr(2)) +
            systemState.unclaimedRewards(VAULT_ID, _idToAddr(3)) +
            systemState.unclaimedRewards(VAULT_ID, _idToAddr(4)) +
            systemState.unclaimedRewards(VAULT_ID, _idToAddr(5));
    }

    function totalSIRMaxError() external view returns (uint256 maxError) {
        uint256 numUpdates;
        uint256 balance;
        maxError = _totalSIRMaxError;

        // Vault's cumulative SIR per TEA is updated
        bool crossThreeYears = currentTimeBefore < startTime + SystemConstants.THREE_YEARS &&
            currentTime > startTime + SystemConstants.THREE_YEARS;
        uint256 numUpdatesCumSIRPerTEA = crossThreeYears ? _numUpdatesCumSIRPerTEA + 2 : _numUpdatesCumSIRPerTEA + 1;

        for (uint256 i = 1; i <= 5; i++) {
            balance = systemState.balanceOf(_idToAddr(i), VAULT_ID);
            if (balance > 0) {
                numUpdates = numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[_idToAddr(i)];
                maxError += ErrorComputation.maxErrorBalanceSIR(balance, numUpdates);
            }
        }
    }
}

contract SystemStateInvariantTest is Test {
    SystemStateHandler private _systemStateHandler;

    function setUp() public {
        uint40 startTime = uint40(block.timestamp);
        if (startTime == 0) startTime = 1;

        _systemStateHandler = new SystemStateHandler(startTime);

        targetContract(address(_systemStateHandler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = _systemStateHandler.transfer.selector;
        selectors[1] = _systemStateHandler.mint.selector;
        selectors[2] = _systemStateHandler.burn.selector;
        selectors[3] = _systemStateHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(_systemStateHandler), selectors: selectors}));
    }

    function invariant_cumulativeSIR() public {
        uint256 totalSIR;
        uint40 startTime = _systemStateHandler.startTime();
        uint40 currentTime = _systemStateHandler.currentTime();
        vm.warp(currentTime);

        if (currentTime < startTime + SystemConstants.THREE_YEARS) {
            totalSIR =
                _systemStateHandler.issuanceFirst3Years() *
                (currentTime - startTime - _systemStateHandler.totalTimeWithoutIssuanceFirst3Years());
        } else {
            totalSIR =
                _systemStateHandler.issuanceFirst3Years() *
                (SystemConstants.THREE_YEARS - _systemStateHandler.totalTimeWithoutIssuanceFirst3Years()) +
                _systemStateHandler.issuanceAfter3Years() *
                (currentTime -
                    startTime -
                    SystemConstants.THREE_YEARS -
                    _systemStateHandler.totalTimeWithoutIssuanceAfter3Years());
        }

        uint256 claimedSIR = _systemStateHandler.totalClaimedSIR();
        uint256 unclaimedSIR = _systemStateHandler.totalUnclaimedSIR();

        assertLe(claimedSIR + unclaimedSIR, totalSIR, "Total SIR is too high");

        uint256 totalSIRMaxError = _systemStateHandler.totalSIRMaxError();
        assertGe(
            claimedSIR + unclaimedSIR,
            totalSIR > totalSIRMaxError ? totalSIR - totalSIRMaxError : 0,
            "Total SIR is too low"
        );
    }

    function invariant_vaultTeaBalance() public {
        SystemStateWrapper systemState = SystemStateWrapper(_systemStateHandler.systemState());
        uint256 vaultBalance = systemState.balanceOf(address(systemState), _systemStateHandler.VAULT_ID());
        assertGe(vaultBalance, _systemStateHandler.vaultBalanceOld());
    }
}
