// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {Staker} from "src/Staker.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {ErrorComputation} from "./ErrorComputation.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {TransferHelper} from "src/libraries/TransferHelper.sol";

contract SIRTest is Test {
    address alice;
    address bob;
    address charlie;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        staker = new Staker(Addresses.ADDR_WETH);

        vault = address(new Vault(vm.addr(10), address(staker), vm.addr(12)));
        staker.initialize(vault);

        alice = vm.addr(1);
        bob = vm.addr(2);
        charlie = vm.addr(3);
    }
}
