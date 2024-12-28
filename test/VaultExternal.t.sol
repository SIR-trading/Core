// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {VaultExternal} from "src/libraries/VaultExternal.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {MockERC20} from "src/test/MockERC20.sol";
import {AddressClone} from "src/libraries/AddressClone.sol";
import {Oracle} from "src/Oracle.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {APE} from "src/APE.sol";
import {ABDKMathQuad} from "abdk/ABDKMathQuad.sol";
import "forge-std/Test.sol";

import {TickMathPrecision} from "src/libraries/TickMathPrecision.sol";

contract VaultExternalTest is Test {
    error VaultAlreadyInitialized();
    error LeverageTierOutOfRange();
    error NoUniswapPool();

    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId,
        address ape
    );

    SirStructs.VaultParameters[] paramsById;
    address apeImplementation;

    mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => SirStructs.VaultState)))
        public vaultState; // Do not use vaultId 0
    uint48 constant VAULT_ID = 9;
    uint48 vaultId;
    address alice;

    Oracle oracle;

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        // Expand array to VAULT_ID elements
        for (vaultId = 0; vaultId < VAULT_ID; vaultId++) {
            paramsById.push(SirStructs.VaultParameters(address(0), address(0), 0));
        }

        // Deploy oracle
        oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);

        // Deploy APE implementation
        apeImplementation = address(new APE());

        alice = vm.addr(1);
    }

    function testFuzz_deployETHvsUSDC(int8 leverageTier) public {
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER)); // Only accepted values in the system

        // vm.expectEmit();
        // emit VaultInitialized(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier, vaultId);
        VaultExternal.deploy(
            oracle,
            vaultState[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            SirStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDC,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: leverageTier
            }),
            apeImplementation
        );

        APE ape = APE(AddressClone.getAddress(address(this), vaultId));
        assertGt(address(ape).code.length, 0);

        assertEq(ape.symbol(), string.concat("APE-", Strings.toString(vaultId)), "Symbol is not correct");
        assertEq(ape.decimals(), 18, "Decimals is not correct");
        assertEq(ape.debtToken(), Addresses.ADDR_USDC, "Debt token is not correct");
        assertEq(ape.collateralToken(), Addresses.ADDR_WETH, "Collateral token is not correct");
        assertEq(ape.leverageTier(), leverageTier, "Leverage tier is not correct");

        SirStructs.VaultParameters memory params = paramsById[vaultId];
        assertEq(params.debtToken, Addresses.ADDR_USDC, "Debt token is not correct");
        assertEq(params.collateralToken, Addresses.ADDR_WETH, "Collateral token is not correct");
        assertEq(params.leverageTier, leverageTier, "Leverage tier is not correct");
    }

    function testFuzz_deployWrongTokens(address debtToken, address collateralToken, int8 leverageTier) public {
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MAX_LEVERAGE_TIER)); // Only accepted values in the system

        vm.expectRevert(NoUniswapPool.selector);
        VaultExternal.deploy(
            oracle,
            vaultState[debtToken][collateralToken][leverageTier],
            paramsById,
            SirStructs.VaultParameters(debtToken, collateralToken, leverageTier),
            apeImplementation
        );
    }

    function testFuzz_deployETHvsUSDCWrongLeverage(int8 leverageTier) public {
        vm.assume(leverageTier < SystemConstants.MIN_LEVERAGE_TIER || leverageTier > SystemConstants.MAX_LEVERAGE_TIER); // Non accepted values in the system

        vm.expectRevert(LeverageTierOutOfRange.selector);
        VaultExternal.deploy(
            oracle,
            vaultState[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            SirStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDC,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: leverageTier
            }),
            apeImplementation
        );
    }

    function test_deployMaxNumberOfVaultsPerTokenTuple() public returns (int8 leverageTier) {
        leverageTier = -3;
        for (; vaultId < VAULT_ID + 6; vaultId++) {
            vm.expectEmit();
            emit VaultInitialized(
                Addresses.ADDR_USDC,
                Addresses.ADDR_WETH,
                leverageTier,
                vaultId,
                AddressClone.getAddress(address(this), vaultId)
            );
            VaultExternal.deploy(
                oracle,
                vaultState[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
                paramsById,
                SirStructs.VaultParameters({
                    debtToken: Addresses.ADDR_USDC,
                    collateralToken: Addresses.ADDR_WETH,
                    leverageTier: leverageTier
                }),
                apeImplementation
            );

            APE ape = APE(AddressClone.getAddress(address(this), vaultId));
            assertGt(address(ape).code.length, 0);

            assertEq(ape.symbol(), string.concat("APE-", Strings.toString(vaultId)));
            assertEq(ape.decimals(), 18);
            assertEq(ape.debtToken(), Addresses.ADDR_USDC);
            assertEq(ape.collateralToken(), Addresses.ADDR_WETH);
            assertEq(ape.leverageTier(), leverageTier);

            SirStructs.VaultParameters memory params = paramsById[vaultId];
            assertEq(params.debtToken, Addresses.ADDR_USDC);
            assertEq(params.collateralToken, Addresses.ADDR_WETH);
            assertEq(params.leverageTier, leverageTier);

            leverageTier++;
        }
    }

    function test_deploy1TooManyVaultsPerTokenTuple() public {
        int8 leverageTier = test_deployMaxNumberOfVaultsPerTokenTuple();

        vm.expectRevert(LeverageTierOutOfRange.selector);
        VaultExternal.deploy(
            oracle,
            vaultState[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            SirStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDC,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: leverageTier
            }),
            apeImplementation
        );

        leverageTier--;
        vm.expectRevert(VaultAlreadyInitialized.selector);
        VaultExternal.deploy(
            oracle,
            vaultState[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            SirStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDC,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: leverageTier
            }),
            apeImplementation
        );
    }

    function testFuzz_teaURI(uint vaultId_, int8 leverageTier_, uint256 totalSupply_) public {
        vaultId_ = _bound(vaultId_, 1, VAULT_ID - 1);
        leverageTier_ = int8(_bound(leverageTier_, -3, 2)); // Only accepted values in the system

        paramsById[vaultId_] = SirStructs.VaultParameters(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier_);

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

    struct CollateralState {
        uint256 totalReserves;
        uint256 totalFeesToStakers;
    }

    error VaultDoesNotExist();

    bytes16 log2Point0001; // 1.0001 in IEEE-754 Quadruple Precision Floating Point Numbers

    MockERC20 private _collateralToken;
    address alice;
    Oracle oracle;

    mapping(address collateral => uint256) public totalReserves;
    mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => SirStructs.VaultState))) vaultStates;
    SirStructs.VaultParameters vaultParams;

    function setUp() public {
        log2Point0001 = ABDKMathQuad.fromUInt(10001).div(ABDKMathQuad.fromUInt(10000)).log_2();

        _collateralToken = new MockERC20("Collateral token", "TKN", 18);

        vaultParams = SirStructs.VaultParameters(Addresses.ADDR_USDC, address(_collateralToken), 0);

        alice = vm.addr(1);
        oracle = new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY);
    }

    function _preprocess(
        CollateralState memory collateralState,
        SirStructs.VaultState memory vaultState,
        int64 tickPriceX42
    ) internal {
        // Constraint reserve
        collateralState.totalReserves = _bound(collateralState.totalReserves, 0, type(uint144).max);
        vaultState.reserve = uint144(collateralState.totalReserves);
        collateralState.totalFeesToStakers = _bound(
            collateralState.totalFeesToStakers,
            0,
            type(uint256).max - collateralState.totalReserves
        );
        vm.assume(vaultState.reserve == 0 || vaultState.reserve >= 1e6); // Min reserve is always 1M (or 0 if no mint has occured)

        // Constraint vaultId
        vaultState.vaultId = uint48(_bound(vaultState.vaultId, 1, type(uint48).max));

        // Mint tokens
        _collateralToken.mint(address(this), collateralState.totalReserves + collateralState.totalFeesToStakers);

        // Save token state
        totalReserves[vaultParams.collateralToken] = collateralState.totalReserves;

        // Save vault state
        vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier] = vaultState;

        // Mock oracle
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(Oracle.getPrice.selector, vaultParams.collateralToken, vaultParams.debtToken),
            abi.encode(tickPriceX42)
        );
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(
                Oracle.updateOracleState.selector,
                vaultParams.collateralToken,
                vaultParams.debtToken
            ),
            abi.encode(tickPriceX42)
        );
    }

    function _assertUnchangedParameters(
        CollateralState memory collateralState,
        CollateralState memory collateralState_,
        SirStructs.VaultState memory vaultState,
        SirStructs.VaultState memory vaultState_
    ) private view {
        assertEq(
            collateralState_.totalReserves,
            collateralState.totalReserves,
            "totalReserves in collateralState do not match"
        );
        assertEq(
            collateralState_.totalFeesToStakers,
            collateralState.totalFeesToStakers,
            "totalFeesToStakers do not match"
        );
        assertEq(
            collateralState_.totalReserves,
            totalReserves[vaultParams.collateralToken],
            "totalReserves do not match"
        );

        assertEq(vaultState_.reserve, vaultState.reserve, "reserve do not match");
        assertEq(vaultState_.tickPriceSatX42, vaultState.tickPriceSatX42, "tickPriceSatX42 do not match");
        assertEq(vaultState_.vaultId, vaultState.vaultId, "vaultId do not match");
    }

    function testFuzz_getNoReserves(
        bool isAPE,
        uint256 totalFeesToStakers,
        SirStructs.VaultState memory vaultState,
        int64 tickPriceX42
    ) public {
        _preprocess(
            CollateralState({totalReserves: 0, totalFeesToStakers: totalFeesToStakers}),
            vaultState,
            tickPriceX42
        );

        vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier] = vaultState;

        (SirStructs.VaultState memory vaultState_, SirStructs.Reserves memory reserves, address ape) = VaultExternal
            .getReserves(isAPE, vaultStates, oracle, vaultParams);

        CollateralState memory collateralState_ = CollateralState({
            totalReserves: vaultState_.reserve,
            totalFeesToStakers: _collateralToken.balanceOf(address(this)) - totalReserves[vaultParams.collateralToken]
        });

        _assertUnchangedParameters(
            CollateralState({totalReserves: 0, totalFeesToStakers: totalFeesToStakers}),
            collateralState_,
            vaultState,
            vaultState_
        );

        assertTrue(isAPE ? ape != address(0) : ape == address(0));

        assertEq(reserves.reserveApes, 0);
        assertEq(reserves.reserveLPers, 0);
        assertEq(reserves.tickPriceX42, tickPriceX42);
    }

    function testFuzz_getReservesAllAPE(
        bool isAPE,
        CollateralState memory collateralState,
        SirStructs.VaultState memory vaultState,
        int64 tickPriceX42
    ) public {
        _preprocess(collateralState, vaultState, tickPriceX42);
        vm.assume(vaultState.reserve > 0);

        // type(int64).min represents -∞ => reserveLPers is empty
        vaultState.tickPriceSatX42 = type(int64).min;
        vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier] = vaultState;

        (SirStructs.VaultState memory vaultState_, SirStructs.Reserves memory reserves, address ape) = VaultExternal
            .getReserves(isAPE, vaultStates, oracle, vaultParams);

        CollateralState memory collateralState_ = CollateralState({
            totalReserves: vaultState_.reserve,
            totalFeesToStakers: _collateralToken.balanceOf(address(this)) - totalReserves[vaultParams.collateralToken]
        });

        _assertUnchangedParameters(collateralState, collateralState_, vaultState, vaultState_);

        assertTrue(isAPE ? ape != address(0) : ape == address(0));

        assertEq(reserves.reserveApes, vaultState.reserve - 1);
        assertEq(reserves.reserveLPers, 1);
        assertEq(reserves.tickPriceX42, tickPriceX42);
    }

    function testFuzz_getReservesAllTEA(
        bool isAPE,
        CollateralState memory collateralState,
        SirStructs.VaultState memory vaultState,
        int64 tickPriceX42
    ) public {
        _preprocess(collateralState, vaultState, tickPriceX42);
        vm.assume(vaultState.reserve > 0);

        // type(int64).max represents +∞ => reserveApes is empty
        vaultState.tickPriceSatX42 = type(int64).max;
        vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier] = vaultState;

        (SirStructs.VaultState memory vaultState_, SirStructs.Reserves memory reserves, address ape) = VaultExternal
            .getReserves(isAPE, vaultStates, oracle, vaultParams);

        CollateralState memory collateralState_ = CollateralState({
            totalReserves: vaultState_.reserve,
            totalFeesToStakers: _collateralToken.balanceOf(address(this)) - totalReserves[vaultParams.collateralToken]
        });

        _assertUnchangedParameters(collateralState, collateralState_, vaultState, vaultState_);

        assertTrue(isAPE ? ape != address(0) : ape == address(0));

        assertEq(reserves.reserveApes, 1);
        assertEq(reserves.reserveLPers, vaultState.reserve - 1);
        assertEq(reserves.tickPriceX42, tickPriceX42);
    }

    function testFuzz_getReserves(
        bool isAPE,
        CollateralState memory collateralState,
        SirStructs.VaultState memory vaultState,
        int64 tickPriceX42
    ) public {
        _preprocess(collateralState, vaultState, tickPriceX42);
        vm.assume(vaultState.reserve > 0);

        vaultState.tickPriceSatX42 = int64(
            _bound(vaultState.tickPriceSatX42, type(int64).min + 1, type(int64).max - 1)
        );
        vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier] = vaultState;

        (SirStructs.VaultState memory vaultState_, SirStructs.Reserves memory reserves, address ape) = VaultExternal
            .getReserves(isAPE, vaultStates, oracle, vaultParams);

        CollateralState memory collateralState_ = CollateralState({
            totalReserves: vaultState_.reserve,
            totalFeesToStakers: _collateralToken.balanceOf(address(this)) - totalReserves[vaultParams.collateralToken]
        });

        _assertUnchangedParameters(collateralState, collateralState_, vaultState, vaultState_);

        assertTrue(isAPE ? ape != address(0) : ape == address(0));

        (uint256 reserveApes, uint256 reserveLPers) = _getReservesWithFloatingPoint(
            vaultState,
            vaultParams.leverageTier,
            tickPriceX42
        );

        assertApproxEqAbs(reserves.reserveApes, reserveApes, 2 + vaultState.reserve / 1e16); // We found this is our accuracy by numerical experimentation
        assertApproxEqAbs(reserves.reserveLPers, reserveLPers, 2 + vaultState.reserve / 1e16);
        assertEq(reserves.tickPriceX42, tickPriceX42);
    }

    function testFuzz_getReservesVaultDoesNotExist(
        bool isAPE,
        CollateralState memory collateralState,
        SirStructs.VaultState memory vaultState,
        int64 tickPriceX42
    ) public {
        _preprocess(collateralState, vaultState, tickPriceX42);

        vaultState.vaultId = 0;
        vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier] = vaultState;

        vm.expectRevert(VaultDoesNotExist.selector);
        VaultExternal.getReserves(isAPE, vaultStates, oracle, vaultParams);
    }

    function _getReservesWithFloatingPoint(
        SirStructs.VaultState memory vaultState,
        int8 leverageTier,
        int64 tickPriceX42
    ) private view returns (uint144 reserveApes, uint144 reserveLPers) {
        bytes16 tickPriceFP = ABDKMathQuad.fromInt(tickPriceX42).div(ABDKMathQuad.fromUInt(2 ** 42));
        bytes16 tickPriceSatFP = ABDKMathQuad.fromInt(vaultState.tickPriceSatX42).div(ABDKMathQuad.fromUInt(2 ** 42));
        bytes16 totalReservesFP = ABDKMathQuad.fromUInt(vaultState.reserve);

        if (tickPriceX42 < vaultState.tickPriceSatX42) {
            bytes16 leverageRatioFP = ABDKMathQuad.fromInt(leverageTier).pow_2().add(ABDKMathQuad.fromUInt(1));

            reserveApes = uint144(
                tickPriceFP
                    .sub(tickPriceSatFP)
                    .mul(log2Point0001)
                    .mul(leverageRatioFP.sub(ABDKMathQuad.fromUInt(1)))
                    .pow_2()
                    .mul(totalReservesFP)
                    .div(leverageRatioFP)
                    .toUInt()
            );
            reserveLPers = vaultState.reserve - reserveApes;
        } else {
            bytes16 collateralizationRatioFP = ABDKMathQuad.fromInt(-leverageTier).pow_2().add(
                ABDKMathQuad.fromUInt(1)
            );

            reserveLPers = uint144(
                tickPriceSatFP
                    .sub(tickPriceFP)
                    .mul(log2Point0001)
                    .pow_2()
                    .mul(totalReservesFP)
                    .div(collateralizationRatioFP)
                    .toUInt()
            );
            reserveApes = vaultState.reserve - reserveLPers;
        }
    }
}
