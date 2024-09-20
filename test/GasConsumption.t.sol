// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Vault} from "src/Vault.sol";
import {APE} from "src/APE.sol";
import {Oracle} from "src/Oracle.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {AddressClone} from "src/libraries/AddressClone.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";

import "forge-std/Test.sol";

contract GasConsumption is Test, ERC1155TokenReceiver {
    uint256 public constant TIME_ADVANCE = 1 days;
    uint256 public constant BLOCK_NUMBER_START = 18128102;

    IWETH9 private constant WETH = IWETH9(Addresses.ADDR_WETH);
    Vault public vault;
    APE public ape;

    /**            |        |        |        |         |
|------------------------------|-----------------|--------|--------|--------|---------|
| Deployment Cost              | Deployment Size |        |        |        |         |
| 5190362                      | 24315           |        |        |        |         |
| Function Name                | min             | avg    | median | max    | # calls |
| balanceOf                    | 706             | 706    | 706    | 706    | 4       |
| burn                         | 104994          | 112811 | 112687 | 120875 | 8       |
| initialize                   | 477563          | 542517 | 542493 | 607519 | 4       |
| mint                         | 125018          | 168506 | 164413 | 227885 | 8       |
| updateVaults                 | 85430           | 85430  | 85430  | 85430  | 4       |
     */

    // WETH/USDT's Uniswap TWAP has a long cardinality
    SirStructs.VaultParameters public vaultParameters1 =
        SirStructs.VaultParameters({
            debtToken: Addresses.ADDR_USDT,
            collateralToken: address(WETH),
            leverageTier: int8(-1)
        });

    // BNB/WETH's Uniswap TWAP is of cardinality 1
    SirStructs.VaultParameters public vaultParameters2 =
        SirStructs.VaultParameters({
            debtToken: Addresses.ADDR_BNB,
            collateralToken: address(WETH),
            leverageTier: int8(0)
        });

    function setUp() public {
        vm.createSelectFork("mainnet", BLOCK_NUMBER_START);

        // vm.writeFile("./gains.log", "");

        ape = new APE();

        Oracle oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);
        vault = new Vault(vm.addr(100), vm.addr(101), address(oracle), address(ape));

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

        ape = APE(AddressClone.getAddress(address(vault), 1));
    }

    function _prepareWETH(uint256 amount) private {
        // Deal ETH
        vm.deal(address(this), amount);

        // Wrap ETH to WETH
        WETH.deposit{value: amount}();

        // Deposit WETH to vault
        WETH.approve(address(vault), amount);
    }

    ///////////////////////////////////////////////

    /// @dev Around 205,457 gas
    function test_DoNotProbeFeeTierA() public {
        // To make sure mint() is done exactly at the same time than other tests
        skip(TIME_ADVANCE);

        // Intialize vault
        vault.initialize(vaultParameters1);

        // Deposit WETH to vault
        _prepareWETH(2 ether);

        // Mint some APE
        vault.mint(true, vaultParameters1, 2 ether);

        // Deposit WETH to vault
        _prepareWETH(2 ether);

        // Mint some TEA
        vault.mint(false, vaultParameters1, 2 ether);

        // Burn some APE
        vault.burn(true, vaultParameters1, ape.balanceOf(address(this)));

        // Burn some TEA
        vault.burn(false, vaultParameters1, vault.balanceOf(address(this), 1));
    }

    function test_ProbeFeeTierA() public {
        // Intialize vault
        vault.initialize(vaultParameters1);

        // Skip
        skip(TIME_ADVANCE);

        // Deposit WETH to vault
        _prepareWETH(2 ether);

        // Mint some APE
        vault.mint(true, vaultParameters1, 2 ether);

        // Deposit WETH to vault
        _prepareWETH(2 ether);

        // Mint some TEA
        vault.mint(false, vaultParameters1, 2 ether);

        // Burn some APE
        vault.burn(true, vaultParameters1, ape.balanceOf(address(this)));

        // Burn some TEA
        vault.burn(false, vaultParameters1, vault.balanceOf(address(this), 1));
    }

    function test_DoNotProbeFeeTierB() public {
        // To make sure mint() is done exactly at the same time than other tests
        skip(TIME_ADVANCE);

        // Intialize vault
        vault.initialize(vaultParameters2);

        // Deposit WETH to vault
        _prepareWETH(2 ether);

        // Mint some APE
        vault.mint(true, vaultParameters2, 2 ether);

        // Deposit WETH to vault
        _prepareWETH(2 ether);

        // Mint some TEA
        vault.mint(false, vaultParameters2, 2 ether);

        // Burn some APE
        vault.burn(true, vaultParameters2, ape.balanceOf(address(this)));

        // Burn some TEA
        vault.burn(false, vaultParameters2, vault.balanceOf(address(this), 1));
    }

    function test_ProbeFeeTierB() public {
        // Intialize vault
        vault.initialize(vaultParameters2);

        // Skip
        skip(TIME_ADVANCE);

        // Deposit WETH to vault
        _prepareWETH(2 ether);

        // Mint some APE
        vault.mint(true, vaultParameters2, 2 ether);

        // Deposit WETH to vault
        _prepareWETH(2 ether);

        // Mint some TEA
        vault.mint(false, vaultParameters2, 2 ether);

        // Burn some APE
        vault.burn(true, vaultParameters2, ape.balanceOf(address(this)));

        // Burn some TEA
        vault.burn(false, vaultParameters2, vault.balanceOf(address(this), 1));
    }
}
