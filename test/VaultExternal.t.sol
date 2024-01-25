// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {VaultExternal} from "src/libraries/VaultExternal.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {SaltedAddress} from "src/libraries/SaltedAddress.sol";
import {Oracle} from "src/Oracle.sol";
import {APE} from "src/APE.sol";
import "forge-std/Test.sol";

contract VaultExternalTest is Test {
    error VaultAlreadyInitialized();
    error LeverageTierOutOfRange();
    error NoFeeTiers();

    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId
    );

    VaultStructs.Parameters[] paramsById;

    mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => VaultStructs.State)))
        public state; // Do not use vaultId 0
    VaultStructs.TokenParameters transientTokenParameters;
    uint40 constant VAULT_ID = 9;
    uint40 vaultId;
    address alice;

    Oracle oracle;

    function latestTokenParams()
        external
        view
        returns (
            string memory name,
            string memory symbol,
            uint8 decimals,
            address debtToken,
            address collateralToken,
            int8 leverageTier
        )
    {
        name = transientTokenParameters.name;
        symbol = transientTokenParameters.symbol;
        decimals = transientTokenParameters.decimals;

        VaultStructs.Parameters memory params = paramsById[paramsById.length - 1];
        debtToken = params.debtToken;
        collateralToken = params.collateralToken;
        leverageTier = params.leverageTier;
    }

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        // Expand array to VAULT_ID elements
        for (vaultId = 0; vaultId < VAULT_ID; vaultId++) {
            paramsById.push(VaultStructs.Parameters(address(0), address(0), 0));
        }

        // Deployr oracle
        oracle = new Oracle();

        alice = vm.addr(1);
    }

    function testFuzz_deployETHvsUSDC(int8 leverageTier) public {
        leverageTier = int8(_bound(leverageTier, -3, 2)); // Only accepted values in the system

        vm.expectEmit();
        emit VaultInitialized(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier, vaultId);
        VaultExternal.deployAPE(
            oracle,
            state[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            transientTokenParameters,
            Addresses.ADDR_USDC,
            Addresses.ADDR_WETH,
            leverageTier
        );

        APE ape = APE(SaltedAddress.getAddress(address(this), vaultId));
        assertGt(address(ape).code.length, 0);

        assertEq(ape.symbol(), string.concat("APE-", Strings.toString(vaultId)));
        assertEq(ape.decimals(), 18);
        assertEq(ape.debtToken(), Addresses.ADDR_USDC);
        assertEq(ape.collateralToken(), Addresses.ADDR_WETH);
        assertEq(ape.leverageTier(), leverageTier);

        VaultStructs.Parameters memory params = paramsById[vaultId];
        assertEq(params.debtToken, Addresses.ADDR_USDC);
        assertEq(params.collateralToken, Addresses.ADDR_WETH);
        assertEq(params.leverageTier, leverageTier);
    }

    function testFuzz_deployWrongTokens(address debtToken, address collateralToken, int8 leverageTier) public {
        leverageTier = int8(_bound(leverageTier, -3, 2)); // Only accepted values in the system

        vm.expectRevert(abi.encodeWithSelector(NoFeeTiers.selector));
        VaultExternal.deployAPE(
            oracle,
            state[debtToken][collateralToken][leverageTier],
            paramsById,
            transientTokenParameters,
            debtToken,
            collateralToken,
            leverageTier
        );
    }

    function testFuzz_deployETHvsUSDCWrongLeverage(int8 leverageTier) public {
        vm.assume(leverageTier < -3 || leverageTier > 2); // Non accepted values in the system

        vm.expectRevert(abi.encodeWithSelector(LeverageTierOutOfRange.selector));
        VaultExternal.deployAPE(
            oracle,
            state[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            transientTokenParameters,
            Addresses.ADDR_USDC,
            Addresses.ADDR_WETH,
            leverageTier
        );
    }

    function test_deployMaxNumberOfVaultsPerTokenTuple() public returns (int8 leverageTier) {
        leverageTier = -3;
        for (; vaultId < VAULT_ID + 6; vaultId++) {
            vm.expectEmit();
            emit VaultInitialized(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier, vaultId);
            VaultExternal.deployAPE(
                oracle,
                state[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
                paramsById,
                transientTokenParameters,
                Addresses.ADDR_USDC,
                Addresses.ADDR_WETH,
                leverageTier
            );

            APE ape = APE(SaltedAddress.getAddress(address(this), vaultId));
            assertGt(address(ape).code.length, 0);

            assertEq(ape.symbol(), string.concat("APE-", Strings.toString(vaultId)));
            assertEq(ape.decimals(), 18);
            assertEq(ape.debtToken(), Addresses.ADDR_USDC);
            assertEq(ape.collateralToken(), Addresses.ADDR_WETH);
            assertEq(ape.leverageTier(), leverageTier);

            VaultStructs.Parameters memory params = paramsById[vaultId];
            assertEq(params.debtToken, Addresses.ADDR_USDC);
            assertEq(params.collateralToken, Addresses.ADDR_WETH);
            assertEq(params.leverageTier, leverageTier);

            leverageTier++;
        }
    }

    function test_deploy1TooManyVaultsPerTokenTuple() public {
        int8 leverageTier = test_deployMaxNumberOfVaultsPerTokenTuple();

        vm.expectRevert(abi.encodeWithSelector(LeverageTierOutOfRange.selector));
        VaultExternal.deployAPE(
            oracle,
            state[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            transientTokenParameters,
            Addresses.ADDR_USDC,
            Addresses.ADDR_WETH,
            leverageTier
        );

        leverageTier--;
        vm.expectRevert(abi.encodeWithSelector(VaultAlreadyInitialized.selector));
        VaultExternal.deployAPE(
            oracle,
            state[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            transientTokenParameters,
            Addresses.ADDR_USDC,
            Addresses.ADDR_WETH,
            leverageTier
        );
    }

    function testFuzz_teaURI(uint vaultId_, int8 leverageTier_, uint256 totalSupply_) public {
        vaultId_ = _bound(vaultId_, 1, VAULT_ID - 1);
        leverageTier_ = int8(_bound(leverageTier_, -3, 2)); // Only accepted values in the system

        paramsById[vaultId_] = VaultStructs.Parameters(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier_);

        string memory uriStr = VaultExternal.teaURI(paramsById, vaultId_, totalSupply_);
        // console.log("uriStr:", uriStr);

        // Parse the values of the JSON data uri using JS. Some fancy code to deal with big numbers.
        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "-e";
        inputs[2] = string.concat(
            "console.log(JSON.stringify(JSON.parse(decodeURIComponent('",
            uriStr,
            '\').replace(/^data:application\\/json;charset=UTF-8,/,"").replace(/(?<=:\\s*)(\\d{16,})(?=[,}])/g, "\\"$1\\""))));'
        );

        string memory output = string(vm.ffi(inputs));

        assertEq(vm.parseJsonString(output, "$.name"), string.concat("LP Token for APE-", vm.toString(vaultId_)));
        assertEq(vm.parseJsonString(output, "$.symbol"), string.concat("TEA-", vm.toString(vaultId_)));
        assertEq(vm.parseJsonUint(output, "$.decimals"), 18);
        assertEq(vm.parseJsonUint(output, "$.chain_id"), 1);
        assertEq(vm.parseJsonUint(output, "$.vault_id"), vaultId_);
        assertEq(vm.parseJsonString(output, "$.debt_token"), Strings.toHexString(Addresses.ADDR_USDC));
        assertEq(vm.parseJsonString(output, "$.collateral_token"), Strings.toHexString(Addresses.ADDR_WETH));
        assertEq(vm.parseJsonInt(output, "$.leverage_tier"), leverageTier_);
        assertEq(vm.parseJsonUint(output, "$.total_supply"), totalSupply_);
    }
}
