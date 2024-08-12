// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Vault} from "src/Vault.sol";
import {APE} from "src/APE.sol";
import {Oracle} from "src/Oracle.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SaltedAddress} from "src/libraries/SaltedAddress.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";

import "forge-std/Test.sol";

/// cli: forge test --mc VaultGasTest --gas-report
contract VaultGasTest is Test, ERC1155TokenReceiver {
    uint256 public constant TIME_ADVANCE = 1 days;
    uint256 public constant BLOCK_NUMBER_START = 18128102;

    IWETH9 private constant WETH = IWETH9(Addresses.ADDR_WETH);
    Vault public vault;
    APE public ape;

    SirStructs.VaultParameters public vaultParameters =
        SirStructs.VaultParameters({
            debtToken: Addresses.ADDR_USDT,
            collateralToken: address(WETH),
            leverageTier: int8(-1)
        });

    function setUp() public {
        vm.createSelectFork("mainnet", BLOCK_NUMBER_START);

        // vm.writeFile("./gains.log", "");

        Oracle oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);
        vault = new Vault(vm.addr(100), vm.addr(101), address(oracle));

        // Set tax between 2 vaults
        {
            uint48[] memory oldVaults = new uint48[](0);
            uint48[] memory newVaults = new uint48[](2);
            newVaults[0] = 1;
            newVaults[1] = 2;
            uint8[] memory newTaxes = new uint8[](2);
            newTaxes[0] = 228;
            newTaxes[1] = 114; // Ensure 114^2+228^2 <= (2^8-1)^2
            vm.prank(vm.addr(100));
            vault.updateVaults(oldVaults, newVaults, newTaxes, 342);
        }

        ape = APE(SaltedAddress.getAddress(address(vault), 1));
    }

    function _depositWETH(uint256 amount) private {
        // Deal ETH
        vm.deal(address(this), amount);

        // Wrap ETH to WETH
        WETH.deposit{value: amount}();

        // Deposit WETH to vault
        WETH.transfer(address(vault), amount);
    }

    ///////////////////////////////////////////////

    /// @dev Around 205,457 gas
    function test_DoNotProbeFeeTier() public {
        // To make sure mint() is done exactly at the same time than other tests
        skip(TIME_ADVANCE);

        // Intialize vault
        vault.initialize(vaultParameters);

        // Deposit WETH to vault
        _depositWETH(2 ether);

        // Mint some APE
        vault.mint(true, vaultParameters);

        // Deposit WETH to vault
        _depositWETH(2 ether);

        // Mint some TEA
        vault.mint(false, vaultParameters);

        // Burn some APE
        vault.burn(true, vaultParameters, ape.balanceOf(address(this)));

        // Burn some TEA
        vault.burn(false, vaultParameters, vault.balanceOf(address(this), 1));
    }

    /// @dev Around 232,642 gas
    function test_ProbeFeeTier() public {
        // Intialize vault
        vault.initialize(vaultParameters);

        // Skip
        skip(TIME_ADVANCE);

        // Deposit WETH to vault
        _depositWETH(2 ether);

        // Mint some APE
        vault.mint(true, vaultParameters);

        // Deposit WETH to vault
        _depositWETH(2 ether);

        // Mint some TEA
        vault.mint(false, vaultParameters);

        // Burn some APE
        vault.burn(true, vaultParameters, ape.balanceOf(address(this)));

        // Burn some TEA
        vault.burn(false, vaultParameters, vault.balanceOf(address(this), 1));
    }
}
