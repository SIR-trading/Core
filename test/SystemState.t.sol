import "forge-std/Test.sol";
import {SystemState} from "src/SystemState.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";

contract SystemStateInstance is SystemState {
    constructor(
        address systemControl,
        address sir,
        address vaultExternal
    ) SystemState(systemControl, sir, vaultExternal) {}

    function updateLPerIssuanceParams(
        uint256 vaultId,
        address lper0,
        address lper1
    ) external returns (uint104 unclaimedRewards) {
        return updateLPerIssuanceParams(false, vaultId, lper0, lper1);
    }
}

contract SystemStateTest is Test {
    SystemStateInstance systemState;

    function setUp() public {
        systemState = new SystemStateInstance(vm.addr(1), vm.addr(2), vm.addr(3));
    }

    function test_vaultIssuanceParamsBeforeIssuance() public {
        uint256 vaultId = 42;
        vm.warp(69 seconds);

        uint152 cumSIRPerTEA = systemState.cumulativeSIRPerTEA(vaultId);

        assertEq(cumSIRPerTEA, 0);
    }
}
