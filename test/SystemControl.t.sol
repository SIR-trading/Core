// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {Oracle} from "src/Oracle.sol";
import {SIR} from "src/SIR.sol";
import {SystemControl} from "src/SystemControl.sol";
import {Staker} from "src/Staker.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {TransferHelper} from "src/libraries/TransferHelper.sol";

contract SystemControlInitializationTest is Test {
    address payable sir;
    address public vault;
    SystemControl public systemControl;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        // Deploy Oracle
        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

        // Deploy SystemControl
        systemControl = new SystemControl();

        // Deploy SIR
        sir = payable(address(new SIR(Addresses.ADDR_WETH)));

        // Deploy Vault
        vault = address(new Vault(address(systemControl), sir, oracle));

        // Initialize SIR
        SIR(sir).initialize(vault);
    }

    function testFuzz_initializationWrongCaller(address caller) public {
        vm.assume(caller != address(this));

        // Initialize SystemControl
        vm.prank(caller);
        vm.expectRevert();
        systemControl.initialize(vault, sir);
    }

    function test_alreadyInitialized() public {
        // Initialize SystemControl
        systemControl.initialize(vault, sir);

        // Initialize SystemControl again
        vm.expectRevert();
        systemControl.initialize(vault, sir);
    }
}

contract SystemControlTest is Test {
    address payable sir;
    address public vault;
    SystemControl public systemControl;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        // Deploy Oracle
        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

        // Deploy SystemControl
        systemControl = new SystemControl();

        // Deploy SIR
        sir = payable(address(new SIR(Addresses.ADDR_WETH)));

        // Deploy Vault
        vault = address(new Vault(address(systemControl), sir, oracle));

        // Initialize SIR
        SIR(sir).initialize(vault);

        // Initialize SystemControl
        systemControl.initialize(vault, sir);
    }

    function testFuzz_exitBetaWrongCaller(address caller) public {
        vm.assume(caller != address(this));

        // Exit Beta
        vm.prank(caller);
        vm.expectRevert();
        systemControl.exitBeta();
    }

    enum SystemStatus {
        Unstoppable,
        TrainingWheels,
        Emergency,
        Shutdown
    }
    event SystemStatusChanged(SystemStatus indexed oldStatus, SystemStatus indexed newStatus);

    function test_exitBeta() public {
        // Exit Beta
        vm.expectEmit();
        emit SystemStatusChanged(SystemStatus.TrainingWheels, SystemStatus.Unstoppable);
        systemControl.exitBeta();

        // Check if Beta is exited
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.Unstoppable));
    }

    error WrongStatus();

    // function test_exitBetaWrongState() public {
    //     // Change to TrainingWheels
    //     systemControl.haultMinting();

    //     // Attempt to exit Beta
    //     vm.expectRevert(WrongStatus.selector);
    //     systemControl.exitBeta();

    //     //
    // }
}
