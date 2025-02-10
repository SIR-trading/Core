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
import {TransferHelper} from "v3-core/libraries/TransferHelper.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {MockERC20} from "src/test/MockERC20.sol";
import {APE} from "src/APE.sol";

contract SystemControlInitializationTest is Test {
    address public vault;
    SystemControl public systemControl;
    address payable sir = payable(vm.addr(10));

    function setUp() public {
        // Deploy SystemControl
        systemControl = new SystemControl();

        // Deploy APE implementation
        address ape = address(new APE());

        // Deploy Vault
        vault = address(new Vault(address(systemControl), sir, vm.addr(11), ape, Addresses.ADDR_WETH));
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

contract SystemControlTest is ERC1155TokenReceiver, Test {
    error FeeCannotBeZero();
    error ShutdownTooEarly();

    event NewBaseFee(uint16 baseFee);
    event FundsWithdrawn(address indexed to, address indexed token, uint256 amount);
    event NewLPFee(uint16 lpFee);

    struct ContributorPreMainnet {
        address addr;
        uint256 allocation;
    }

    uint256 constant SLOT_SYSTEM_STATUS = 2;
    uint256 constant OFFSET_SYSTEM_STATUS = 21 * 8;

    IWETH9 private constant WETH = IWETH9(Addresses.ADDR_WETH);

    SirStructs.VaultParameters vaultParameters =
        SirStructs.VaultParameters({
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

    mapping(uint48 => bool) private _seen;

    address oneContributor;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);
        // vm.writeFile("./numNewVaults.log", "");

        // Deploy Oracle
        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

        // Deploy SystemControl
        systemControl = new SystemControl();

        // Deploy SIR
        sir = payable(address(new SIR(Addresses.ADDR_WETH, address(systemControl))));

        // Deploy APE implementation
        address ape = address(new APE());

        // Deploy Vault
        vault = new Vault(address(systemControl), sir, oracle, ape, Addresses.ADDR_WETH);

        // Initialize SIR
        SIR(sir).initialize(address(vault));

        // Initialize SystemControl
        systemControl.initialize(address(vault), sir);

        // Get 1 pre-mainnet contributor
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contributors/spice-contributors.json"));
        bytes memory data = vm.parseJson(json);
        ContributorPreMainnet[] memory contributorsPreMainnet = abi.decode(data, (ContributorPreMainnet[]));
        oneContributor = contributorsPreMainnet[0].addr;
    }

    function test_haultMinting() public {
        // Initialize vault
        _initializeVault();

        // Save system parameters
        SirStructs.SystemParameters memory systemParams = vault.systemParams();
        assertTrue(!systemParams.mintingStopped, "mintingStopped not set to false");

        // Successfully mint APE
        _dealWETH(address(this), 1 ether);
        WETH.approve(address(vault), 1 ether);
        uint256 apeAmount = vault.mint(true, vaultParameters, 1 ether, 0);

        // Successfully mint TEA
        _dealWETH(address(this), 1 ether);
        WETH.approve(address(vault), 1 ether);
        uint256 teaAmount = vault.mint(false, vaultParameters, 1 ether, 0);

        // Successfully mint SIR
        skip(1 days);
        vm.prank(oneContributor);
        SIR(sir).contributorMint();

        // To ensure there are new SIR rewards
        skip(1 days);

        // Emergency hault
        vm.expectEmit();
        emit SystemStatusChanged(SystemStatus.TrainingWheels, SystemStatus.Emergency);
        systemControl.haultMinting();

        // Check if minting is haulted
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.Emergency));

        // Check fees are 0
        SirStructs.SystemParameters memory systemParams_ = vault.systemParams();
        assertEq(systemParams_.baseFee.fee, systemParams.baseFee.fee, "baseFee changed");
        assertEq(systemParams_.lpFee.fee, systemParams.lpFee.fee, "lpFee changed");
        assertEq(systemParams_.mintingStopped, true, "mintingStopped not set to true");
        assertEq(systemParams_.cumulativeTax, systemParams.cumulativeTax, "cumulativeTax not saved correctly");

        // Failure to mint APE
        _dealWETH(address(this), 1 ether);
        WETH.approve(address(vault), 1 ether);
        vm.expectRevert();
        vault.mint(true, vaultParameters, 1 ether, 0);

        // Failure to mint TEA
        _dealWETH(address(this), 1 ether);
        WETH.approve(address(vault), 1 ether);
        vm.expectRevert();
        vault.mint(false, vaultParameters, 1 ether, 0);

        // Failure to mint SIR
        vm.prank(oneContributor);
        vm.expectRevert();
        SIR(sir).contributorMint();

        // Burn APE
        vault.burn(true, vaultParameters, apeAmount);

        // Burn TEA
        vault.burn(false, vaultParameters, teaAmount);
    }

    function test_resumeMinting() public {
        test_haultMinting();

        SirStructs.SystemParameters memory systemParams = vault.systemParams();

        // Resume minting
        vm.expectEmit();
        emit SystemStatusChanged(SystemStatus.Emergency, SystemStatus.TrainingWheels);
        systemControl.resumeMinting();

        skip(SystemConstants.FEE_CHANGE_DELAY);

        // Successfully mint APE
        _dealWETH(address(this), 1 ether);
        WETH.approve(address(vault), 1 ether);
        vault.mint(true, vaultParameters, 1 ether, 0);

        // Successfully mint TEA
        _dealWETH(address(this), 1 ether);
        WETH.approve(address(vault), 1 ether);
        vault.mint(false, vaultParameters, 1 ether, 0);

        // Successfully mint SIR
        skip(1 days);
        vm.prank(oneContributor);
        SIR(sir).contributorMint();

        // Check fees are restored
        SirStructs.SystemParameters memory systemParams_ = vault.systemParams();
        assertEq(systemParams.baseFee.fee, systemParams_.baseFee.fee, "baseFee changed");
        assertEq(systemParams.lpFee.fee, systemParams_.lpFee.fee, "lpFee changed");
        assertTrue(!systemParams_.mintingStopped, "mintingStopped not set to false");
    }

    function testFuzz_shutdownSystemTooEarly(uint40 skipTime) public {
        skipTime = uint40(_bound(skipTime, 0, SystemConstants.SHUTDOWN_WITHDRAWAL_DELAY - 1));

        // Hault minting
        test_haultMinting();

        // Skip time
        skip(skipTime);

        // Shutdown system too early
        vm.expectRevert(ShutdownTooEarly.selector);
        systemControl.shutdownSystem();
    }

    function testFuzz_shutdownSystem(uint40 skipTime) public {
        skipTime = uint40(_bound(skipTime, SystemConstants.SHUTDOWN_WITHDRAWAL_DELAY, type(uint40).max));

        // Initialize vault
        _initializeVault();

        // Successfully mint APE
        _dealWETH(address(this), 1 ether);
        WETH.approve(address(vault), 1 ether);
        uint256 apeAmount = vault.mint(true, vaultParameters, 1 ether, 0);

        // Successfully mint TEA
        _dealWETH(address(this), 1 ether);
        WETH.approve(address(vault), 1 ether);
        uint256 teaAmount = vault.mint(false, vaultParameters, 1 ether, 0);

        // Hault minting
        systemControl.haultMinting();

        // Skip time
        skip(SystemConstants.SHUTDOWN_WITHDRAWAL_DELAY);

        // Shutdown system
        vm.expectEmit();
        emit SystemStatusChanged(SystemStatus.Emergency, SystemStatus.Shutdown);
        systemControl.shutdownSystem();

        // Check if system is shutdown
        assertEq(uint256(systemControl.systemStatus()), uint256(SystemStatus.Shutdown));

        // Failure to mint APE
        _dealWETH(address(this), 1 ether);
        WETH.approve(address(vault), 1 ether);
        vm.expectRevert();
        vault.mint(true, vaultParameters, 1 ether, 0);

        // Failure to mint TEA
        _dealWETH(address(this), 1 ether);
        WETH.approve(address(vault), 1 ether);
        vm.expectRevert();
        vault.mint(false, vaultParameters, 1 ether, 0);

        // Burn APE
        vault.burn(true, vaultParameters, apeAmount);

        // Burn TEA
        vault.burn(false, vaultParameters, teaAmount);
    }

    function testFuzz_saveFundsWrongCaller(address caller) public {
        vm.assume(caller != address(this));

        // Set state to Shutdown
        _setState(SystemStatus.Shutdown);

        // Attempt to withdraw funds
        address[] memory tokens = new address[](1);
        tokens[0] = Addresses.ADDR_USDC;
        vm.prank(caller);
        vm.expectRevert();
        systemControl.saveFunds(tokens, vm.addr(20));
    }

    function test_saveFundsWrongState() public {
        // Arary of tokens to withdraw
        address[] memory tokens = new address[](1);
        tokens[0] = Addresses.ADDR_USDC;

        // Set state to Unstoppable
        _setState(SystemStatus.Unstoppable);

        // Attempt to withdraw funds
        vm.expectRevert(WrongStatus.selector);
        systemControl.saveFunds(tokens, vm.addr(20));

        // Set state to Emergency
        _setState(SystemStatus.Emergency);

        // Attempt to withdraw funds
        vm.expectRevert(WrongStatus.selector);
        systemControl.saveFunds(tokens, vm.addr(20));

        // Set state to TrainingWheels
        _setState(SystemStatus.TrainingWheels);

        // Attempt to withdraw funds
        vm.expectRevert(WrongStatus.selector);
        systemControl.saveFunds(tokens, vm.addr(20));
    }

    function test_saveNoFunds() public {
        // Hault minting
        systemControl.haultMinting();

        // Skip time
        skip(SystemConstants.SHUTDOWN_WITHDRAWAL_DELAY);

        // Shutdown system
        systemControl.shutdownSystem();

        // Arary of tokens to withdraw
        address[] memory tokens = new address[](1);
        tokens[0] = Addresses.ADDR_USDC;

        // Withdraw funds
        vm.expectEmit();
        emit FundsWithdrawn(vm.addr(20), Addresses.ADDR_USDC, 0);
        systemControl.saveFunds(tokens, vm.addr(20));
    }

    function test_saveFunds() public {
        // Add some WETH
        _dealWETH(address(vault), 1 ether);

        // Add some BNB
        deal(Addresses.ADDR_BNB, address(vault), 2 ether, true);

        // Add some USDT
        deal(Addresses.ADDR_USDT, address(vault), 3 ether, true);

        // Mock token whose totalSupply function reverts
        MockERC20 token = new MockERC20("Mock", "MCK", 18);
        token.mint(address(vault), 4 ether);
        vm.mockCallRevert(address(token), abi.encodeWithSelector(token.balanceOf.selector), "");

        // Mock token whose totalSupply returns nothing
        MockERC20 token2 = new MockERC20("Mock2", "MCK2", 18);
        token2.mint(address(vault), 5 ether);
        vm.mockCall(address(token2), abi.encodeWithSelector(token2.balanceOf.selector), "");

        // Mock token whose totalSupply returns wrong value
        MockERC20 token3 = new MockERC20("Mock3", "MCK3", 18);
        token3.mint(address(vault), 6 ether);
        vm.mockCall(address(token3), abi.encodeWithSelector(token3.balanceOf.selector), abi.encode(7 ether));

        // Mock token whose transfer function reverts
        MockERC20 token4 = new MockERC20("Mock4", "MCK4", 18);
        token4.mint(address(vault), 7 ether);
        vm.mockCallRevert(address(token4), abi.encodeWithSelector(token4.transfer.selector), "");

        // Mock token whose transfer returns false
        MockERC20 token5 = new MockERC20("Mock5", "MCK5", 18);
        token5.mint(address(vault), 8 ether);
        vm.mockCall(address(token5), abi.encodeWithSelector(token5.transfer.selector), abi.encode(false));

        // Hault minting
        systemControl.haultMinting();

        // Skip time
        skip(SystemConstants.SHUTDOWN_WITHDRAWAL_DELAY);

        // Shutdown system
        systemControl.shutdownSystem();

        // Arary of tokens to withdraw
        address[] memory tokens = new address[](9);
        tokens[0] = Addresses.ADDR_USDC;
        tokens[1] = address(token5);
        tokens[2] = address(token4);
        tokens[3] = address(token3);
        tokens[4] = address(token2);
        tokens[5] = address(token);
        tokens[6] = Addresses.ADDR_USDT;
        tokens[7] = Addresses.ADDR_BNB;
        tokens[8] = Addresses.ADDR_WETH;

        // Expected events
        vm.expectEmit();
        emit FundsWithdrawn(vm.addr(20), Addresses.ADDR_USDC, 0);
        vm.expectEmit();
        emit FundsWithdrawn(vm.addr(20), address(token5), 0);
        vm.expectEmit();
        emit FundsWithdrawn(vm.addr(20), address(token4), 0);
        vm.expectEmit();
        emit FundsWithdrawn(vm.addr(20), address(token3), 0);
        vm.expectEmit();
        emit FundsWithdrawn(vm.addr(20), address(token2), 0);
        vm.expectEmit();
        emit FundsWithdrawn(vm.addr(20), address(token), 0);
        vm.expectEmit();
        emit FundsWithdrawn(vm.addr(20), Addresses.ADDR_USDT, 3 ether);
        vm.expectEmit();
        emit FundsWithdrawn(vm.addr(20), Addresses.ADDR_BNB, 2 ether);
        vm.expectEmit();
        emit FundsWithdrawn(vm.addr(20), Addresses.ADDR_WETH, 1 ether);

        // Withdraw funds
        systemControl.saveFunds(tokens, vm.addr(20));

        // Assert balances
        assertEq(IERC20(Addresses.ADDR_USDT).balanceOf(vm.addr(20)), 3 ether, "USDC balance wrong");
        assertEq(IERC20(Addresses.ADDR_BNB).balanceOf(vm.addr(20)), 2 ether, "BNB balance wrong");
        assertEq(IERC20(Addresses.ADDR_WETH).balanceOf(vm.addr(20)), 1 ether, "WETH balance wrong");
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

contract SystemControlWithoutOracleTest is ERC1155TokenReceiver, Test {
    error FeeCannotBeZero();
    error ShutdownTooEarly();
    error NewTaxesTooHigh();
    error ArraysLengthMismatch();
    error WrongVaultsOrOrder();

    event NewBaseFee(uint16 baseFee);
    event NewLPFee(uint16 lpFee);

    uint256 constant SLOT_SYSTEM_STATUS = 2;
    uint256 constant OFFSET_SYSTEM_STATUS = 21 * 8;

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

    mapping(uint48 => bool) private _seen;

    function setUp() public {
        // Deploy SystemControl
        systemControl = new SystemControl();

        // Deploy SIR
        sir = payable(address(new SIR(Addresses.ADDR_WETH, address(systemControl))));

        // Deploy APE implementation
        address ape = address(new APE());

        // Deploy Vault
        vault = new Vault(address(systemControl), sir, sir, ape, Addresses.ADDR_WETH);

        // Initialize SIR
        SIR(sir).initialize(address(vault));

        // Initialize SystemControl
        systemControl.initialize(address(vault), sir);
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

    function testFuzz_setBaseFeeWrongCaller(address caller, uint16 baseFee) public {
        vm.assume(caller != address(this));
        baseFee = uint16(_bound(baseFee, 1, type(uint16).max));

        // Set base fee
        vm.prank(caller);
        vm.expectRevert();
        systemControl.setBaseFee(baseFee);
    }

    function testFuzz_setBaseFeeWrongState(uint16 baseFee) public {
        baseFee = uint16(_bound(baseFee, 1, type(uint16).max));

        // Set state to Unstoppable
        _setState(SystemStatus.Unstoppable);

        // Attempt to set base fee
        vm.expectRevert(WrongStatus.selector);
        systemControl.setBaseFee(baseFee);

        // Set state to Emergency
        _setState(SystemStatus.Emergency);

        // Attempt to set base fee
        vm.expectRevert(WrongStatus.selector);
        systemControl.setBaseFee(baseFee);

        // Set state to Shutdown
        _setState(SystemStatus.Shutdown);

        // Attempt to set base fee
        vm.expectRevert(WrongStatus.selector);
        systemControl.setBaseFee(baseFee);
    }

    function test_setBaseFeeToZero() public {
        // Set base fee to 0
        vm.expectRevert(FeeCannotBeZero.selector);
        systemControl.setBaseFee(0);
    }

    function testFuzz_setBaseFeeAndCheckTooEarly(uint16 baseFee, uint40 delay) public {
        delay = uint40(_bound(delay, 0, SystemConstants.FEE_CHANGE_DELAY - 1));

        baseFee = uint16(_bound(baseFee, 1, type(uint16).max));

        // Retrieve current lp fee
        SirStructs.SystemParameters memory systemParams = vault.systemParams();

        // Set base fee
        vm.expectEmit();
        emit NewBaseFee(baseFee);
        systemControl.setBaseFee(baseFee);

        skip(delay);

        // Check if base fee is set correctly
        SirStructs.SystemParameters memory systemParams_ = vault.systemParams();
        assertEq(systemParams_.baseFee.fee, systemParams.baseFee.fee, "baseFee not set correctly");
        assertEq(systemParams_.lpFee.fee, systemParams.lpFee.fee, "lpFee not changed");
    }

    function testFuzz_setBaseFee(uint16 baseFee) public {
        baseFee = uint16(_bound(baseFee, 1, type(uint16).max));

        // Retrieve current lp fee
        SirStructs.SystemParameters memory systemParams = vault.systemParams();

        // Set base fee
        vm.expectEmit();
        emit NewBaseFee(baseFee);
        systemControl.setBaseFee(baseFee);

        skip(SystemConstants.FEE_CHANGE_DELAY);

        // Check if base fee is set correctly
        SirStructs.SystemParameters memory systemParams_ = vault.systemParams();
        assertEq(systemParams_.baseFee.fee, baseFee, "baseFee not set correctly");
        assertEq(systemParams_.lpFee.fee, systemParams.lpFee.fee, "lpFee not changed");
    }

    function testFuzz_setLpFeeWrongCaller(address caller, uint16 lpFee) public {
        vm.assume(caller != address(this));
        lpFee = uint16(_bound(lpFee, 1, type(uint16).max));

        // Set base fee
        vm.prank(caller);
        vm.expectRevert();
        systemControl.setLPFee(lpFee);
    }

    function testFuzz_setLpFeeWrongState(uint16 lpFee) public {
        lpFee = uint16(_bound(lpFee, 1, type(uint16).max));

        // Set state to Unstoppable
        _setState(SystemStatus.Unstoppable);

        // Attempt to set lp fee
        vm.expectRevert(WrongStatus.selector);
        systemControl.setLPFee(lpFee);

        // Set state to Emergency
        _setState(SystemStatus.Emergency);

        // Attempt to set lp fee
        vm.expectRevert(WrongStatus.selector);
        systemControl.setLPFee(lpFee);

        // Set state to Shutdown
        _setState(SystemStatus.Shutdown);

        // Attempt to set lp fee
        vm.expectRevert(WrongStatus.selector);
        systemControl.setLPFee(lpFee);
    }

    function test_setLpFeeToZero() public {
        // Set lp fee to 0
        vm.expectRevert(FeeCannotBeZero.selector);
        systemControl.setLPFee(0);
    }

    function testFuzz_setLpFeeAndCheckTooEarly(uint16 lpFee, uint40 delay) public {
        delay = uint40(_bound(delay, 0, SystemConstants.FEE_CHANGE_DELAY - 1));

        lpFee = uint16(_bound(lpFee, 1, type(uint16).max));

        // Retrieve current lp fee
        SirStructs.SystemParameters memory systemParams = vault.systemParams();

        // Set lp fee
        vm.expectEmit();
        emit NewLPFee(lpFee);
        systemControl.setLPFee(lpFee);

        skip(delay);

        // Check if lp fee is set correctly
        SirStructs.SystemParameters memory systemParams_ = vault.systemParams();
        assertEq(systemParams_.baseFee.fee, systemParams.baseFee.fee, "baseFee not changed");
        assertEq(systemParams_.lpFee.fee, systemParams.lpFee.fee, "lpFee not set correctly");
    }

    function testFuzz_setLpFee(uint16 lpFee) public {
        lpFee = uint16(_bound(lpFee, 1, type(uint16).max));

        // Retrieve current base fee
        SirStructs.SystemParameters memory systemParams = vault.systemParams();

        // Set lp fee
        vm.expectEmit();
        emit NewLPFee(lpFee);
        systemControl.setLPFee(lpFee);

        skip(SystemConstants.FEE_CHANGE_DELAY);

        // Check if lp fee is set correctly
        SirStructs.SystemParameters memory systemParams_ = vault.systemParams();
        assertEq(systemParams_.baseFee.fee, systemParams.baseFee.fee, "baseFee not changed");
        assertEq(systemParams_.lpFee.fee, lpFee, "lpFee not set correctly");
    }

    function testFuzz_updateVaultsIssuancesFirstTime(
        uint48[] memory vaults,
        uint8[] memory taxes
    ) public returns (uint48[] memory) {
        // Prepare the vaults
        (vaults, taxes) = _prepareVaults(vaults, taxes);

        // vm.writeLine("./numNewVaults.log", vm.toString(numNewVaults));

        // Update vaults issuances
        systemControl.updateVaultsIssuances(new uint48[](0), vaults, taxes);

        return vaults;
    }

    function testFuzz_updateVaultsIssuancesWrongCaller(
        uint48[] memory oldVaults,
        uint8[] memory oldTaxes,
        uint48[] memory newVaults,
        uint8[] memory newTaxes,
        address user
    ) public {
        vm.assume(user != address(this));

        oldVaults = testFuzz_updateVaultsIssuancesFirstTime(oldVaults, oldTaxes);

        // Prepare the vaults
        (newVaults, newTaxes) = _prepareVaults(newVaults, newTaxes);

        // Update vaults issuances
        vm.prank(user);
        vm.expectRevert();
        systemControl.updateVaultsIssuances(oldVaults, newVaults, newTaxes);
    }

    function testFuzz_updateVaultsIssuancesArraysMismatch(
        uint48[] memory oldVaults,
        uint8[] memory oldTaxes,
        uint48[] memory newVaults,
        uint8[] memory newTaxes
    ) public {
        oldVaults = testFuzz_updateVaultsIssuancesFirstTime(oldVaults, oldTaxes);

        // Remove repeated vaults
        newVaults = _removeDuplicates(newVaults);

        // Ensure lengths of newVaults and taxes are not equal
        vm.assume(newVaults.length != newTaxes.length);

        // Sort newVaults
        if (newVaults.length > 1) _quickSort(newVaults, 0, int(newVaults.length - 1));

        // Cumulative squared tax
        uint256 cumulativeSquaredTaxes;
        for (uint256 i = 0; i < newTaxes.length; ++i) {
            if (newTaxes[i] == 0) newTaxes[i] = 1;
            cumulativeSquaredTaxes += uint256(newTaxes[i]) ** 2;
        }

        // Check if cumulativeSquaredTaxes exceeds max value
        if (cumulativeSquaredTaxes > uint256(type(uint8).max) ** 2) {
            uint128 sqrtCumSquaredTaxes = _sqrt(cumulativeSquaredTaxes) + 1; // To ensure it's rounding up
            uint256 decrement;
            for (uint256 i = 0; i < newTaxes.length; ++i) {
                // Scale down taxes
                newTaxes[i] = uint8((uint256(newTaxes[i]) * type(uint8).max) / sqrtCumSquaredTaxes);
                if (newTaxes[i] == 0) {
                    newTaxes[i] = 1;
                    decrement++;
                } else if (decrement > 0) {
                    uint8 dec = newTaxes[i] - 1 < decrement ? newTaxes[i] - 1 : uint8(decrement);
                    newTaxes[i] -= dec;
                    decrement -= dec;
                }
            }
        }

        // Update vaults issuances
        vm.expectRevert(ArraysLengthMismatch.selector);
        systemControl.updateVaultsIssuances(oldVaults, newVaults, newTaxes);
    }

    function testFuzz_updateVaultsIssuancesWrongOldVaults(
        uint48[] memory oldVaults,
        uint8[] memory oldTaxes,
        uint48[] memory wrongOldVaults,
        uint48[] memory newVaults,
        uint8[] memory newTaxes
    ) public {
        oldVaults = testFuzz_updateVaultsIssuancesFirstTime(oldVaults, oldTaxes);

        vm.assume(keccak256(abi.encodePacked(oldVaults)) != keccak256(abi.encodePacked(wrongOldVaults)));

        // Prepare the vaults
        (newVaults, newTaxes) = _prepareVaults(newVaults, newTaxes);

        // Update vaults issuances
        vm.expectRevert(WrongVaultsOrOrder.selector);
        systemControl.updateVaultsIssuances(wrongOldVaults, newVaults, newTaxes);
    }

    function testFuzz_updateVaultsIssuancesWithZeroTax(
        uint48[] memory oldVaults,
        uint8[] memory oldTaxes,
        uint48[] memory newVaults,
        uint8[] memory newTaxes,
        uint256 nullTaxIndex
    ) public {
        oldVaults = testFuzz_updateVaultsIssuancesFirstTime(oldVaults, oldTaxes);

        // Remove repeated vaults
        newVaults = _removeDuplicates(newVaults);

        // Number of new vaults
        uint256 numNewVaults = newVaults.length < newTaxes.length ? newVaults.length : newTaxes.length;
        numNewVaults = _bound(numNewVaults, 0, uint256(type(uint8).max) ** 2);
        vm.assume(numNewVaults > 0);

        // Equalize lengths of newVaults and taxes
        assembly {
            mstore(newVaults, numNewVaults)
            mstore(newTaxes, numNewVaults)
        }

        // Sort newVaults
        if (numNewVaults > 1) _quickSort(newVaults, 0, int(numNewVaults - 1));

        // Cumulative squared tax
        uint256 cumulativeSquaredTaxes;
        for (uint256 i = 0; i < numNewVaults; ++i) {
            if (newTaxes[i] == 0) newTaxes[i] = 1;
            cumulativeSquaredTaxes += uint256(newTaxes[i]) ** 2;
        }

        // Check if cumulativeSquaredTaxes exceeds max value
        bool anyTaxIsZero;
        uint128 sqrtCumSquaredTaxes = _sqrt(cumulativeSquaredTaxes) + 1; // To ensure it's rounding up
        for (uint256 i = 0; i < numNewVaults; ++i) {
            // Scale down taxes
            if (cumulativeSquaredTaxes > uint256(type(uint8).max) ** 2)
                newTaxes[i] = uint8((uint256(newTaxes[i]) * type(uint8).max) / sqrtCumSquaredTaxes);
            if (newTaxes[i] == 0) anyTaxIsZero = true;
        }

        // Add 0 tax if necessary
        if (numNewVaults > 0 && !anyTaxIsZero) {
            nullTaxIndex = nullTaxIndex % numNewVaults;
            newTaxes[nullTaxIndex] = 0;
        }

        // Update vaults issuances
        vm.expectRevert(FeeCannotBeZero.selector);
        systemControl.updateVaultsIssuances(oldVaults, newVaults, newTaxes);
    }

    function testFuzz_updateVaultsIssuancesWrongOrder(
        uint48[] memory oldVaults,
        uint8[] memory oldTaxes,
        uint48[] memory newVaults,
        uint8[] memory newTaxes
    ) public {
        oldVaults = testFuzz_updateVaultsIssuancesFirstTime(oldVaults, oldTaxes);

        // Number of new vaults
        uint256 numNewVaults = newVaults.length < newTaxes.length ? newVaults.length : newTaxes.length;
        numNewVaults = _bound(numNewVaults, 0, uint256(type(uint8).max) ** 2);

        // Equalize lengths of newVaults and taxes
        assembly {
            mstore(newVaults, numNewVaults)
            mstore(newTaxes, numNewVaults)
        }

        // Check that it's not already sorted without duplicates
        bool alreadySorted = true;
        for (uint256 i = 1; i < numNewVaults; ++i) {
            if (newVaults[i] <= newVaults[i - 1]) {
                alreadySorted = false;
                break;
            }
        }
        vm.assume(!alreadySorted);

        // Cumulative squared tax
        uint256 cumulativeSquaredTaxes;
        for (uint256 i = 0; i < numNewVaults; ++i) {
            if (newTaxes[i] == 0) newTaxes[i] = 1;
            cumulativeSquaredTaxes += uint256(newTaxes[i]) ** 2;
        }

        // Check if cumulativeSquaredTaxes exceeds max value
        if (cumulativeSquaredTaxes > uint256(type(uint8).max) ** 2) {
            uint128 sqrtCumSquaredTaxes = _sqrt(cumulativeSquaredTaxes) + 1; // To ensure it's rounding up
            uint256 decrement;
            for (uint256 i = 0; i < numNewVaults; ++i) {
                // Scale down taxes
                newTaxes[i] = uint8((uint256(newTaxes[i]) * type(uint8).max) / sqrtCumSquaredTaxes);
                if (newTaxes[i] == 0) {
                    newTaxes[i] = 1;
                    decrement++;
                } else if (decrement > 0) {
                    uint8 dec = newTaxes[i] - 1 < decrement ? newTaxes[i] - 1 : uint8(decrement);
                    newTaxes[i] -= dec;
                    decrement -= dec;
                }
            }
        }

        // Update vaults issuances
        vm.expectRevert(WrongVaultsOrOrder.selector);
        systemControl.updateVaultsIssuances(oldVaults, newVaults, newTaxes);
    }

    function testFuzz_updateVaultsIssuancesWithHighTaxes(
        uint48[] memory oldVaults,
        uint8[] memory oldTaxes,
        uint48[] memory newVaults,
        uint8[] memory newTaxes
    ) public {
        oldVaults = testFuzz_updateVaultsIssuancesFirstTime(oldVaults, oldTaxes);

        // Remove repeated vaults
        newVaults = _removeDuplicates(newVaults);

        // Number of new vaults
        uint256 numNewVaults = newVaults.length < newTaxes.length ? newVaults.length : newTaxes.length;
        numNewVaults = _bound(numNewVaults, 0, uint256(type(uint8).max) ** 2);
        vm.assume(numNewVaults > 1);

        // Equalize lengths of newVaults and taxes
        assembly {
            mstore(newVaults, numNewVaults)
            mstore(newTaxes, numNewVaults)
        }

        // Sort newVaults
        _quickSort(newVaults, 0, int(numNewVaults - 1));

        // Cumulative squared tax
        uint256 cumulativeSquaredTaxes;
        for (uint256 i = 0; i < numNewVaults; ++i) {
            if (newTaxes[i] == 0) newTaxes[i] = 1;
            cumulativeSquaredTaxes += uint256(newTaxes[i]) ** 2;
        }

        // Check if cumulativeSquaredTaxes is too low
        if (cumulativeSquaredTaxes <= uint256(type(uint8).max) ** 2) {
            uint128 sqrtCumSquaredTaxes = _sqrt(cumulativeSquaredTaxes);
            cumulativeSquaredTaxes = 0;
            for (uint256 i = 0; i < numNewVaults; ++i) {
                // Scale up taxes
                if (newTaxes[i] == 0) newTaxes[i] = 1;
                uint256 newTax = (uint256(newTaxes[i]) * type(uint8).max - 1) / sqrtCumSquaredTaxes + 1;
                if (newTax > type(uint8).max) newTaxes[i] = type(uint8).max;
                else newTaxes[i] = uint8(newTax);

                cumulativeSquaredTaxes += uint256(newTaxes[i]) ** 2;
            }
        }

        // Still.. Check if cumulativeSquaredTaxes is too low one last time
        if (cumulativeSquaredTaxes <= uint256(type(uint8).max) ** 2) {
            for (uint256 i = 0; i < numNewVaults; i++) {
                if (newTaxes[i] < type(uint8).max) {
                    newTaxes[i]++;
                    break;
                }
            }
        }

        // Update vaults issuances
        vm.expectRevert(NewTaxesTooHigh.selector);
        systemControl.updateVaultsIssuances(oldVaults, newVaults, newTaxes);
    }

    function testFuzz_updateVaultsIssuances(
        uint48[] memory oldVaults,
        uint8[] memory oldTaxes,
        uint48[] memory newVaults,
        uint8[] memory newTaxes
    ) public {
        oldVaults = testFuzz_updateVaultsIssuancesFirstTime(oldVaults, oldTaxes);

        // Prepare the vaults
        (newVaults, newTaxes) = _prepareVaults(newVaults, newTaxes);

        // Update vaults issuances
        systemControl.updateVaultsIssuances(oldVaults, newVaults, newTaxes);
    }

    function test_updateMaxNumberVaultsIssuances() public {
        // Prepare the vaults
        uint256 maxLen = uint256(type(uint8).max) ** 2;
        uint48[] memory newVaults = new uint48[](maxLen);
        uint8[] memory newTaxes = new uint8[](maxLen);
        for (uint256 i = 0; i < maxLen; ++i) {
            newVaults[i] = uint48(i + 1);
            newTaxes[i] = 1;
        }

        // Update vaults issuances
        systemControl.updateVaultsIssuances(new uint48[](0), newVaults, newTaxes);
    }

    function testFuzz_updateTooManyVaultsIssuances() public {
        // Prepare the vaults
        uint256 maxLen = uint256(type(uint8).max) ** 2 + 1;
        uint48[] memory newVaults = new uint48[](maxLen);
        uint8[] memory newTaxes = new uint8[](maxLen);
        for (uint256 i = 0; i < maxLen; ++i) {
            newVaults[i] = uint48(i + 1);
            newTaxes[i] = 1;
        }

        // Update vaults issuances
        vm.expectRevert();
        systemControl.updateVaultsIssuances(new uint48[](0), newVaults, newTaxes);
    }

    function test_updateHighestVaultIssuance() public {
        // Prepare the vaults
        uint48[] memory newVaults = new uint48[](1);
        uint8[] memory newTaxes = new uint8[](1);
        newVaults[0] = 1;
        newTaxes[0] = type(uint8).max;

        // Update vaults issuances
        systemControl.updateVaultsIssuances(new uint48[](0), newVaults, newTaxes);
    }

    function test_updateTooHighVaultIssuance() public {
        // Prepare the vaults
        uint48[] memory newVaults = new uint48[](2);
        uint8[] memory newTaxes = new uint8[](2);
        newVaults[0] = 1;
        newTaxes[0] = type(uint8).max;
        newVaults[1] = 2;
        newTaxes[1] = 1;

        // Update vaults issuances
        vm.expectRevert();
        systemControl.updateVaultsIssuances(new uint48[](0), newVaults, newTaxes);
    }

    /////////////////////////////////////////////////////////////////
    ///////////////////  PRIVATE  //  FUNCTIONS  ///////////////////
    ///////////////////////////////////////////////////////////////

    function _prepareVaults(
        uint48[] memory newVaults,
        uint8[] memory newTaxes
    ) private returns (uint48[] memory, uint8[] memory) {
        // Remove repeated vaults
        newVaults = _removeDuplicates(newVaults);

        // Number of new vaults
        uint256 numNewVaults = newVaults.length < newTaxes.length ? newVaults.length : newTaxes.length;
        numNewVaults = _bound(numNewVaults, 0, uint256(type(uint8).max) ** 2);

        // Equalize lengths of newVaults and taxes
        assembly {
            mstore(newVaults, numNewVaults)
            mstore(newTaxes, numNewVaults)
        }

        // Sort newVaults
        if (numNewVaults > 1) _quickSort(newVaults, 0, int(numNewVaults - 1));

        // Cumulative squared tax
        uint256 cumulativeSquaredTaxes;
        for (uint256 i = 0; i < numNewVaults; ++i) {
            if (newTaxes[i] == 0) newTaxes[i] = 1;
            cumulativeSquaredTaxes += uint256(newTaxes[i]) ** 2;
        }

        // Check if cumulativeSquaredTaxes exceeds max value
        if (cumulativeSquaredTaxes > uint256(type(uint8).max) ** 2) {
            uint128 sqrtCumSquaredTaxes = _sqrt(cumulativeSquaredTaxes) + 1; // To ensure it's rounding up
            uint256 decrement;
            for (uint256 i = 0; i < numNewVaults; ++i) {
                // Scale down taxes
                newTaxes[i] = uint8((uint256(newTaxes[i]) * type(uint8).max) / sqrtCumSquaredTaxes);
                if (newTaxes[i] == 0) {
                    newTaxes[i] = 1;
                    decrement++;
                } else if (decrement > 0) {
                    uint8 dec = newTaxes[i] - 1 < decrement ? newTaxes[i] - 1 : uint8(decrement);
                    newTaxes[i] -= dec;
                    decrement -= dec;
                }
            }
        }

        return (newVaults, newTaxes);
    }

    function _removeDuplicates(uint48[] memory input) private returns (uint48[] memory) {
        if (input.length == 0) {
            return input;
        }

        uint uniqueCount = 0;
        for (uint i = 0; i < input.length; i++) {
            if (!_seen[input[i]]) {
                _seen[input[i]] = true;
                uniqueCount++;
            }
        }

        uint48[] memory uniqueArray = new uint48[](uniqueCount);
        uint index = 0;

        for (uint i = 0; i < input.length; i++) {
            if (_seen[input[i]]) {
                uniqueArray[index++] = input[i];
                _seen[input[i]] = false;
            }
        }

        return uniqueArray;
    }

    function _quickSort(uint48[] memory arr, int left, int right) private pure {
        int i = left;
        int j = right;
        if (i == j) return;
        uint48 pivot = arr[uint(left + (right - left) / 2)];
        while (i <= j) {
            while (arr[uint(i)] < pivot) i++;
            while (pivot < arr[uint(j)]) j--;
            if (i <= j) {
                (arr[uint(i)], arr[uint(j)]) = (arr[uint(j)], arr[uint(i)]);
                i++;
                j--;
            }
        }
        if (left < j) _quickSort(arr, left, j);
        if (i < right) _quickSort(arr, i, right);
    }

    function _sqrt(uint256 x) private pure returns (uint128) {
        if (x == 0) return 0;
        else {
            uint256 xx = x;
            uint256 r = 1;
            if (xx >= 0x100000000000000000000000000000000) {
                xx >>= 128;
                r <<= 64;
            }
            if (xx >= 0x10000000000000000) {
                xx >>= 64;
                r <<= 32;
            }
            if (xx >= 0x100000000) {
                xx >>= 32;
                r <<= 16;
            }
            if (xx >= 0x10000) {
                xx >>= 16;
                r <<= 8;
            }
            if (xx >= 0x100) {
                xx >>= 8;
                r <<= 4;
            }
            if (xx >= 0x10) {
                xx >>= 4;
                r <<= 2;
            }
            if (xx >= 0x8) {
                r <<= 1;
            }
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            uint256 r1 = x / r;
            return uint128(r < r1 ? r : r1);
        }
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
