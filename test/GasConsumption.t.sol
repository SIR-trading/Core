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

    /**
|------------------------------|-----------------|--------|--------|--------|---------|
| Deployment Cost              | Deployment Size |        |        |        |         |
| 5426770                      | 25467           |        |        |        |         |
| Function Name                | min             | avg    | median | max    | # calls |
| balanceOf                    | 701             | 701    | 701    | 701    | 4       |
| burn                         | 102409          | 107789 | 107821 | 113107 | 8       |
| initialize                   | 483102          | 548027 | 547994 | 613018 | 4       |
| mint                         | 152765          | 177494 | 177617 | 201979 | 8       |
| updateVaults                 | 102235          | 102235 | 102235 | 102235 | 4       |
     */

    // WETH/USDT's Uniswap TWAP has a long cardinality
    SirStructs.VaultParameters public vaultParameters1 =
        SirStructs.VaultParameters({
            debtToken: Addresses.ADDR_USDT,
            collateralToken: address(WETH),
            leverageTier: int8(-1)
        });

    // WETH/BNB's Uniswap TWAP is of cardinality 1
    SirStructs.VaultParameters public vaultParameters2 =
        SirStructs.VaultParameters({
            debtToken: Addresses.ADDR_BNB,
            collateralToken: address(WETH),
            leverageTier: int8(0)
        });

    // USDT/WETH to mint with debt token
    SirStructs.VaultParameters public vaultParameters3 =
        SirStructs.VaultParameters({
            debtToken: address(WETH),
            collateralToken: Addresses.ADDR_USDT,
            leverageTier: int8(1)
        });

    function setUp() public {
        vm.createSelectFork("mainnet", BLOCK_NUMBER_START);

        // vm.writeFile("./gains.log", "");

        ape = new APE();

        Oracle oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);
        vault = new Vault(vm.addr(100), vm.addr(101), address(oracle), address(ape), Addresses.ADDR_WETH);

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

    function _prepareETH(uint256 amount) private {
        // Deal ETH
        vm.deal(address(this), amount);
    }

    ///////////////////////////////////////////////

    /// @dev Around 205,457 gas
    function test_DoNotProbeFeeTierA() public {
        // To make sure mint() is done exactly at the same time than other tests
        skip(TIME_ADVANCE);

        // Intialize vault
        vault.initialize(vaultParameters1);

        // Mint some APE with WETH
        _prepareWETH(2 ether);
        vault.mint(true, vaultParameters1, 2 ether, 0);

        // Mint some TEA with WETH
        _prepareWETH(2 ether);
        vault.mint(false, vaultParameters1, 2 ether, 0);

        // Mint some APE with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(true, vaultParameters1, 0, 0);

        // Mint some TEA with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(false, vaultParameters1, 0, 0);

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

        // Mint some APE with WETH
        _prepareWETH(2 ether);
        vault.mint(true, vaultParameters1, 2 ether, 0);

        // Mint some TEA with WETH
        _prepareWETH(2 ether);
        vault.mint(false, vaultParameters1, 2 ether, 0);

        // Mint some APE with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(true, vaultParameters1, 0, 0);

        // Mint some TEA with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(false, vaultParameters1, 0, 0);

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

        // Mint some APE with WETH
        _prepareWETH(2 ether);
        vault.mint(true, vaultParameters2, 2 ether, 0);

        // Mint some TEA with WETH
        _prepareWETH(2 ether);
        vault.mint(false, vaultParameters2, 2 ether, 0);

        // Mint some APE with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(true, vaultParameters2, 0, 0);

        // Mint some TEA with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(false, vaultParameters2, 0, 0);

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

        // Mint some APE with WETH
        _prepareWETH(2 ether);
        vault.mint(true, vaultParameters2, 2 ether, 0);

        // Mint some TEA with WETH
        _prepareWETH(2 ether);
        vault.mint(false, vaultParameters2, 2 ether, 0);

        // Mint some APE with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(true, vaultParameters2, 0, 0);

        // Mint some TEA with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(false, vaultParameters2, 0, 0);

        // Burn some APE
        vault.burn(true, vaultParameters2, ape.balanceOf(address(this)));

        // Burn some TEA
        vault.burn(false, vaultParameters2, vault.balanceOf(address(this), 1));
    }

    function test_DoNotProbeFeeTierC() public {
        // To make sure mint() is done exactly at the same time than other tests
        skip(TIME_ADVANCE);

        // Intialize vault
        vault.initialize(vaultParameters3);

        // Mint some APE with WETH
        _prepareWETH(2 ether);
        vault.mint(true, vaultParameters3, 2 ether, 1);

        // Mint some TEA with WETH
        _prepareWETH(2 ether);
        vault.mint(false, vaultParameters3, 2 ether, 1);

        // Mint some APE with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(true, vaultParameters3, 0, 1);

        // Mint some TEA with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(false, vaultParameters3, 0, 1);

        // Burn some APE
        vault.burn(true, vaultParameters3, ape.balanceOf(address(this)));

        // Burn some TEA
        vault.burn(false, vaultParameters3, vault.balanceOf(address(this), 1));
    }

    function test_ProbeFeeTierC() public {
        // Intialize vault
        vault.initialize(vaultParameters3);

        // Skip
        skip(TIME_ADVANCE);

        // Mint some APE with WETH
        _prepareWETH(2 ether);
        vault.mint(true, vaultParameters3, 2 ether, 1);

        // Mint some TEA with WETH
        _prepareWETH(2 ether);
        vault.mint(false, vaultParameters3, 2 ether, 1);

        // Mint some APE with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(true, vaultParameters3, 0, 1);

        // Mint some TEA with ETH
        _prepareETH(2 ether);
        vault.mint{value: 2 ether}(false, vaultParameters3, 0, 1);

        // Burn some APE
        vault.burn(true, vaultParameters3, ape.balanceOf(address(this)));

        // Burn some TEA
        vault.burn(false, vaultParameters3, vault.balanceOf(address(this), 1));
    }
}
