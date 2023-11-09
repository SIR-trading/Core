// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {VaultExternal, Strings} from "src/VaultExternal.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SaltedAddress} from "src/libraries/SaltedAddress.sol";
import {IERC20} from "v2-core/interfaces/IERC20.sol";

contract VaultExternalTest is Test {
    VaultExternal vaultExternal;

    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId
    );

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        vaultExternal = new VaultExternal(address(this));
    }

    function test_deployETHvsUSDC() public {
        int8 leverageTier = -1;

        vm.expectEmit();
        emit VaultInitialized(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier, 1);
        vaultExternal.deployAPE(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier);

        address ape = SaltedAddress.getAddress(address(vaultExternal), 1);
        assertGt(ape.code.length, 0);

        assertEq(IERC20(ape).name(), "Tokenized WETH/USDC with x1.5 leverage");
        assertEq(IERC20(ape).symbol(), "APE-1");
        assertEq(IERC20(ape).decimals(), 18);

        (address debtToken, address collateralToken, int8 leverageTier_) = vaultExternal.paramsById(1);
        assertEq(debtToken, Addresses.ADDR_USDC);
        assertEq(collateralToken, Addresses.ADDR_WETH);
        assertEq(leverageTier, leverageTier_);
    }

    function testFuzz_deployETHvsUSDC(int8 leverageTier) public {
        leverageTier = int8(bound(leverageTier, -3, 2)); // Only accepted values in the system

        vm.expectEmit();
        emit VaultInitialized(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier, 1);
        vaultExternal.deployAPE(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier);

        address ape = SaltedAddress.getAddress(address(vaultExternal), 1);
        assertGt(ape.code.length, 0);

        assertEq(IERC20(ape).symbol(), string.concat("APE-1"));
        assertEq(IERC20(ape).decimals(), IERC20(Addresses.ADDR_WETH).decimals());

        (address debtToken, address collateralToken, int8 leverageTier_) = vaultExternal.paramsById(1);
        assertEq(debtToken, Addresses.ADDR_USDC);
        assertEq(collateralToken, Addresses.ADDR_WETH);
        assertEq(leverageTier, leverageTier_);
    }

    function testFuzz_deployETHvsUSDCWrongLeverage(int8 leverageTier) public {
        vm.assume(leverageTier < -3 || leverageTier > 2); // Non accepted values in the system

        vm.expectRevert();
        vaultExternal.deployAPE(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier);
    }

    function test_deploy10Vaults() public {
        int8 leverageTier = 0;

        for (uint256 vaultId = 1; vaultId <= 10; vaultId++) {
            vm.expectEmit();
            emit VaultInitialized(Addresses.ADDR_ALUSD, Addresses.ADDR_USDC, leverageTier, vaultId);
            vaultExternal.deployAPE(Addresses.ADDR_ALUSD, Addresses.ADDR_USDC, leverageTier);

            address ape = SaltedAddress.getAddress(address(vaultExternal), vaultId);
            assertGt(ape.code.length, 0);

            assertEq(IERC20(ape).symbol(), string.concat("APE-", Strings.toString(vaultId)));
            assertEq(IERC20(ape).decimals(), IERC20(Addresses.ADDR_USDC).decimals());

            (address debtToken, address collateralToken, int8 leverageTier_) = vaultExternal.paramsById(vaultId);
            assertEq(debtToken, Addresses.ADDR_ALUSD);
            assertEq(collateralToken, Addresses.ADDR_USDC);
            assertEq(leverageTier, leverageTier_);
        }
    }

    // TEST THE LIMIT ON THE NUMBER OF VAULTS
}
