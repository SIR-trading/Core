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
        systemControl.initialize(vault);
    }

    function test_alreadyInitialized() public {
        // Initialize SystemControl
        systemControl.initialize(vault);

        // Initialize SystemControl again
        vm.expectRevert();
        systemControl.initialize(vault);
    }
}

contract SystemControlTest is Test {
    enum SystemStatus {
        Unstoppable,
        TrainingWheels,
        Emergency,
        Shutdown
    }
    event SystemStatusChanged(SystemStatus indexed oldStatus, SystemStatus indexed newStatus);
    error WrongStatus();

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
        systemControl.initialize(vault);
    }

    function testFuzz_exitBetaWrongCaller(address caller) public {
        vm.assume(caller != address(this));

        // Exit Beta
        vm.prank(caller);
        vm.expectRevert();
        systemControl.exitBeta();

        // Check if Beta is still active
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.TrainingWheels));
    }

    function test_exitBetaWrongState() public {
        // CHANGE TO WRONG STATE
        // // Change to TrainingWheels
        // systemControl.haultMinting();

        // Attempt to exit Beta
        vm.expectRevert(WrongStatus.selector);
        systemControl.exitBeta();

        // Check if Beta is still active
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.TrainingWheels));
    }

    function test_exitBeta() public {
        // Exit Beta
        vm.expectEmit();
        emit SystemStatusChanged(SystemStatus.TrainingWheels, SystemStatus.Unstoppable);
        systemControl.exitBeta();

        // Check if Beta is exited
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.Unstoppable));
    }

    function _setState(SystemStatus systemStatus) private {
        // // Increase supply
        // uint256 slot = uint256(vm.load(address(staker), bytes32(uint256(SLOT_SUPPLY))));
        // uint80 balanceOfSIR = uint80(slot) + amount;
        // slot >>= 80;
        // uint96 unclaimedETH = uint96(slot);
        // vm.store(
        //     address(staker),
        //     bytes32(uint256(SLOT_SUPPLY)),
        //     bytes32(abi.encodePacked(uint80(0), unclaimedETH, balanceOfSIR))
        // );
        // assertEq(staker.supply(), balanceOfSIR, "Wrong supply slot used by vm.store");
        // // Increase balance
        // slot = uint256(vm.load(address(staker), keccak256(abi.encode(account, bytes32(uint256(SLOT_BALANCES))))));
        // balanceOfSIR = uint80(slot) + amount;
        // slot >>= 80;
        // unclaimedETH = uint96(slot);
        // vm.store(
        //     address(staker),
        //     keccak256(abi.encode(account, bytes32(uint256(SLOT_BALANCES)))),
        //     bytes32(abi.encodePacked(uint80(0), unclaimedETH, balanceOfSIR))
        // );
        // assertEq(staker.balanceOf(account), balanceOfSIR, "Wrong balance slot used by vm.store");
    }
}
