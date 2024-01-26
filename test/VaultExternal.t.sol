// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {VaultExternal} from "src/libraries/VaultExternal.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {VaultStructs} from "src/libraries/VaultStructs.sol";
import {MockERC20} from "src/test/MockERC20.sol";
import {SaltedAddress} from "src/libraries/SaltedAddress.sol";
import {Oracle} from "src/Oracle.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {APE} from "src/APE.sol";
import {ABDKMathQuad} from "abdk/ABDKMathQuad.sol";
import "forge-std/Test.sol";

import {TickMathPrecision} from "src/libraries/TickMathPrecision.sol";

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

contract VaultExternalGetReserves is Test {
    using ABDKMathQuad for bytes16;

    bytes16 log2Point0001; // 1.0001 in IEEE-754 Quadruple Precision Floating Point Numbers

    MockERC20 private _collateralToken;
    address alice;

    function setUp() public {
        _collateralToken = new MockERC20("Collateral token", "TKN", 18);
        alice = vm.addr(1);

        log2Point0001 = ABDKMathQuad.fromUInt(10001).div(ABDKMathQuad.fromUInt(10000)).log_2();
    }

    function testFuzz_getReservesNoReserves(
        bool isMint,
        bool isAPE,
        int8 leverageTier,
        uint152 collateralDeposited,
        uint256 totalSupplyCollateral,
        VaultStructs.State memory state_
    ) public {
        leverageTier = int8(_bound(leverageTier, -3, 2)); // Only accepted values in the system
        collateralDeposited = uint152(_bound(collateralDeposited, 0, type(uint256).max - totalSupplyCollateral));
        collateralDeposited = uint152(_bound(collateralDeposited, 0, type(uint152).max));

        // Mint tokens
        _collateralToken.mint(alice, totalSupplyCollateral);
        _collateralToken.mint(address(this), collateralDeposited);

        // No reserves
        state_.totalReserves = 0;
        state_.treasury = 0;

        (VaultStructs.Reserves memory reserves, APE ape, uint152 collateralDeposited_) = VaultExternal.getReserves(
            isMint,
            isAPE,
            state_,
            address(_collateralToken),
            leverageTier
        );

        assertEq(reserves.treasury, 0);
        assertEq(reserves.apesReserve, 0);
        assertEq(reserves.lpReserve, 0);
        assertTrue(isAPE ? address(ape) != address(0) : address(ape) == address(0));
        assertEq(collateralDeposited_, isMint ? collateralDeposited : 0);
    }

    function testFuzz_getReservesReserveAllAPE(
        bool isMint,
        bool isAPE,
        int8 leverageTier,
        uint152 collateralDeposited,
        uint256 totalSupplyCollateral,
        VaultStructs.State memory state_
    ) public {
        leverageTier = int8(_bound(leverageTier, -3, 2)); // Only accepted values in the system

        state_.totalReserves = uint152(_bound(state_.totalReserves, 2, type(uint152).max)); // Min totalReserves is always 2 (or 0 if no minted has occured)
        state_.treasury = uint152(_bound(state_.treasury, 0, type(uint152).max - state_.totalReserves));
        collateralDeposited = uint152(
            _bound(collateralDeposited, 0, type(uint152).max - state_.totalReserves - state_.treasury)
        );

        totalSupplyCollateral = _bound(
            totalSupplyCollateral,
            state_.totalReserves + state_.treasury,
            type(uint256).max - collateralDeposited
        );

        // Mint tokens
        _collateralToken.mint(alice, totalSupplyCollateral - state_.totalReserves - state_.treasury);
        _collateralToken.mint(address(this), state_.totalReserves + state_.treasury + collateralDeposited);

        // type(int64).min represents -∞ => lpReserve is empty
        state_.tickPriceSatX42 = type(int64).min;

        (VaultStructs.Reserves memory reserves, APE ape, uint152 collateralDeposited_) = VaultExternal.getReserves(
            isMint,
            isAPE,
            state_,
            address(_collateralToken),
            leverageTier
        );

        assertEq(reserves.treasury, state_.treasury);
        assertEq(reserves.apesReserve, state_.totalReserves - 1);
        assertEq(reserves.lpReserve, 1);
        assertTrue(isAPE ? address(ape) != address(0) : address(ape) == address(0));
        assertEq(collateralDeposited_, isMint ? collateralDeposited : 0);
    }

    function testFuzz_getReservesReserveAllTEA(
        bool isMint,
        bool isAPE,
        int8 leverageTier,
        uint152 collateralDeposited,
        uint256 totalSupplyCollateral,
        VaultStructs.State memory state_
    ) public {
        leverageTier = int8(_bound(leverageTier, -3, 2)); // Only accepted values in the system

        state_.totalReserves = uint152(_bound(state_.totalReserves, 2, type(uint152).max)); // Min totalReserves is always 2 (or 0 if no minted has occured)
        state_.treasury = uint152(_bound(state_.treasury, 0, type(uint152).max - state_.totalReserves));
        collateralDeposited = uint152(
            _bound(collateralDeposited, 0, type(uint152).max - state_.totalReserves - state_.treasury)
        );

        totalSupplyCollateral = _bound(
            totalSupplyCollateral,
            state_.totalReserves + state_.treasury,
            type(uint256).max - collateralDeposited
        );

        // Mint tokens
        _collateralToken.mint(alice, totalSupplyCollateral - state_.totalReserves - state_.treasury);
        _collateralToken.mint(address(this), state_.totalReserves + state_.treasury + collateralDeposited);

        // type(int64).max represents +∞ => apesReserve is empty
        state_.tickPriceSatX42 = type(int64).max;

        (VaultStructs.Reserves memory reserves, APE ape, uint152 collateralDeposited_) = VaultExternal.getReserves(
            isMint,
            isAPE,
            state_,
            address(_collateralToken),
            leverageTier
        );

        assertEq(reserves.treasury, state_.treasury);
        assertEq(reserves.apesReserve, 1);
        assertEq(reserves.lpReserve, state_.totalReserves - 1);
        assertTrue(isAPE ? address(ape) != address(0) : address(ape) == address(0));
        assertEq(collateralDeposited_, isMint ? collateralDeposited : 0);
    }

    function testFuzz_getReserves(
        bool isMint,
        bool isAPE,
        int8 leverageTier,
        uint152 collateralDeposited,
        uint256 totalSupplyCollateral,
        VaultStructs.State memory state_
    ) public {
        leverageTier = int8(_bound(leverageTier, -3, 2)); // Only accepted values in the system

        state_.totalReserves = uint152(_bound(state_.totalReserves, 2, type(uint152).max)); // Min totalReserves is always 2 (or 0 if no minted has occured)
        state_.treasury = uint152(_bound(state_.treasury, 0, type(uint152).max - state_.totalReserves));
        collateralDeposited = uint152(
            _bound(collateralDeposited, 0, type(uint152).max - state_.totalReserves - state_.treasury)
        );

        totalSupplyCollateral = _bound(
            totalSupplyCollateral,
            state_.totalReserves + state_.treasury,
            type(uint256).max - collateralDeposited
        );

        state_.tickPriceSatX42 = int64(_bound(state_.tickPriceSatX42, type(int64).min + 1, type(int64).max - 1));

        // Mint tokens
        _collateralToken.mint(alice, totalSupplyCollateral - state_.totalReserves - state_.treasury);
        _collateralToken.mint(address(this), state_.totalReserves + state_.treasury + collateralDeposited);

        (VaultStructs.Reserves memory reserves, APE ape, uint152 collateralDeposited_) = VaultExternal.getReserves(
            isMint,
            isAPE,
            state_,
            address(_collateralToken),
            leverageTier
        );

        (uint256 apesReserve, uint256 lpReserve) = _getReservesWithFloatingPoint(leverageTier, state_);

        assertEq(reserves.treasury, state_.treasury);
        assertApproxEqAbs(reserves.apesReserve, apesReserve, 2 + state_.totalReserves / 1e16); // We found this is our accuracy by numerical experimentation
        assertApproxEqAbs(reserves.lpReserve, lpReserve, 2 + state_.totalReserves / 1e16);
        assertTrue(isAPE ? address(ape) != address(0) : address(ape) == address(0));
        assertEq(collateralDeposited_, isMint ? collateralDeposited : 0);
    }

    function testFuzz_getReservesTooLargeDeposit(
        bool isAPE,
        int8 leverageTier,
        uint256 collateralDeposited,
        uint256 totalSupplyCollateral,
        VaultStructs.State memory state_
    ) public {
        leverageTier = int8(_bound(leverageTier, -3, 2)); // Only accepted values in the system

        state_.totalReserves = uint152(_bound(state_.totalReserves, 2, type(uint152).max)); // Min totalReserves is always 2 (or 0 if no minted has occured)
        state_.treasury = uint152(_bound(state_.treasury, 0, type(uint152).max - state_.totalReserves));
        totalSupplyCollateral = _bound(
            totalSupplyCollateral,
            state_.totalReserves + state_.treasury,
            type(uint256).max - type(uint152).max + state_.totalReserves + state_.treasury - 1
        );
        collateralDeposited = _bound(
            collateralDeposited,
            type(uint152).max - state_.totalReserves - state_.treasury + 1,
            type(uint256).max - totalSupplyCollateral
        );

        // Mint tokens
        _collateralToken.mint(alice, totalSupplyCollateral - state_.totalReserves - state_.treasury);
        _collateralToken.mint(address(this), state_.totalReserves + state_.treasury + collateralDeposited);

        vm.expectRevert();
        VaultExternal.getReserves(true, isAPE, state_, address(_collateralToken), leverageTier);
    }

    function _getReservesWithFloatingPoint(
        int8 leverageTier,
        VaultStructs.State memory state_
    ) private view returns (uint152 apesReserve, uint152 lpReserve) {
        bytes16 tickPriceFP = ABDKMathQuad.fromInt(state_.tickPriceX42).div(ABDKMathQuad.fromUInt(2 ** 42));
        bytes16 tickPriceSatFP = ABDKMathQuad.fromInt(state_.tickPriceSatX42).div(ABDKMathQuad.fromUInt(2 ** 42));
        bytes16 totalReservesFP = ABDKMathQuad.fromUInt(state_.totalReserves);

        if (state_.tickPriceX42 < state_.tickPriceSatX42) {
            bytes16 leverageRatioFP = ABDKMathQuad.fromInt(leverageTier).pow_2().add(ABDKMathQuad.fromUInt(1));

            apesReserve = uint152(
                tickPriceFP
                    .sub(tickPriceSatFP)
                    .mul(log2Point0001)
                    .mul(leverageRatioFP.sub(ABDKMathQuad.fromUInt(1)))
                    .pow_2()
                    .mul(totalReservesFP)
                    .div(leverageRatioFP)
                    .toUInt()
            );
            lpReserve = state_.totalReserves - apesReserve;
        } else {
            bytes16 collateralizationRatioFP = ABDKMathQuad.fromInt(-leverageTier).pow_2().add(
                ABDKMathQuad.fromUInt(1)
            );

            lpReserve = uint152(
                tickPriceSatFP
                    .sub(tickPriceFP)
                    .mul(log2Point0001)
                    .pow_2()
                    .mul(totalReservesFP)
                    .div(collateralizationRatioFP)
                    .toUInt()
            );
            apesReserve = state_.totalReserves - lpReserve;
        }
    }
}
