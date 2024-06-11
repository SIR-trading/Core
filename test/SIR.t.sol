// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {SIR} from "src/SIR.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {ErrorComputation} from "./ErrorComputation.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {TransferHelper} from "src/libraries/TransferHelper.sol";

contract SIRTest is Test {
    SIR public sir;

    address alice = vm.addr(1);
    address bob = vm.addr(2);
    address charlie = vm.addr(3);

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        // Deploy Oracle
        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

        // Deploy SIR
        sir = new SIR(Addresses.ADDR_WETH);

        // Deploy Vault
        vault = address(new Vault(vm.addr(10), address(staker), oracle));

        // Initialize SIR
        sir.initialize(vault);
    }
}
