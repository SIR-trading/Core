// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {SystemState} from "src/SystemState.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
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
            _systemParams.cumulativeTax,
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
            _systemParams.cumulativeTax,
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
            _systemParams.cumulativeTax,
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
            _systemParams.cumulativeTax,
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
            return
                cumulativeSIRPerTEA(
                    _systemParams.cumulativeTax,
                    vaultIssuanceParams[vaultId],
                    supplyExcludeVault(VAULT_ID)
                );
        return type(uint176).max / uint176(vaultId); // To make it somewhat arbitrary
    }
}

contract SystemStateTest is Test {
    uint48 constant VAULT_ID = 42;
    uint40 constant MAX_TS = 599 * 365 days; // See SystemState.sol comments for explanation
    SystemStateWrapper systemState;
    SirStructs.SystemParameters systemParams0;
    SirStructs.SystemParameters systemParams_;

    uint40 timestampStart;

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
    ) private returns (uint256 durationBefore3Years, uint256 durationAfter3Years, uint176 cumulativeSIRPerTEAx96) {
        if (tsUpdateTax < tsMint) {
            if (checkFirst3Years) {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsMint, timestampStart + SystemConstants.THREE_YEARS));
                durationBefore3Years = tsCheckRewards - tsMint;
            } else if (tsMint > timestampStart + SystemConstants.THREE_YEARS) {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsMint, MAX_TS));
                durationAfter3Years = tsCheckRewards - tsMint;
            } else {
                tsCheckRewards = uint40(_bound(tsCheckRewards, timestampStart + SystemConstants.THREE_YEARS, MAX_TS));
                durationBefore3Years = timestampStart + SystemConstants.THREE_YEARS - tsMint;
                durationAfter3Years = tsCheckRewards - (timestampStart + SystemConstants.THREE_YEARS);
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
                tsCheckRewards = uint40(
                    _bound(tsCheckRewards, tsUpdateTax, timestampStart + SystemConstants.THREE_YEARS)
                );
                durationBefore3Years = tsCheckRewards - tsUpdateTax;
            } else if (tsUpdateTax > timestampStart + SystemConstants.THREE_YEARS) {
                tsCheckRewards = uint40(_bound(tsCheckRewards, tsUpdateTax, MAX_TS));
                durationAfter3Years = tsCheckRewards - tsUpdateTax;
            } else {
                tsCheckRewards = uint40(_bound(tsCheckRewards, timestampStart + SystemConstants.THREE_YEARS, MAX_TS));
                durationBefore3Years = timestampStart + SystemConstants.THREE_YEARS - tsUpdateTax;
                durationAfter3Years = tsCheckRewards - (timestampStart + SystemConstants.THREE_YEARS);
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
        cumulativeSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);
    }

    function setUp() public {
        systemControl = vm.addr(1);
        sir = vm.addr(2);

        alice = vm.addr(4);
        bob = vm.addr(5);

        systemState = new SystemStateWrapper(systemControl, sir);
        timestampStart = uint40(block.timestamp);

        systemParams0 = systemState.systemParams();
    }

    function testFuzz_noMint(uint40 tsUpdateTax, uint40 tsCheckRewards) public {
        tsUpdateTax = uint40(_bound(tsUpdateTax, 0, MAX_TS));
        tsCheckRewards = uint40(_bound(tsCheckRewards, tsUpdateTax, MAX_TS));

        // Activate tax
        vm.warp(tsUpdateTax);
        _activateTax();

        // Get cumulative SIR per TEA
        vm.warp(tsUpdateTax);
        uint176 cumulativeSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumulativeSIRPerTEAx96, 0);
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
        uint176 cumulativeSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        assertEq(cumulativeSIRPerTEAx96, 0);
    }

    function testFuzz_mintAndCheckFirst3Years(
        uint40 tsUpdateTax,
        uint40 tsMint,
        uint40 tsCheckRewards,
        uint256 teaAmount,
        uint256 teaAmountPOL
    ) public {
        // Tax and mint before the 3 years have passed
        tsUpdateTax = uint40(_bound(tsUpdateTax, timestampStart, timestampStart + SystemConstants.THREE_YEARS));
        tsMint = uint40(_bound(tsMint, timestampStart, timestampStart + SystemConstants.THREE_YEARS));

        teaAmount = _bound(teaAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmount);

        (uint256 duration, , uint176 cumulativeSIRPerTEAx96) = _updateTaxMintAndCheckRewards(
            tsUpdateTax,
            tsMint,
            tsCheckRewards,
            true,
            teaAmount,
            teaAmountPOL
        );

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumulativeSIRPerTEAx96,
            ((SystemConstants.LP_ISSUANCE_FIRST_3_YEARS * duration) << 96) / teaAmount,
            ErrorComputation.maxErrorCumumlative(1)
        );

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = SystemConstants.LP_ISSUANCE_FIRST_3_YEARS * duration;

        assertLe(unclaimedSIR, unclaimedSIRTheoretical);
        assertApproxEqAbs(unclaimedSIR, unclaimedSIRTheoretical, ErrorComputation.maxErrorBalance(96, teaAmount, 1));

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
        tsUpdateTax = uint40(_bound(tsUpdateTax, timestampStart + SystemConstants.THREE_YEARS, MAX_TS));
        tsMint = uint40(_bound(tsMint, timestampStart + SystemConstants.THREE_YEARS, MAX_TS));

        teaAmount = _bound(teaAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmount);

        (, uint256 duration, uint176 cumulativeSIRPerTEAx96) = _updateTaxMintAndCheckRewards(
            tsUpdateTax,
            tsMint,
            tsCheckRewards,
            false,
            teaAmount,
            teaAmountPOL
        );

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumulativeSIRPerTEAx96,
            ((SystemConstants.ISSUANCE * duration) << 96) / teaAmount,
            ErrorComputation.maxErrorCumumlative(1)
        );

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = SystemConstants.ISSUANCE * duration;

        assertLe(unclaimedSIR, unclaimedSIRTheoretical);
        assertApproxEqAbs(unclaimedSIR, unclaimedSIRTheoretical, ErrorComputation.maxErrorBalance(96, teaAmount, 1));

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
        tsUpdateTax = uint40(_bound(tsUpdateTax, timestampStart, timestampStart + SystemConstants.THREE_YEARS));
        tsMint = uint40(_bound(tsMint, timestampStart, timestampStart + SystemConstants.THREE_YEARS));

        teaAmount = _bound(teaAmount, 1, SystemConstants.TEA_MAX_SUPPLY);
        teaAmountPOL = _bound(teaAmountPOL, 0, SystemConstants.TEA_MAX_SUPPLY - teaAmount);

        (
            uint256 durationBefore3Years,
            uint256 durationAfter3Years,
            uint176 cumulativeSIRPerTEAx96
        ) = _updateTaxMintAndCheckRewards(tsUpdateTax, tsMint, tsCheckRewards, false, teaAmount, teaAmountPOL);

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumulativeSIRPerTEAx96,
            ((SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
                durationBefore3Years +
                SystemConstants.ISSUANCE *
                durationAfter3Years) << 96) / teaAmount,
            ErrorComputation.maxErrorCumumlative(2)
        );

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
            durationBefore3Years +
            SystemConstants.ISSUANCE *
            durationAfter3Years;

        assertLe(unclaimedSIR, unclaimedSIRTheoretical);
        assertApproxEqAbs(unclaimedSIR, unclaimedSIRTheoretical, ErrorComputation.maxErrorBalance(96, teaAmount, 2));

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
        vm.warp(timestampStart);
        _activateTax();

        // Mint TEA for Alice
        systemState.mint(alice, teaAmount, teaAmountPOL);

        // Burn TEA from Alice
        vm.warp(timestampStart + 2 * SystemConstants.THREE_YEARS);
        systemState.burn(alice, teaAmount, teaAmountPOL2);

        // Mint TEA for Bob
        systemState.mint(bob, teaAmount, teaAmountPOL);

        vm.warp(1 + 4 * SystemConstants.THREE_YEARS);

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = uint256(
            SystemConstants.LP_ISSUANCE_FIRST_3_YEARS + SystemConstants.ISSUANCE
        ) * SystemConstants.THREE_YEARS;

        assertLe(unclaimedSIR, unclaimedSIRTheoretical);
        assertApproxEqAbs(unclaimedSIR, unclaimedSIRTheoretical, ErrorComputation.maxErrorBalance(96, teaAmount, 2));

        // Check rewards for Bob
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, bob);
        unclaimedSIRTheoretical = uint256(2) * SystemConstants.ISSUANCE * SystemConstants.THREE_YEARS;

        assertLe(unclaimedSIR, unclaimedSIRTheoretical);
        assertApproxEqAbs(unclaimedSIR, unclaimedSIRTheoretical, ErrorComputation.maxErrorBalance(96, teaAmount, 3));

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
        tsMint = uint40(_bound(tsMint, timestampStart, MAX_TS));
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
        uint176 cumulativeSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        uint256 durationBeforeBurnBefore3Years;
        uint256 durationBeforeBurnAfter3Years;
        if (
            tsMint < timestampStart + SystemConstants.THREE_YEARS &&
            tsBurn < timestampStart + SystemConstants.THREE_YEARS
        ) {
            durationBeforeBurnBefore3Years = tsBurn - tsMint;
        } else if (tsMint >= timestampStart + SystemConstants.THREE_YEARS) {
            durationBeforeBurnAfter3Years = tsBurn - tsMint;
        } else {
            durationBeforeBurnBefore3Years = timestampStart + SystemConstants.THREE_YEARS - tsMint;
            durationBeforeBurnAfter3Years = tsBurn - (timestampStart + SystemConstants.THREE_YEARS);
        }

        uint256 durationAfterBurnBefore3Years;
        uint256 durationAfterBurnAfter3Years;
        if (
            tsBurn < timestampStart + SystemConstants.THREE_YEARS &&
            tsCheckRewards < timestampStart + SystemConstants.THREE_YEARS
        ) {
            durationAfterBurnBefore3Years = tsCheckRewards - tsBurn;
        } else if (tsBurn >= timestampStart + SystemConstants.THREE_YEARS) {
            durationAfterBurnAfter3Years = tsCheckRewards - tsBurn;
        } else {
            durationAfterBurnBefore3Years = timestampStart + SystemConstants.THREE_YEARS - tsBurn;
            durationAfterBurnAfter3Years = tsCheckRewards - (timestampStart + SystemConstants.THREE_YEARS);
        }

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumulativeSIRPerTEAx96,
            ((SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
                durationBeforeBurnBefore3Years +
                SystemConstants.ISSUANCE *
                durationBeforeBurnAfter3Years) << 96) / teaAmount,
            ErrorComputation.maxErrorCumumlative(3)
        );

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
            durationBeforeBurnBefore3Years +
            SystemConstants.ISSUANCE *
            durationBeforeBurnAfter3Years;

        assertLe(unclaimedSIR, unclaimedSIRTheoretical);
        assertApproxEqAbs(unclaimedSIR, unclaimedSIRTheoretical, ErrorComputation.maxErrorBalance(96, teaAmount, 3));

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
        tsMint = uint40(_bound(tsMint, timestampStart, MAX_TS));
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
        uint176 cumulativeSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        uint256 durationBeforeBurnBefore3Years;
        uint256 durationBeforeBurnAfter3Years;
        if (
            tsMint < timestampStart + SystemConstants.THREE_YEARS &&
            tsBurn < timestampStart + SystemConstants.THREE_YEARS
        ) {
            durationBeforeBurnBefore3Years = tsBurn - tsMint;
        } else if (tsMint >= timestampStart + SystemConstants.THREE_YEARS) {
            durationBeforeBurnAfter3Years = tsBurn - tsMint;
        } else {
            durationBeforeBurnBefore3Years = timestampStart + SystemConstants.THREE_YEARS - tsMint;
            durationBeforeBurnAfter3Years = tsBurn - (timestampStart + SystemConstants.THREE_YEARS);
        }

        uint144 unclaimedSIR;
        uint256 unclaimedSIRTheoretical;
        uint256 teaAmountAfterBurn = teaAmount - teaAmountToBurn;
        {
            // To avoid deep stack error
            uint256 durationAfterBurnBefore3Years;
            uint256 durationAfterBurnAfter3Years;
            if (
                tsBurn < timestampStart + SystemConstants.THREE_YEARS &&
                tsCheckRewards < timestampStart + SystemConstants.THREE_YEARS
            ) {
                durationAfterBurnBefore3Years = tsCheckRewards - tsBurn;
            } else if (tsBurn >= timestampStart + SystemConstants.THREE_YEARS) {
                durationAfterBurnAfter3Years = tsCheckRewards - tsBurn;
            } else {
                durationAfterBurnBefore3Years = timestampStart + SystemConstants.THREE_YEARS - tsBurn;
                durationAfterBurnAfter3Years = tsCheckRewards - (timestampStart + SystemConstants.THREE_YEARS);
            }

            // Check cumulative SIR per TEA
            assertApproxEqAbs(
                cumulativeSIRPerTEAx96,
                ((SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
                    durationBeforeBurnBefore3Years +
                    SystemConstants.ISSUANCE *
                    durationBeforeBurnAfter3Years) << 96) /
                    teaAmount +
                    ((SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
                        durationAfterBurnBefore3Years +
                        SystemConstants.ISSUANCE *
                        durationAfterBurnAfter3Years) << 96) /
                    teaAmountAfterBurn,
                ErrorComputation.maxErrorCumumlative(3)
            );

            // Check rewards for Alice
            unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
            unclaimedSIRTheoretical =
                SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
                (durationBeforeBurnBefore3Years + durationAfterBurnBefore3Years) +
                SystemConstants.ISSUANCE *
                (durationBeforeBurnAfter3Years + durationAfterBurnAfter3Years);
        }

        assertLe(unclaimedSIR, unclaimedSIRTheoretical);
        assertApproxEqAbs(
            unclaimedSIR,
            unclaimedSIRTheoretical,
            ErrorComputation.maxErrorBalance(96, teaAmount, 2) +
                ErrorComputation.maxErrorBalance(96, teaAmountAfterBurn, 2)
        );

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
        tsMint = uint40(_bound(tsMint, timestampStart, MAX_TS));
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
        uint176 cumulativeSIRPerTEAx96 = systemState.cumulativeSIRPerTEA(VAULT_ID);

        uint256 durationAliceBefore3Years;
        uint256 durationAliceAfter3Years;
        if (
            tsMint < timestampStart + SystemConstants.THREE_YEARS &&
            tsTransfer < timestampStart + SystemConstants.THREE_YEARS
        ) {
            durationAliceBefore3Years = tsTransfer - tsMint;
        } else if (tsMint >= timestampStart + SystemConstants.THREE_YEARS) {
            durationAliceAfter3Years = tsTransfer - tsMint;
        } else {
            durationAliceBefore3Years = timestampStart + SystemConstants.THREE_YEARS - tsMint;
            durationAliceAfter3Years = tsTransfer - (timestampStart + SystemConstants.THREE_YEARS);
        }

        uint256 durationBobBefore3Years;
        uint256 durationBobAfter3Years;
        if (
            tsTransfer < timestampStart + SystemConstants.THREE_YEARS &&
            tsCheckRewards < timestampStart + SystemConstants.THREE_YEARS
        ) {
            durationBobBefore3Years = tsCheckRewards - tsTransfer;
        } else if (tsTransfer >= timestampStart + SystemConstants.THREE_YEARS) {
            durationBobAfter3Years = tsCheckRewards - tsTransfer;
        } else {
            durationBobBefore3Years = timestampStart + SystemConstants.THREE_YEARS - tsTransfer;
            durationBobAfter3Years = tsCheckRewards - (timestampStart + SystemConstants.THREE_YEARS);
        }

        // Check cumulative SIR per TEA
        assertApproxEqAbs(
            cumulativeSIRPerTEAx96,
            ((SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
                (durationAliceBefore3Years + durationBobBefore3Years) +
                SystemConstants.ISSUANCE *
                (durationAliceAfter3Years + durationBobAfter3Years)) << 96) / teaAmountMint,
            ErrorComputation.maxErrorCumumlative(3)
        );

        // Check rewards for Alice
        uint144 unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, alice);
        uint256 unclaimedSIRTheoretical = (SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
            durationAliceBefore3Years +
            SystemConstants.ISSUANCE *
            durationAliceAfter3Years) +
            ((SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
                durationBobBefore3Years +
                SystemConstants.ISSUANCE *
                durationBobAfter3Years) * (teaAmountMint - teaAmountTransfer)) /
            teaAmountMint;

        assertLe(unclaimedSIR, unclaimedSIRTheoretical);
        assertApproxEqAbs(
            unclaimedSIR,
            unclaimedSIRTheoretical,
            ErrorComputation.maxErrorBalance(96, teaAmountMint, 2) +
                ErrorComputation.maxErrorBalance(96, teaAmountMint - teaAmountTransfer, 2)
        );

        // Check rewards for Bob
        unclaimedSIR = systemState.unclaimedRewards(VAULT_ID, bob);
        unclaimedSIRTheoretical =
            ((SystemConstants.LP_ISSUANCE_FIRST_3_YEARS *
                durationBobBefore3Years +
                SystemConstants.ISSUANCE *
                durationBobAfter3Years) * teaAmountTransfer) /
            teaAmountMint;

        assertLe(unclaimedSIR, unclaimedSIRTheoretical);
        assertApproxEqAbs(
            unclaimedSIR,
            unclaimedSIRTheoretical,
            ErrorComputation.maxErrorBalance(96, teaAmountTransfer, 3)
        );
    }

    function testFuzz_claimSIR(uint40 tsMint, uint40 tsCheckRewards, uint256 teaAmount, uint256 teaAmountPOL) public {
        // Adjust timestamps
        tsMint = uint40(_bound(tsMint, timestampStart, MAX_TS));
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
        if (
            tsMint < timestampStart + SystemConstants.THREE_YEARS &&
            tsCheckRewards < timestampStart + SystemConstants.THREE_YEARS
        ) {
            durationBefore3Years = tsCheckRewards - tsMint;
        } else if (tsMint >= timestampStart + SystemConstants.THREE_YEARS) {
            durationAfter3Years = tsCheckRewards - tsMint;
        } else {
            durationBefore3Years = timestampStart + SystemConstants.THREE_YEARS - tsMint;
            durationAfter3Years = tsCheckRewards - (timestampStart + SystemConstants.THREE_YEARS);
        }

        uint256 unclaimedSIRAliceTheoretical = (durationBefore3Years *
            SystemConstants.LP_ISSUANCE_FIRST_3_YEARS +
            durationAfter3Years *
            SystemConstants.ISSUANCE);

        assertLe(unclaimedSIRAlice, unclaimedSIRAliceTheoretical);
        assertApproxEqAbs(
            unclaimedSIRAlice,
            unclaimedSIRAliceTheoretical,
            ErrorComputation.maxErrorBalance(96, teaAmount, 2)
        );

        assertEq(systemState.unclaimedRewards(VAULT_ID, alice), 0);
    }

    function testFuzz_claimSIRFailsCuzNotSir(
        uint40 tsMint,
        uint40 tsCheckRewards,
        uint256 teaAmount,
        uint256 teaAmountPOL
    ) public {
        // Adjust timestamps
        tsMint = uint40(_bound(tsMint, timestampStart, MAX_TS));
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

    function testFuzz_updateBaseFee(uint16 baseFee, uint16 lpFee, bool mintingStopped, uint40 delay) public {
        vm.assume(baseFee != 0);
        delay = uint40(_bound(delay, SystemConstants.FEE_CHANGE_DELAY, type(uint40).max - timestampStart));

        systemParams_ = systemState.systemParams();

        // Update system vaultState
        vm.prank(systemControl);
        systemState.updateSystemState(baseFee, lpFee, mintingStopped);

        systemParams_ = systemState.systemParams();

        // Skip delay
        skip(delay);

        // Check system vaultState
        systemParams_ = systemState.systemParams();

        assertEq(systemParams_.baseFee.fee, baseFee); // Only base fee is updated
        assertEq(systemParams_.lpFee.fee, systemParams0.lpFee.fee);
        assertEq(systemParams_.mintingStopped, systemParams0.mintingStopped);
        assertEq(systemParams_.cumulativeTax, systemParams0.cumulativeTax);
    }

    function testFuzz_updateBaseFeeCheckTooEarly(
        uint16 baseFee,
        uint16 lpFee,
        bool mintingStopped,
        uint40 delay
    ) public {
        vm.assume(baseFee != 0);
        delay = uint40(_bound(delay, 0, SystemConstants.FEE_CHANGE_DELAY - 1));

        // Update system vaultState
        vm.prank(systemControl);
        systemState.updateSystemState(baseFee, lpFee, mintingStopped);

        // Skip delay
        skip(delay);

        // Check system vaultState
        systemParams_ = systemState.systemParams();

        // Nothing changed
        assertEq(systemParams_.baseFee.fee, systemParams0.baseFee.fee);
        assertEq(systemParams_.lpFee.fee, systemParams0.lpFee.fee);
        assertEq(systemParams_.mintingStopped, systemParams0.mintingStopped);
        assertEq(systemParams_.cumulativeTax, systemParams0.cumulativeTax);
    }

    function testFuzz_updateBaseFeeTwice(
        uint16 baseFee1,
        uint16 lpFee1,
        bool mintingStopped1,
        uint40 delay1,
        uint16 baseFee2,
        uint16 lpFee2,
        bool mintingStopped2,
        uint40 delay2
    ) public {
        vm.assume(baseFee1 != 0);
        vm.assume(baseFee2 != 0);
        delay1 = uint40(_bound(delay1, 0, type(uint40).max - timestampStart));
        delay2 = uint40(_bound(delay2, 0, type(uint40).max - timestampStart - delay1));

        if (delay1 < SystemConstants.FEE_CHANGE_DELAY)
            testFuzz_updateBaseFeeCheckTooEarly(baseFee1, lpFee1, mintingStopped1, delay1);
        else testFuzz_updateBaseFee(baseFee1, lpFee1, mintingStopped1, delay1);

        // Update system vaultState
        vm.prank(systemControl);
        systemState.updateSystemState(baseFee2, lpFee2, mintingStopped2);

        // Skip delay
        skip(delay2);

        // Check system vaultState
        console.log("here");
        systemParams_ = systemState.systemParams();
        console.log("there");

        assertEq(
            systemParams_.baseFee.fee,
            delay2 <= SystemConstants.FEE_CHANGE_DELAY
                ? (delay1 <= SystemConstants.FEE_CHANGE_DELAY ? systemParams0.baseFee.fee : baseFee1)
                : baseFee2
        ); // Only base fee is updated
        assertEq(systemParams_.lpFee.fee, systemParams0.lpFee.fee);
        assertEq(systemParams_.mintingStopped, systemParams0.mintingStopped);
        assertEq(systemParams_.cumulativeTax, systemParams0.cumulativeTax);
    }

    function testFuzz_updateLpFee(uint16 lpFee, bool mintingStopped, uint40 delay) public {
        vm.assume(lpFee != 0);
        delay = uint40(_bound(delay, SystemConstants.FEE_CHANGE_DELAY, type(uint40).max - timestampStart));

        // Update system vaultState
        vm.prank(systemControl);
        systemState.updateSystemState(0, lpFee, mintingStopped);

        // Skip delay
        skip(delay);

        // Check system vaultState
        systemParams_ = systemState.systemParams();

        assertEq(systemParams_.baseFee.fee, systemParams0.baseFee.fee);
        assertEq(systemParams_.lpFee.fee, lpFee); // Only LP fee is updated
        assertEq(systemParams_.mintingStopped, systemParams0.mintingStopped);
        assertEq(systemParams_.cumulativeTax, systemParams0.cumulativeTax);
    }

    function testFuzz_updateLpFeeCheckTooEarly(uint16 lpFee, bool mintingStopped, uint40 delay) public {
        vm.assume(lpFee != 0);
        delay = uint40(_bound(delay, 0, SystemConstants.FEE_CHANGE_DELAY - 1));

        // Update system vaultState
        vm.prank(systemControl);
        systemState.updateSystemState(0, lpFee, mintingStopped);

        // Skip delay
        skip(delay);

        // Check system vaultState
        systemParams_ = systemState.systemParams();

        // Nothing changed
        assertEq(systemParams_.baseFee.fee, systemParams0.baseFee.fee);
        assertEq(systemParams_.lpFee.fee, systemParams0.lpFee.fee);
        assertEq(systemParams_.mintingStopped, systemParams0.mintingStopped);
        assertEq(systemParams_.cumulativeTax, systemParams0.cumulativeTax);
    }

    function testFuzz_updateLpFeeTwice(
        uint16 lpFee1,
        bool mintingStopped1,
        uint40 delay1,
        uint16 lpFee2,
        bool mintingStopped2,
        uint40 delay2
    ) public {
        vm.assume(lpFee1 != 0);
        vm.assume(lpFee2 != 0);
        delay1 = uint40(_bound(delay1, 0, type(uint40).max - timestampStart));
        delay2 = uint40(_bound(delay2, 0, type(uint40).max - timestampStart - delay1));
        if (delay1 < SystemConstants.FEE_CHANGE_DELAY)
            testFuzz_updateLpFeeCheckTooEarly(lpFee1, mintingStopped1, delay1);
        else testFuzz_updateLpFee(lpFee1, mintingStopped1, delay1);

        // Update system vaultState
        vm.prank(systemControl);
        systemState.updateSystemState(0, lpFee2, mintingStopped2);

        // Skip delay
        skip(delay2);

        // Check system vaultState
        systemParams_ = systemState.systemParams();

        assertEq(systemParams_.baseFee.fee, systemParams0.baseFee.fee);
        assertEq(
            systemParams_.lpFee.fee,
            delay2 <= SystemConstants.FEE_CHANGE_DELAY
                ? (delay1 <= SystemConstants.FEE_CHANGE_DELAY ? systemParams0.lpFee.fee : lpFee1)
                : lpFee2
        ); // Only LP fee is updated
        assertEq(systemParams_.mintingStopped, systemParams0.mintingStopped);
        assertEq(systemParams_.cumulativeTax, systemParams0.cumulativeTax);
    }

    function testFuzz_updateMintingStopped(bool mintingStopped) public {
        // Update system vaultState
        vm.prank(systemControl);
        systemState.updateSystemState(0, 0, mintingStopped);

        // Check system vaultState
        systemParams_ = systemState.systemParams();

        assertEq(systemParams_.baseFee.fee, systemParams0.baseFee.fee);
        assertEq(systemParams_.lpFee.fee, systemParams0.lpFee.fee);
        assertEq(systemParams_.mintingStopped, mintingStopped); // Only mintingStopped is updatedsystem
        assertEq(systemParams_.cumulativeTax, systemParams0.cumulativeTax);
    }

    function testFuzz_updateSystem(uint16 baseFee, uint16 lpFee, bool mintingStopped, uint16 numVaults) public {
        vm.assume(baseFee != 0);
        vm.assume(lpFee != 0);
        numVaults = uint16(_bound(numVaults, 0, uint16(type(uint8).max) ** 2));

        // Random fake variables
        uint256 rndVal = uint256(keccak256(abi.encodePacked(baseFee, lpFee, mintingStopped, numVaults)));
        uint16 lpFeeFake = uint16(rndVal >> 16);
        bool mintingStoppedFake = (rndVal >> 32) % 2 == 0;

        // Update system state
        vm.startPrank(systemControl);
        systemState.updateSystemState(baseFee, lpFeeFake, mintingStoppedFake);
        systemState.updateSystemState(0, lpFee, mintingStoppedFake);
        systemState.updateSystemState(0, 0, mintingStopped);
        vm.stopPrank();

        // Skip delay to apply the new fees
        skip(SystemConstants.FEE_CHANGE_DELAY);

        // Update vaults with the minimum tax (1)
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
        systemParams_ = systemState.systemParams();

        assertEq(systemParams_.baseFee.fee, baseFee);
        assertEq(systemParams_.lpFee.fee, lpFee);
        assertEq(systemParams_.mintingStopped, mintingStopped);
        assertEq(systemParams_.cumulativeTax, numVaults);

        // New update, only 1 vault with max tax
        uint48[] memory veryNewVaults = new uint48[](1);
        uint8[] memory veryNewTaxes = new uint8[](1);
        veryNewVaults[0] = 1;
        veryNewTaxes[0] = type(uint8).max;
        vm.prank(systemControl);
        systemState.updateVaults(newVaults, veryNewVaults, veryNewTaxes, type(uint8).max);

        // Check system vaultState
        systemParams_ = systemState.systemParams();

        assertEq(systemParams_.baseFee.fee, baseFee);
        assertEq(systemParams_.lpFee.fee, lpFee);
        assertEq(systemParams_.mintingStopped, mintingStopped);
        assertEq(systemParams_.cumulativeTax, type(uint8).max);
    }

    function testFuzz_updateSystemStateNotSystemControl(uint16 baseFee, uint16 lpFee, bool mintingStopped) public {
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
        if (systemState.totalSupply(VAULT_ID) - systemState.balanceOf(address(systemState), VAULT_ID) == 0) {
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
        _totalSIRMaxError += ErrorComputation.maxErrorBalance(96, preBalance, numUpdates);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[toAddr];
        uint256 toBalance = systemState.balanceOf(toAddr, VAULT_ID);
        _totalSIRMaxError += ErrorComputation.maxErrorBalance(96, toBalance, numUpdates);

        // Update indexes
        _numUpdatesCumSIRPerTEAForUser[fromAddr] = _numUpdatesCumSIRPerTEA;
        _numUpdatesCumSIRPerTEAForUser[toAddr] = _numUpdatesCumSIRPerTEA;
    }

    function mint(
        uint256 user,
        uint256 amount,
        uint256 amountToProtocol,
        uint24 timeSkip
    ) external advanceTime(timeSkip) {
        address addr = _idToAddr(user);

        uint256 preBalance = systemState.balanceOf(addr, VAULT_ID);
        uint256 vaultPreBalance = systemState.balanceOf(address(systemState), VAULT_ID);

        uint256 totalSupply = systemState.totalSupply(VAULT_ID);
        amount = _bound(amount, 0, SystemConstants.TEA_MAX_SUPPLY - totalSupply);
        amountToProtocol = _bound(amountToProtocol, 0, SystemConstants.TEA_MAX_SUPPLY - totalSupply - amount);

        systemState.mint(addr, amount, amountToProtocol);

        // Vault's cumulative SIR per TEA is updated
        _updateCumSIRPerTEA();

        // Update totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[addr];
        _totalSIRMaxError += ErrorComputation.maxErrorBalance(96, preBalance, numUpdates);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[address(systemState)];
        _totalSIRMaxError += ErrorComputation.maxErrorBalance(96, vaultPreBalance, numUpdates);

        // Update index
        _numUpdatesCumSIRPerTEAForUser[addr] = _numUpdatesCumSIRPerTEA;
        _numUpdatesCumSIRPerTEAForUser[address(systemState)] = _numUpdatesCumSIRPerTEA;
    }

    function burn(
        uint256 user,
        uint256 amount,
        uint256 amountToProtocol,
        uint24 timeSkip
    ) external advanceTime(timeSkip) {
        address addr = _idToAddr(user);
        uint256 preBalance = systemState.balanceOf(addr, VAULT_ID);
        amount = _bound(amount, 0, preBalance);
        uint256 vaultPreBalance = systemState.balanceOf(address(systemState), VAULT_ID);
        amountToProtocol = _bound(amountToProtocol, 0, amount);

        systemState.burn(addr, amount, amountToProtocol);

        // Vault's cumulative SIR per TEA is updated
        _updateCumSIRPerTEA();

        // Update totalSIRMaxError
        uint256 numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[addr];
        _totalSIRMaxError += ErrorComputation.maxErrorBalance(96, preBalance, numUpdates);
        numUpdates = _numUpdatesCumSIRPerTEA - _numUpdatesCumSIRPerTEAForUser[address(systemState)];
        _totalSIRMaxError += ErrorComputation.maxErrorBalance(96, vaultPreBalance, numUpdates);

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
        _totalSIRMaxError += ErrorComputation.maxErrorBalance(96, balance, numUpdates);

        // Update index
        _numUpdatesCumSIRPerTEAForUser[addr] = _numUpdatesCumSIRPerTEA;
    }

    function issuanceFirst3Years() external pure returns (uint256) {
        return SystemConstants.LP_ISSUANCE_FIRST_3_YEARS;
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
                maxError += ErrorComputation.maxErrorBalance(96, balance, numUpdates);
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
            // console.log(
            //     "currentTime - startTime - _systemStateHandler.totalTimeWithoutIssuanceFirst3Years()",
            //     currentTime - startTime - _systemStateHandler.totalTimeWithoutIssuanceFirst3Years()
            // );
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
        assertApproxEqAbs(claimedSIR + unclaimedSIR, totalSIR, totalSIRMaxError, "Total SIR is too low");
    }

    function invariant_vaultTeaBalance() public view {
        SystemStateWrapper systemState = SystemStateWrapper(_systemStateHandler.systemState());
        uint256 vaultBalance = systemState.balanceOf(address(systemState), _systemStateHandler.VAULT_ID());
        assertGe(vaultBalance, _systemStateHandler.vaultBalanceOld());
    }
}
