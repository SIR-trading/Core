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

    VaultStructs.VaultParameters[] paramsById;

    mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => VaultStructs.VaultState)))
        public vaultState; // Do not use vaultId 0
    VaultStructs.TokenParameters transientTokenParameters;
    uint48 constant VAULT_ID = 9;
    uint48 vaultId;
    address alice;

    Oracle oracle;

    function latestTokenParams()
        external
        view
        returns (VaultStructs.TokenParameters memory, VaultStructs.VaultParameters memory)
    {
        return (transientTokenParameters, paramsById[paramsById.length - 1]);
    }

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);

        // Expand array to VAULT_ID elements
        for (vaultId = 0; vaultId < VAULT_ID; vaultId++) {
            paramsById.push(VaultStructs.VaultParameters(address(0), address(0), 0));
        }

        // Deployr oracle
        oracle = new Oracle();

        alice = vm.addr(1);
    }

    function testFuzz_deployETHvsUSDC(int8 leverageTier) public {
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MIN_LEVERAGE_TIER)); // Only accepted values in the system

        vm.expectEmit();
        emit VaultInitialized(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier, vaultId);
        VaultExternal.deployAPE(
            oracle,
            vaultState[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            transientTokenParameters,
            VaultStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDC,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: leverageTier
            })
        );

        APE ape = APE(SaltedAddress.getAddress(address(this), vaultId));
        assertGt(address(ape).code.length, 0);

        assertEq(ape.symbol(), string.concat("APE-", Strings.toString(vaultId)));
        assertEq(ape.decimals(), 18);
        assertEq(ape.debtToken(), Addresses.ADDR_USDC);
        assertEq(ape.collateralToken(), Addresses.ADDR_WETH);
        assertEq(ape.leverageTier(), leverageTier);

        VaultStructs.VaultParameters memory params = paramsById[vaultId];
        assertEq(params.debtToken, Addresses.ADDR_USDC);
        assertEq(params.collateralToken, Addresses.ADDR_WETH);
        assertEq(params.leverageTier, leverageTier);
    }

    function testFuzz_deployWrongTokens(address debtToken, address collateralToken, int8 leverageTier) public {
        leverageTier = int8(_bound(leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MIN_LEVERAGE_TIER)); // Only accepted values in the system

        vm.expectRevert(abi.encodeWithSelector(NoFeeTiers.selector));
        VaultExternal.deployAPE(
            oracle,
            vaultState[debtToken][collateralToken][leverageTier],
            paramsById,
            transientTokenParameters,
            VaultStructs.VaultParameters(debtToken, collateralToken, leverageTier)
        );
    }

    function testFuzz_deployETHvsUSDCWrongLeverage(int8 leverageTier) public {
        vm.assume(leverageTier < -3 || leverageTier > 2); // Non accepted values in the system

        vm.expectRevert(abi.encodeWithSelector(LeverageTierOutOfRange.selector));
        VaultExternal.deployAPE(
            oracle,
            vaultState[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            transientTokenParameters,
            VaultStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDC,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: leverageTier
            })
        );
    }

    function test_deployMaxNumberOfVaultsPerTokenTuple() public returns (int8 leverageTier) {
        leverageTier = -3;
        for (; vaultId < VAULT_ID + 6; vaultId++) {
            vm.expectEmit();
            emit VaultInitialized(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier, vaultId);
            VaultExternal.deployAPE(
                oracle,
                vaultState[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
                paramsById,
                transientTokenParameters,
                VaultStructs.VaultParameters({
                    debtToken: Addresses.ADDR_USDC,
                    collateralToken: Addresses.ADDR_WETH,
                    leverageTier: leverageTier
                })
            );

            APE ape = APE(SaltedAddress.getAddress(address(this), vaultId));
            assertGt(address(ape).code.length, 0);

            assertEq(ape.symbol(), string.concat("APE-", Strings.toString(vaultId)));
            assertEq(ape.decimals(), 18);
            assertEq(ape.debtToken(), Addresses.ADDR_USDC);
            assertEq(ape.collateralToken(), Addresses.ADDR_WETH);
            assertEq(ape.leverageTier(), leverageTier);

            VaultStructs.VaultParameters memory params = paramsById[vaultId];
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
            vaultState[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            transientTokenParameters,
            VaultStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDC,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: leverageTier
            })
        );

        leverageTier--;
        vm.expectRevert(abi.encodeWithSelector(VaultAlreadyInitialized.selector));
        VaultExternal.deployAPE(
            oracle,
            vaultState[Addresses.ADDR_USDC][Addresses.ADDR_WETH][leverageTier],
            paramsById,
            transientTokenParameters,
            VaultStructs.VaultParameters({
                debtToken: Addresses.ADDR_USDC,
                collateralToken: Addresses.ADDR_WETH,
                leverageTier: leverageTier
            })
        );
    }

    function testFuzz_teaURI(uint vaultId_, int8 leverageTier_, uint256 totalSupply_) public {
        vaultId_ = _bound(vaultId_, 1, VAULT_ID - 1);
        leverageTier_ = int8(_bound(leverageTier_, -3, 2)); // Only accepted values in the system

        paramsById[vaultId_] = VaultStructs.VaultParameters(Addresses.ADDR_USDC, Addresses.ADDR_WETH, leverageTier_);

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

    error VaultDoesNotExist();

    struct TestParameters {
        uint144 collateralDeposited;
        int64 tickPriceX42;
    }

    bytes16 log2Point0001; // 1.0001 in IEEE-754 Quadruple Precision Floating Point Numbers

    MockERC20 private _collateralToken;
    address alice;
    Oracle oracle;

    mapping(address collateral => VaultStructs.TokenState) tokenStates;
    mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => VaultStructs.VaultState))) vaultStates;
    VaultStructs.VaultParameters vaultParams;

    function setUp() public {
        log2Point0001 = ABDKMathQuad.fromUInt(10001).div(ABDKMathQuad.fromUInt(10000)).log_2();

        _collateralToken = new MockERC20("Collateral token", "TKN", 18);

        vaultParams = VaultStructs.VaultParameters(Addresses.ADDR_USDC, address(_collateralToken), 0);

        alice = vm.addr(1);
        oracle = new Oracle();
    }

    modifier preprocess(
        VaultStructs.TokenState memory tokenState,
        VaultStructs.VaultState memory vaultState,
        TestParameters memory testParams // uint144 collateralDeposited, // int64 newTickPriceX42
    ) {
        // Constraint reserve
        vaultState.reserve = uint144(_bound(vaultState.reserve, 0, tokenState.total));

        // // Constraint collateralTotalSupply
        // collateralTotalSupply = _bound(collateralTotalSupply, tokenState.total, type(uint256).max);

        // Constraint collateralDeposited
        testParams.collateralDeposited = uint144(
            _bound(testParams.collateralDeposited, 0, type(uint144).max - tokenState.total)
        );

        // // Constraint leverageTier
        // vaultParams.leverageTier = int8(
        //     _bound(vaultParams.leverageTier, SystemConstants.MIN_LEVERAGE_TIER, SystemConstants.MIN_LEVERAGE_TIER)
        // ); // Only accepted values in the system

        // Constraint vaultId
        vaultState.vaultId = uint48(_bound(vaultState.vaultId, 1, type(uint48).max));

        // Mint tokens
        _collateralToken.mint(alice, type(uint256).max - tokenState.total - testParams.collateralDeposited);
        _collateralToken.mint(address(this), uint256(tokenState.total) + testParams.collateralDeposited);

        // Save token state
        tokenStates[vaultParams.collateralToken] = tokenState;

        // Save vault state
        vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier] = vaultState;

        // Mock oracle
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(Oracle.getPrice.selector, vaultParams.collateralToken, vaultParams.debtToken),
            abi.encode(testParams.tickPriceX42)
        );
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(
                Oracle.updateOracleState.selector,
                vaultParams.collateralToken,
                vaultParams.debtToken
            ),
            abi.encode(testParams.tickPriceX42)
        );

        _;
    }

    function _assertUnchangedParameters(
        VaultStructs.TokenState memory tokenState,
        VaultStructs.TokenState memory tokenState_,
        VaultStructs.VaultState memory vaultState,
        VaultStructs.VaultState memory vaultState_
    ) private {
        assertEq(tokenState_.total, tokenState.total);
        assertEq(tokenState_.collectedFees, tokenState.collectedFees);

        assertEq(vaultState_.reserve, vaultState.reserve);
        assertEq(vaultState_.tickPriceSatX42, vaultState.tickPriceSatX42);
        assertEq(vaultState_.vaultId, vaultState.vaultId);
    }

    function testFuzz_getReservesNoReserves(
        bool isMint,
        bool isAPE,
        VaultStructs.TokenState memory tokenState,
        VaultStructs.VaultState memory vaultState,
        TestParameters memory testParams
    ) public preprocess(tokenState, vaultState, testParams) {
        // No collateral in the vault
        vaultState.reserve = 0;
        vaultStates[vaultParams.debtToken][vaultParams.collateralToken][vaultParams.leverageTier] = vaultState;

        (
            VaultStructs.TokenState memory tokenState_,
            VaultStructs.VaultState memory vaultState_,
            VaultStructs.Reserves memory reserves,
            APE ape,
            uint144 collateralDeposited_
        ) = VaultExternal.getReserves(isMint, isAPE, tokenStates, vaultStates, oracle, vaultParams);

        _assertUnchangedParameters(tokenState, tokenState_, vaultState, vaultState_);

        assertTrue(isAPE ? address(ape) != address(0) : address(ape) == address(0));
        // assertTrue(address(ape) != address(0));

        assertEq(reserves.reserveApes, 0);
        assertEq(reserves.reserveLPers, 0);
        assertEq(reserves.tickPriceX42, testParams.tickPriceX42);

        assertEq(collateralDeposited_, isMint ? testParams.collateralDeposited : 0);
        // assertEq(collateralDeposited_, testParams.collateralDeposited);
    }

    // function testFuzz_getReservesReserveAllAPE(
    //     bool isMint,
    //     bool isAPE,
    //     int8 leverageTier,
    //     uint144 collateralDeposited,
    //     uint256 collateralTotalSupply,
    //     VaultStructs.VaultState memory vaultState,
    //     int64 tickPriceX42
    // ) public {
    //     vaultParams.leverageTier = int8(_bound(vaultParams.leverageTier,SystemConstants.MIN_LEVERAGE_TIER,SystemConstants.MIN_LEVERAGE_TIER)); // Only accepted values in the system

    //     vaultState.reserve = uint144(_bound(vaultState.reserve, 2, type(uint144).max)); // Min reserve is always 2 (or 0 if no minted has occured)
    //     collateralDeposited = uint144(_bound(collateralDeposited, 0, type(uint144).max - vaultState.reserve));

    //     collateralTotalSupply = _bound(
    //         collateralTotalSupply,
    //         vaultState.reserve,
    //         type(uint256).max - collateralDeposited
    //     );

    //     // Mint tokens
    //     _collateralToken.mint(alice, collateralTotalSupply - vaultState.reserve);
    //     _collateralToken.mint(address(this), vaultState.reserve + collateralDeposited);

    //     // type(int64).min represents -∞ => reserveLPers is empty
    //     vaultState.tickPriceSatX42 = type(int64).min;

    //     (VaultStructs.Reserves memory reserves, APE ape, uint144 collateralDeposited_) = VaultExternal.getReserves(
    //         isMint,
    //         isAPE,
    //         vaultState,
    //         address(_collateralToken),
    //         vaultParams.leverageTier,
    //         tickPriceX42
    //     );

    //     assertEq(reserves.reserveApes, vaultState.reserve - 1);
    //     assertEq(reserves.reserveLPers, 1);
    //     assertTrue(isAPE ? address(ape) != address(0) : address(ape) == address(0));
    //     assertEq(collateralDeposited_, isMint ? collateralDeposited : 0);
    // }

    // function testFuzz_getReservesReserveAllTEA(
    //     bool isMint,
    //     bool isAPE,
    //     int8 leverageTier,
    //     uint144 collateralDeposited,
    //     uint256 collateralTotalSupply,
    //     VaultStructs.VaultState memory vaultState
    // ) public {
    //     vaultParams.leverageTier = int8(_bound(vaultParams.leverageTier,SystemConstants.MIN_LEVERAGE_TIER,SystemConstants.MIN_LEVERAGE_TIER)); // Only accepted values in the system

    //     vaultState.reserve = uint144(_bound(vaultState.reserve, 2, type(uint144).max)); // Min reserve is always 2 (or 0 if no minted has occured)
    //     collateralDeposited = uint144(_bound(collateralDeposited, 0, type(uint144).max - vaultState.reserve));

    //     collateralTotalSupply = _bound(
    //         collateralTotalSupply,
    //         vaultState.reserve,
    //         type(uint256).max - collateralDeposited
    //     );

    //     // Mint tokens
    //     _collateralToken.mint(alice, collateralTotalSupply - vaultState.reserve);
    //     _collateralToken.mint(address(this), vaultState.reserve + collateralDeposited);

    //     // type(int64).max represents +∞ => reserveApes is empty
    //     vaultState.tickPriceSatX42 = type(int64).max;

    //     (VaultStructs.Reserves memory reserves, APE ape, uint144 collateralDeposited_) = VaultExternal.getReserves(
    //         isMint,
    //         isAPE,
    //         vaultState,
    //         address(_collateralToken),
    //         vaultParams.leverageTier
    //     );

    //     assertEq(reserves.reserveApes, 1);
    //     assertEq(reserves.reserveLPers, vaultState.reserve - 1);
    //     assertTrue(isAPE ? address(ape) != address(0) : address(ape) == address(0));
    //     assertEq(collateralDeposited_, isMint ? collateralDeposited : 0);
    // }

    // function testFuzz_getReserves(
    //     bool isMint,
    //     bool isAPE,
    //     int8 leverageTier,
    //     uint144 collateralDeposited,
    //     uint256 collateralTotalSupply,
    //     VaultStructs.VaultState memory vaultState,
    //     int64 tickPriceX42
    // ) public {
    //     vaultParams.leverageTier = int8(_bound(vaultParams.leverageTier,SystemConstants.MIN_LEVERAGE_TIER,SystemConstants.MIN_LEVERAGE_TIER)); // Only accepted values in the system

    //     vaultState.reserve = uint144(_bound(vaultState.reserve, 2, type(uint144).max)); // Min reserve is always 2 (or 0 if no minted has occured)
    //     collateralDeposited = uint144(_bound(collateralDeposited, 0, type(uint144).max - vaultState.reserve));

    //     collateralTotalSupply = _bound(
    //         collateralTotalSupply,
    //         vaultState.reserve,
    //         type(uint256).max - collateralDeposited
    //     );

    //     vaultState.tickPriceSatX42 = int64(
    //         _bound(vaultState.tickPriceSatX42, type(int64).min + 1, type(int64).max - 1)
    //     );

    //     // Mint tokens
    //     _collateralToken.mint(alice, collateralTotalSupply - vaultState.reserve);
    //     _collateralToken.mint(address(this), vaultState.reserve + collateralDeposited);

    //     (VaultStructs.Reserves memory reserves, APE ape, uint144 collateralDeposited_) = VaultExternal.getReserves(
    //         isMint,
    //         isAPE,
    //         vaultState,
    //         address(_collateralToken),
    //         vaultParams.leverageTier,
    //         tickPriceX42
    //     );

    //     (uint256 reserveApes, uint256 reserveLPers) = _getReservesWithFloatingPoint(
    //         vaultParams.leverageTier,
    //         vaultState
    //     );

    //     assertApproxEqAbs(reserves.reserveApes, reserveApes, 2 + vaultState.reserve / 1e16); // We found this is our accuracy by numerical experimentation
    //     assertApproxEqAbs(reserves.reserveLPers, reserveLPers, 2 + vaultState.reserve / 1e16);
    //     assertTrue(isAPE ? address(ape) != address(0) : address(ape) == address(0));
    //     assertEq(collateralDeposited_, isMint ? collateralDeposited : 0);
    // }

    // function testFuzz_getReservesTooLargeDeposit(
    //     bool isAPE,
    //     int8 leverageTier,
    //     uint256 collateralDeposited,
    //     uint256 collateralTotalSupply,
    //     VaultStructs.VaultState memory vaultState
    // ) public {
    //     vaultParams.leverageTier = int8(_bound(vaultParams.leverageTier,SystemConstants.MIN_LEVERAGE_TIER,SystemConstants.MIN_LEVERAGE_TIER)); // Only accepted values in the system

    //     vaultState.reserve = uint144(_bound(vaultState.reserve, 2, type(uint144).max)); // Min reserve is always 2 (or 0 if no minted has occured)
    //     collateralTotalSupply = _bound(
    //         collateralTotalSupply,
    //         vaultState.reserve,
    //         type(uint256).max - type(uint144).max + vaultState.reserve - 1
    //     );
    //     collateralDeposited = _bound(
    //         collateralDeposited,
    //         type(uint144).max - vaultState.reserve + 1,
    //         type(uint256).max - collateralTotalSupply
    //     );

    //     // Mint tokens
    //     _collateralToken.mint(alice, collateralTotalSupply - vaultState.reserve);
    //     _collateralToken.mint(address(this), vaultState.reserve + collateralDeposited);

    //     vm.expectRevert();
    //     VaultExternal.getReserves(true, isAPE, vaultState, address(_collateralToken), vaultParams.leverageTier);
    // }

    // function _getReservesWithFloatingPoint(
    //     int8 leverageTier,
    //     VaultStructs.VaultState memory vaultState
    // ) private view returns (uint144 reserveApes, uint144 reserveLPers) {
    //     bytes16 tickPriceFP = ABDKMathQuad.fromInt(vaultState.tickPriceX42).div(ABDKMathQuad.fromUInt(2 ** 42));
    //     bytes16 tickPriceSatFP = ABDKMathQuad.fromInt(vaultState.tickPriceSatX42).div(ABDKMathQuad.fromUInt(2 ** 42));
    //     bytes16 totalReservesFP = ABDKMathQuad.fromUInt(vaultState.reserve);

    //     if (vaultState.tickPriceX42 < vaultState.tickPriceSatX42) {
    //         bytes16 leverageRatioFP = ABDKMathQuad.fromInt(leverageTier).pow_2().add(ABDKMathQuad.fromUInt(1));

    //         reserveApes = uint144(
    //             tickPriceFP
    //                 .sub(tickPriceSatFP)
    //                 .mul(log2Point0001)
    //                 .mul(leverageRatioFP.sub(ABDKMathQuad.fromUInt(1)))
    //                 .pow_2()
    //                 .mul(totalReservesFP)
    //                 .div(leverageRatioFP)
    //                 .toUInt()
    //         );
    //         reserveLPers = vaultState.reserve - reserveApes;
    //     } else {
    //         bytes16 collateralizationRatioFP = ABDKMathQuad.fromInt(-leverageTier).pow_2().add(
    //             ABDKMathQuad.fromUInt(1)
    //         );

    //         reserveLPers = uint144(
    //             tickPriceSatFP
    //                 .sub(tickPriceFP)
    //                 .mul(log2Point0001)
    //                 .pow_2()
    //                 .mul(totalReservesFP)
    //                 .div(collateralizationRatioFP)
    //                 .toUInt()
    //         );
    //         reserveApes = vaultState.reserve - reserveLPers;
    //     }
    // }
}

// function getReserves(
//     bool isMint,
//     bool isAPE,
//     mapping(address collateral => VaultStructs.TokenState) storage tokenStates_,
//     mapping(address debtToken => mapping(address collateralToken => mapping(int8 leverageTier => VaultStructs.VaultState)))
//         storage vaultStates_,
//     Oracle oracle_,
//     VaultStructs.VaultParameters memory vaultParams_
// )
//     internal
//     returns (
//         VaultStructs.TokenState memory tokenState,
//         VaultStructs.VaultState memory vaultState,
//         VaultStructs.Reserves memory reserves,
//         APE ape,
//         uint144 collateralDeposited
//     )
// {
//     unchecked {
//         tokenState = tokenStates_[vaultParams_.collateralToken];
//         vaultState = vaultStates_[vaultParams_.debtToken][vaultParams_.collateralToken][vaultParams_.leverageTier];

//         // Get price and update oracle state if needed
//         reserves.tickPriceX42 = oracle_.updateOracleState(vaultParams_.collateralToken, vaultParams_.debtToken);

//         // Derive APE address if needed
//         if (isAPE) ape = APE(SaltedAddress.getAddress(address(this), vaultState.vaultId));

//         _getReserves(vaultState, reserves, vaultParams_.leverageTier);

//         if (isMint) {
//             // Get deposited collateral
//             uint256 balance = APE(vaultParams_.collateralToken).balanceOf(address(this)); // collateralToken is not an APE token, but it shares the balanceOf method
//             require(balance <= type(uint144).max); // Ensure it fits in a uint144
//             collateralDeposited = uint144(balance - tokenState.total);
//         }
//     }
// }

// function _getReserves(
//     VaultStructs.VaultState memory vaultState,
//     VaultStructs.Reserves memory reserves,
//     int8 leverageTier
// ) private view {
//     unchecked {
//         if (vaultState.vaultId == 0) revert VaultDoesNotExist();

//         // Reserve is empty only in the 1st mint
//         if (vaultState.reserve != 0) {
//             assert(vaultState.reserve >= 2);

//             if (vaultState.tickPriceSatX42 == type(int64).min) {
//                 // type(int64).min represents -∞ => reserveLPers = 0
//                 reserves.reserveApes = vaultState.reserve - 1;
//                 reserves.reserveLPers = 1;
//             } else if (vaultState.tickPriceSatX42 == type(int64).max) {
//                 // type(int64).max represents +∞ => reserveApes = 0
//                 reserves.reserveApes = 1;
//                 reserves.reserveLPers = vaultState.reserve - 1;
//             } else {
//                 uint8 absLeverageTier = leverageTier >= 0 ? uint8(leverageTier) : uint8(-leverageTier);

//                 if (reserves.tickPriceX42 < vaultState.tickPriceSatX42) {
//                     /**
//                      * POWER ZONE
//                      * A = (price/priceSat)^(l-1) R/l
//                      * price = 1.0001^tickPriceX42 and priceSat = 1.0001^tickPriceSatX42
//                      * We use the fact that l = 1+2^leverageTier
//                      * reserveApes is rounded up
//                      */
//                     int256 poweredTickPriceDiffX42 = leverageTier > 0
//                         ? (int256(vaultState.tickPriceSatX42) - reserves.tickPriceX42) << absLeverageTier
//                         : (int256(vaultState.tickPriceSatX42) - reserves.tickPriceX42) >> absLeverageTier;

//                     if (poweredTickPriceDiffX42 > SystemConstants.MAX_TICK_X42) {
//                         reserves.reserveApes = 1;
//                     } else {
//                         /** Rounds up reserveApes, rounds down reserveLPers.
//                             Cannot overflow.
//                             64 bits because getRatioAtTick returns a Q64.64 number.
//                         */
//                         uint256 poweredPriceRatioX64 = TickMathPrecision.getRatioAtTick(
//                             int64(poweredTickPriceDiffX42)
//                         );

//                         reserves.reserveApes = uint144(
//                             _divRoundUp(
//                                 uint256(vaultState.reserve) << (leverageTier >= 0 ? 64 : 64 + absLeverageTier),
//                                 poweredPriceRatioX64 + (poweredPriceRatioX64 << absLeverageTier)
//                             )
//                         );

//                         assert(reserves.reserveApes != 0); // It should never be 0 because it's rounded up. Important for the protocol that it is at least 1.
//                     }

//                     reserves.reserveLPers = vaultState.reserve - reserves.reserveApes;
//                 } else {
//                     /**
//                      * SATURATION ZONE
//                      * LPers are 100% pegged to debt token.
//                      * L = (priceSat/price) R/r
//                      * price = 1.0001^tickPriceX42 and priceSat = 1.0001^tickPriceSatX42
//                      * We use the fact that lr = 1+2^-leverageTier
//                      * reserveLPers is rounded up
//                      */
//                     int256 tickPriceDiffX42 = int256(reserves.tickPriceX42) - vaultState.tickPriceSatX42;

//                     if (tickPriceDiffX42 > SystemConstants.MAX_TICK_X42) {
//                         reserves.reserveLPers = 1;
//                     } else {
//                         /** Rounds up reserveLPers, rounds down reserveApes.
//                             Cannot overflow.
//                             64 bits because getRatioAtTick returns a Q64.64 number.
//                         */
//                         uint256 priceRatioX64 = TickMathPrecision.getRatioAtTick(int64(tickPriceDiffX42));

//                         reserves.reserveLPers = uint144(
//                             _divRoundUp(
//                                 uint256(vaultState.reserve) << (leverageTier < 0 ? 64 : 64 + absLeverageTier),
//                                 priceRatioX64 + (priceRatioX64 << absLeverageTier)
//                             )
//                         );

//                         assert(reserves.reserveLPers != 0); // It should never be 0 because it's rounded up. Important for the protocol that it is at least 1.
//                     }

//                     reserves.reserveApes = vaultState.reserve - reserves.reserveLPers;
//                 }
//             }
//         }
//     }
// }

// function _divRoundUp(uint256 a, uint256 b) private pure returns (uint256) {
//     unchecked {
//         return (a - 1) / b + 1;
//     }
// }
