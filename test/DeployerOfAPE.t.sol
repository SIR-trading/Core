// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {DeployerOfAPE, VaultStructs, Strings} from "src/libraries/DeployerOfAPE.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SaltedAddress} from "src/libraries/SaltedAddress.sol";
import {IERC20} from "v2-core/interfaces/IERC20.sol";

contract MockCaller {
    address private _debtToken;
    address private _collateralToken;
    int8 private _leverageTier;

    constructor(address debtToken_, address collateralToken_, int8 leverageTier_) {
        _debtToken = debtToken_;
        _collateralToken = collateralToken_;
        _leverageTier = leverageTier_;
    }

    VaultStructs.TokenParameters private _transientTokenParameters;

    function latestTokenParams()
        external
        view
        returns (
            string memory name,
            string memory symbol,
            uint8 decimals,
            address debtToken_,
            address collateralToken_,
            int8 leverageTier_
        )
    {
        name = _transientTokenParameters.name;
        symbol = _transientTokenParameters.symbol;
        decimals = _transientTokenParameters.decimals;

        debtToken_ = _debtToken;
        collateralToken_ = _collateralToken;
        leverageTier_ = _leverageTier;
    }

    function deploy(uint40 vaultId, int8 leverageTier) external {
        DeployerOfAPE.deploy(
            _transientTokenParameters,
            vaultId,
            Addresses._ADDR_USDC,
            Addresses._ADDR_WETH,
            leverageTier
        );
    }

    function getApeAddress(uint40 vaultId) external view returns (address) {
        return SaltedAddress.getAddress(vaultId);
    }
}

contract DeployerOfAPETest is Test {
    event VaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 vaultId
    );

    function setUp() public {
        vm.createSelectFork("mainnet", 18128102);
    }

    function test_deployETHvsUSDC() public {
        uint40 vaultId = 42;
        int8 leverageTier = -2;

        MockCaller mockCaller = new MockCaller(Addresses._ADDR_USDC, Addresses._ADDR_WETH, leverageTier);

        vm.expectEmit();
        emit VaultInitialized(Addresses._ADDR_USDC, Addresses._ADDR_WETH, leverageTier, vaultId);
        mockCaller.deploy(vaultId, leverageTier);

        vm.prank(address(mockCaller));
        address ape = mockCaller.getApeAddress(vaultId);
        assertGt(ape.code.length, 0);

        assertEq(IERC20(ape).name(), "Tokenized WETH/USDC with x1.25 leverage");
        assertEq(IERC20(ape).symbol(), "APE-42");
        assertEq(IERC20(ape).decimals(), 18);
    }

    // function testFuzz_deployETHvsUSDC(uint40 vaultId, int8 leverageTier) public {
    //     vm.assume(vaultId > 0);
    //     leverageTier = int8(bound(leverageTier, -3, 2)); // Only accepted values in the system

    //     vm.mockCall(
    //         address(this),
    //         abi.encodeWithSelector(IVault.latestTokenParams.selector),
    //         abi.encode(
    //             _transientTokenParameters.name,
    //             _transientTokenParameters.symbol,
    //             _transientTokenParameters.decimals,
    //             Addresses._ADDR_USDC,
    //             Addresses._ADDR_WETH,
    //             leverageTier
    //         )
    //     );

    //     vm.expectEmit();
    //     emit VaultInitialized(Addresses._ADDR_USDC, Addresses._ADDR_WETH, leverageTier, vaultId);
    //     DeployerOfAPE.deploy(
    //         _transientTokenParameters,
    //         vaultId,
    //         Addresses._ADDR_USDC,
    //         Addresses._ADDR_WETH,
    //         leverageTier
    //     );

    //     address ape = SaltedAddress.getAddress(vaultId);
    //     assertGt(ape.code.length, 0);

    //     assertEq(IERC20(ape).symbol(), string.concat("APE-", Strings.toString(vaultId)));
    //     assertEq(IERC20(ape).decimals(), IERC20(Addresses._ADDR_WETH).decimals());
    // }

    // function testFuzz_deployUSDCvsALUSD(uint40 vaultId, int8 leverageTier) public {
    //     vm.assume(vaultId > 0);
    //     leverageTier = int8(bound(leverageTier, -3, 2)); // Only accepted values in the system

    //     vm.mockCall(
    //         address(this),
    //         abi.encodeWithSelector(IVault.latestTokenParams.selector),
    //         abi.encode(
    //             _transientTokenParameters.name,
    //             _transientTokenParameters.symbol,
    //             _transientTokenParameters.decimals,
    //             Addresses._ADDR_ALUSD,
    //             Addresses._ADDR_USDC,
    //             leverageTier
    //         )
    //     );

    //     vm.expectEmit();
    //     emit VaultInitialized(Addresses._ADDR_ALUSD, Addresses._ADDR_USDC, leverageTier, vaultId);
    //     DeployerOfAPE.deploy(
    //         _transientTokenParameters,
    //         vaultId,
    //         Addresses._ADDR_ALUSD,
    //         Addresses._ADDR_USDC,
    //         leverageTier
    //     );

    //     address ape = SaltedAddress.getAddress(vaultId);
    //     assertGt(ape.code.length, 0);

    //     assertEq(IERC20(ape).symbol(), string.concat("APE-", Strings.toString(vaultId)));
    //     assertEq(IERC20(ape).decimals(), IERC20(Addresses._ADDR_USDC).decimals());
    // }
}
