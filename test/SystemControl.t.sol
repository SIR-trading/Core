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
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";

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

contract SystemControlTest is ERC1155TokenReceiver, Test {
    uint256 constant SLOT_SYSTEM_STATUS = 1;
    uint256 constant OFFSET_SYSTEM_STATUS = 21 * 8;

    IWETH9 private constant WETH = IWETH9(Addresses.ADDR_WETH);

    VaultStructs.VaultParameters vaultParameters =
        VaultStructs.VaultParameters({
            debtToken: Addresses.ADDR_USDT,
            collateralToken: Addresses.ADDR_WETH,
            leverageTier: -1
        });

    enum SystemStatus {
        Unstoppable,
        TrainingWheels,
        Emergency,
        Shutdown
    }
    event SystemStatusChanged(SystemStatus indexed oldStatus, SystemStatus indexed newStatus);
    error WrongStatus();

    address payable sir;
    Vault public vault;
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
        vault = new Vault(address(systemControl), sir, oracle);

        // Initialize SIR
        SIR(sir).initialize(address(vault));

        // Initialize SystemControl
        systemControl.initialize(address(vault));
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
        // Set state to Unstoppable
        _setState(SystemStatus.Unstoppable);

        // Attempt to exit Beta
        vm.expectRevert(WrongStatus.selector);
        systemControl.exitBeta();

        // Set state to Emergency
        _setState(SystemStatus.Emergency);

        // Attempt to exit Beta
        vm.expectRevert(WrongStatus.selector);
        systemControl.exitBeta();

        // Set state to Shutdown
        _setState(SystemStatus.Shutdown);

        // Attempt to exit Beta
        vm.expectRevert(WrongStatus.selector);
        systemControl.exitBeta();
    }

    function test_exitBeta() public {
        // Exit Beta
        vm.expectEmit();
        emit SystemStatusChanged(SystemStatus.TrainingWheels, SystemStatus.Unstoppable);
        systemControl.exitBeta();

        // Check if Beta is exited
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.Unstoppable));
    }

    function testFuzz_haultMintingWrongCaller(address caller) public {
        vm.assume(caller != address(this));

        // Exit Beta
        vm.prank(caller);
        vm.expectRevert();
        systemControl.haultMinting();

        // Check if Beta is still active
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.TrainingWheels));
    }

    function test_haultMintingWrongState() public {
        // Set state to Unstoppable
        _setState(SystemStatus.Unstoppable);

        // Attempt to exit Beta
        vm.expectRevert(WrongStatus.selector);
        systemControl.haultMinting();

        // Set state to Emergency
        _setState(SystemStatus.Emergency);

        // Attempt to exit Beta
        vm.expectRevert(WrongStatus.selector);
        systemControl.haultMinting();

        // Set state to Shutdown
        _setState(SystemStatus.Shutdown);

        // Attempt to exit Beta
        vm.expectRevert(WrongStatus.selector);
        systemControl.haultMinting();
    }

    function test_haultMinting() public returns (uint16 baseFee, uint16 lpFee) {
        // Initialize vault
        _initializeVault();

        // Save system parameters
        uint40 tsIssuanceStart;
        uint16 cumTax;
        bool mintingStopped;
        (tsIssuanceStart, baseFee, lpFee, mintingStopped, cumTax) = vault.systemParams();
        assertTrue(!mintingStopped, "mintingStopped not set to false");

        // Successfully mint APE
        _dealWETH(address(this), 1 ether);
        WETH.transfer(address(vault), 1 ether);
        uint256 apeAmount = vault.mint(true, vaultParameters);

        // Successfully mint TEA
        _dealWETH(address(this), 1 ether);
        WETH.transfer(address(vault), 1 ether);
        uint256 teaAmount = vault.mint(false, vaultParameters);

        // Exit Beta
        vm.expectEmit();
        emit SystemStatusChanged(SystemStatus.TrainingWheels, SystemStatus.Emergency);
        systemControl.haultMinting();

        // Check if Beta is exited
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.Emergency));

        // Check fees are 0
        (uint40 tsIssuanceStart_, uint16 baseFee_, uint16 lpFee_, bool mintingStopped_, uint16 cumTax_) = vault
            .systemParams();
        assertEq(tsIssuanceStart_, tsIssuanceStart, "tsIssuanceStart not saved correctly");
        assertEq(baseFee_, 0, "baseFee not set to 0");
        assertEq(lpFee_, 0, "lpFee not set to 0");
        assertEq(mintingStopped_, true, "mintingStopped not set to true");
        assertEq(cumTax_, cumTax, "cumTax not saved correctly");

        // Failure to mint APE
        _dealWETH(address(this), 1 ether);
        WETH.transfer(address(vault), 1 ether);
        vm.expectRevert();
        vault.mint(true, vaultParameters);

        // Failure to mint TEA
        _dealWETH(address(this), 1 ether);
        WETH.transfer(address(vault), 1 ether);
        vm.expectRevert();
        vault.mint(false, vaultParameters);

        // Burn APE
        vault.burn(true, vaultParameters, apeAmount);

        // Burn TEA
        vault.burn(false, vaultParameters, teaAmount);
    }

    function testFuzz_resumeMintingWrongCaller(address caller) public {
        vm.assume(caller != address(this));

        // Set state to Emergency
        _setState(SystemStatus.Emergency);

        // Exit Beta
        vm.prank(caller);
        vm.expectRevert();
        systemControl.resumeMinting();

        // Check if Beta is still active
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.Emergency));
    }

    function testFuzz_resumeMintingWrongState() public {
        // Set state to Unstoppable
        _setState(SystemStatus.Unstoppable);

        // Attempt to resume minting
        vm.expectRevert(WrongStatus.selector);
        systemControl.resumeMinting();

        // Set state to TrainingWheels
        _setState(SystemStatus.TrainingWheels);

        // Attempt to resume minting
        vm.expectRevert(WrongStatus.selector);
        systemControl.resumeMinting();

        // Set state to Shutdown
        _setState(SystemStatus.Shutdown);

        // Attempt to resume minting
        vm.expectRevert(WrongStatus.selector);
        systemControl.resumeMinting();
    }

    function test_resumeMinting() public {
        (uint16 baseFee, uint16 lpFee) = test_haultMinting();

        // Resume minting
        vm.expectEmit();
        emit SystemStatusChanged(SystemStatus.Emergency, SystemStatus.TrainingWheels);
        systemControl.resumeMinting();

        // Successfully mint APE
        _dealWETH(address(this), 1 ether);
        WETH.transfer(address(vault), 1 ether);
        vault.mint(true, vaultParameters);

        // Successfully mint TEA
        _dealWETH(address(this), 1 ether);
        WETH.transfer(address(vault), 1 ether);
        vault.mint(false, vaultParameters);

        // Check fees are restored
        (, uint16 baseFee_, uint16 lpFee_, bool mintingStopped, ) = vault.systemParams();
        assertEq(baseFee_, baseFee, "baseFee not restored");
        assertEq(lpFee_, lpFee, "lpFee not restored");
        assertTrue(!mintingStopped, "mintingStopped not set to false");
    }

    function testFuzz_shutdownSystemWrongCaller(address caller) public {
        vm.assume(caller != address(this));

        // Set state to Emergency
        _setState(SystemStatus.Emergency);

        // Exit Beta
        vm.prank(caller);
        vm.expectRevert();
        systemControl.shutdownSystem();

        // Check if Beta is still active
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.Emergency));
    }

    function test_shutdownSystemWrongState() public {
        // Set state to Unstoppable
        _setState(SystemStatus.Unstoppable);

        // Attempt to shutdown system
        vm.expectRevert(WrongStatus.selector);
        systemControl.shutdownSystem();

        // Set state to TrainingWheels
        _setState(SystemStatus.TrainingWheels);

        // Attempt to shutdown system
        vm.expectRevert(WrongStatus.selector);
        systemControl.shutdownSystem();

        // Set state to Shutdown
        _setState(SystemStatus.Shutdown);

        // Attempt to shutdown system
        vm.expectRevert(WrongStatus.selector);
        systemControl.shutdownSystem();
    }

    uint40 public constant SHUTDOWN_WITHDRAWAL_DELAY = 20 days;
    error ShutdownTooEarly();

    function testFuzz_shutdownSystemTooEarly(uint40 skipTime) public {
        skipTime = uint40(_bound(skipTime, 0, SHUTDOWN_WITHDRAWAL_DELAY - 1));

        // Hault minting
        test_haultMinting();

        // Skip time
        skip(skipTime);

        // Shutdown system too early
        vm.expectRevert(ShutdownTooEarly.selector);
        systemControl.shutdownSystem();
    }

    function testFuzz_shutdownSystem(uint40 skipTime) public {
        skipTime = uint40(_bound(skipTime, SHUTDOWN_WITHDRAWAL_DELAY, type(uint40).max));

        // Initialize vault
        _initializeVault();

        // Mint APE
        _dealWETH(address(this), 1 ether);
        WETH.transfer(address(vault), 1 ether);
        uint256 amountApe = vault.mint(true, vaultParameters);

        // Mint TEA
        _dealWETH(address(this), 1 ether);
        WETH.transfer(address(vault), 1 ether);
        uint256 amountTea = vault.mint(false, vaultParameters);

        // Hault minting
        systemControl.haultMinting();

        // Skip time
        skip(SHUTDOWN_WITHDRAWAL_DELAY);

        // Shutdown system
        vm.expectEmit();
        emit SystemStatusChanged(SystemStatus.Emergency, SystemStatus.Shutdown);
        systemControl.shutdownSystem();

        // Check if system is shutdown
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.Shutdown));

        // Attempt to mint APE
        _dealWETH(address(this), 1 ether);
        WETH.transfer(address(vault), 1 ether);
        vm.expectRevert();
        vault.mint(true, vaultParameters);

        // Attempt to mint TEA
        _dealWETH(address(this), 1 ether);
        WETH.transfer(address(vault), 1 ether);
        vm.expectRevert();
        vault.mint(false, vaultParameters);

        // Burn APE
        vault.burn(true, vaultParameters, amountApe);

        // Burn TEA
        vault.burn(false, vaultParameters, amountTea);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////////  PRIVATE  //  FUNCTIONS  ///////////////////
    ///////////////////////////////////////////////////////////////

    function _initializeVault() private {
        // Initialize vault
        vault.initialize(vaultParameters);

        // Set 1 vault to receive all the SIR rewards
        uint48[] memory oldVaults = new uint48[](0);
        uint48[] memory newVaults = new uint48[](1);
        newVaults[0] = 1;
        uint8[] memory newTaxes = new uint8[](1);
        newTaxes[0] = 1;
        vm.prank(address(systemControl));
        vault.updateVaults(oldVaults, newVaults, newTaxes, 1);
    }

    function _dealWETH(address to, uint256 amount) internal {
        vm.deal(vm.addr(2), amount);
        vm.prank(vm.addr(2));
        WETH.deposit{value: amount}();
        vm.prank(vm.addr(2));
        WETH.transfer(address(to), amount);
    }

    function _setState(SystemStatus systemStatus) private {
        // Retrieve current status
        uint256 slot = uint256(vm.load(address(systemControl), bytes32(SLOT_SYSTEM_STATUS)));

        // Clear status
        slot &= ~(uint256(3) << OFFSET_SYSTEM_STATUS);

        // Set status
        slot |= uint256(systemStatus) << OFFSET_SYSTEM_STATUS;

        // Store status
        vm.store(address(systemControl), bytes32(SLOT_SYSTEM_STATUS), bytes32(slot));

        // Check if status is set correctly
        assertEq(uint256(systemControl.systemStatus()), uint256(systemStatus), "systemStatus not set correctly");
    }
}
