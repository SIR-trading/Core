// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {Oracle} from "./Oracle.sol";
import {VaultStructs} from "./interfaces/VaultStructs.sol";

// Libraries
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {DeployerOfTokens} from "./libraries/DeployerOfTokens.sol";

// Contracts
import {MAAM} from "./MAAM.sol";

/**
 * @dev Floating point (FP) numbers are necessary for rebasing balances of LP (MAAM tokens).
 *  @dev The price of the collateral vs rewards token is also represented as FP.
 *  @dev THE RULE is that rounding should be applied so that an equal or smaller amount is owed. In this way the protocol will never owe more than it controls.
 *  @dev price's range is [0,Infinity], where Infinity is included.
 *  @dev TEA's supply cannot exceed type(uint).max because of its mint() function.
 */
contract Vault is MAAM, VaultStructs {
    using FloatingPoint for bytes16;

    event vaultInitialized(
        address indexed debtToken,
        address indexed collateralToken,
        int8 indexed leverageTier,
        uint256 indexed vaultId
    );

    Oracle public immutable ORACLE;

    mapping(VaultStructs.Parameters => VaultStructs.State) public state;

    constructor(address vaultLogic, address oracle) MAAM(vaultLogic) {
        // Price oracle
        ORACLE = Oracle(oracle);
    }

    /**
        Initialization is always necessary because we must deploy TEA and APE contracts, and possibly initialize the Oracle.
        If I require initialization, the vaultId can be chosen sequentially,
        and stored in the state by squeezing out some bytes from the other state variables.
        Potentially we can have custom list of salts to allow for 7ea and a9e addresses.
     */
    function initialize(address debtToken, address collateralToken, int8 leverageTier) external {}

    /*////////////////////////////////////////////////////////////////
                            MINT/BURN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Upon transfering collateral to the contract, the minter must call this function atomically to mint the corresponding amount of TEA.
     *     @return the minted amount of TEA
     *     @dev All view functions are outsourced to _VAULT_LOGIC
     */
    function mintTEA() external returns (uint256) {
        // Get price and update ORACLE if necessary
        bytes16 price = ORACLE.updatePriceMemory(_COLLATERAL_TOKEN);

        VaultStructs.State memory state_ = state;
        (VaultStructs.Reserves memory reservesPre, uint256 amountTEA, uint256 feeToPOL) = _VAULT_LOGIC.quoteMint(
            state_,
            _LEVERAGE_TIER,
            price,
            _TEA_TOKEN.totalSupply(),
            _COLLATERAL_TOKEN,
            true
        );

        // Liquidate gentlemen if necessary
        if (reservesPre.gentlemenReserve == 0) _TEA_TOKEN.liquidate();

        // Mints
        _TEA_TOKEN.mint(msg.sender, amountTEA); // Mint TEA
        if (feeToPOL > 0) _mint(address(this), feeToPOL, reservesPre.lpReserve); // Mint POL

        // Store new state reserves
        state = state_;

        return amountTEA;
    }

    function mintAPE() external returns (uint256) {
        // Get price and update ORACLE if necessary
        bytes16 price = ORACLE.updatePriceMemory(_COLLATERAL_TOKEN);

        VaultStructs.State memory state_ = state;
        (VaultStructs.Reserves memory reservesPre, uint256 amountAPE, uint256 feeToPOL) = _VAULT_LOGIC.quoteMint(
            state_,
            _LEVERAGE_TIER,
            price,
            _APE_TOKEN.totalSupply(),
            _COLLATERAL_TOKEN,
            false
        );

        // Liquidate apes if necessary
        if (reservesPre.apesReserve == 0) _APE_TOKEN.liquidate();

        // Mints
        _APE_TOKEN.mint(msg.sender, amountAPE); // Mint TEA
        if (feeToPOL > 0) _mint(address(this), feeToPOL, reservesPre.lpReserve); // Mint POL

        // Store new state reserves
        state = state_;

        return amountAPE;
    }

    /**
     * @notice Users call burn() to burn their TEA in exchange for hard cold collateral
     *     @param amountTEA is the amount of TEA the gentleman wishes to burn
     */
    function burnTEA(uint256 amountTEA) external returns (uint256) {
        // Get price and update ORACLE if necessary
        bytes16 price = ORACLE.updatePriceMemory(_COLLATERAL_TOKEN);

        VaultStructs.State memory state_ = state;
        (VaultStructs.Reserves memory reservesPre, uint256 collateralWithdrawn, uint256 feeToPOL) = _VAULT_LOGIC
            .quoteBurn(state_, _LEVERAGE_TIER, price, _TEA_TOKEN.totalSupply(), amountTEA, true);

        // Burn TEA, mint POL?
        _TEA_TOKEN.burn(msg.sender, amountTEA);
        if (feeToPOL > 0) _mint(address(this), feeToPOL, reservesPre.lpReserve); // Mint POL

        // Store new state reserves
        state = state_;

        // Withdraw collateral to user (after substracting fee)
        TransferHelper.safeTransfer(_COLLATERAL_TOKEN, msg.sender, collateralWithdrawn);

        return collateralWithdrawn;
    }

    /**
     * @notice Users call burn() to burn their APE in exchange for hard cold collateral
     *     @param amountAPE is the amount of APE the gentleman wishes to burn
     */
    function burnAPE(uint256 amountAPE) external returns (uint256) {
        // Get price and update ORACLE if necessary
        bytes16 price = ORACLE.updatePriceMemory(_COLLATERAL_TOKEN);

        VaultStructs.State memory state_ = state;
        (VaultStructs.Reserves memory reservesPre, uint256 collateralWithdrawn, uint256 feeToPOL) = _VAULT_LOGIC
            .quoteBurn(state_, _LEVERAGE_TIER, price, _APE_TOKEN.totalSupply(), amountAPE, false);

        // Burn TEA, mint POL?
        _APE_TOKEN.burn(msg.sender, amountAPE);
        if (feeToPOL > 0) _mint(address(this), feeToPOL, reservesPre.lpReserve); // Mint POL

        // Store new state reserves
        state = state_;

        // Withdraw collateral to user (after substracting fee)
        TransferHelper.safeTransfer(_COLLATERAL_TOKEN, msg.sender, collateralWithdrawn);

        return collateralWithdrawn;
    }

    /**
     * @notice Upon transfering collateral to the contract, the minter must call this function atomically to mint the corresponding amount of MAAM.
     *     @notice Because MAAM is a rebasing token, the minted amount will always be collateralDeposited regardless of price fluctuations.
     *     @notice To control the slippage it returns the final value of the LP reserves.
     *     @return LP reserve after mint
     */
    function mintMAAM() external returns (uint256) {
        // Get price and update ORACLE if necessary
        bytes16 price = ORACLE.updatePriceMemory(_COLLATERAL_TOKEN);

        VaultStructs.State memory state_ = state;
        (uint256 LPReservePre, uint256 collateralDeposited) = _VAULT_LOGIC.quoteMintMAAM(
            state_,
            _LEVERAGE_TIER,
            price,
            _COLLATERAL_TOKEN
        );

        // Mint MAAM
        _mint(msg.sender, collateralDeposited, LPReservePre);

        // Store new state
        state = state_;

        return LPReservePre + collateralDeposited;
    }

    /**
     * @notice LPers call burnMAAM() to burn their MAAM in exchange for hard cold collateral
     *     @param amountMAAM the LPer wishes to burn
     *     @notice To control the slippage it returns the final value of the LP reserves.
     *     @return LP reserve after burn
     */
    function burnMAAM(uint256 amountMAAM) external returns (uint256) {
        // Get price and update ORACLE if necessary
        bytes16 price = ORACLE.updatePriceMemory(_COLLATERAL_TOKEN);

        // Burn all?
        if (amountMAAM == type(uint256).max) amountMAAM = balanceOf(msg.sender);

        VaultStructs.State memory state_ = state;
        uint256 LPReservePre = _VAULT_LOGIC.quoteBurnMAAM(state_, _LEVERAGE_TIER, price, amountMAAM);

        // Burn MAAM
        _burn(msg.sender, amountMAAM, LPReservePre);

        // Store new state
        state = state_;

        // Send collateral
        TransferHelper.safeTransfer(_COLLATERAL_TOKEN, msg.sender, amountMAAM);

        return LPReservePre - amountMAAM;
    }

    /*////////////////////////////////////////////////////////////////
                        QUOTE (READ-ONLY) FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // CREATE FUNCTION THAT RETURNS WHAT MAAM CORRESPONDS TO IN TERMS OF TEA AND APE, OR TEA/APE AND COLLATERAL.

    // CREATE FUNCTION THAT OUTPUTS REAL BACKING RATIO

    // CREATE FUNCTION THAT OUTPUTS REAL LEVERAGE RATIO

    /*/////////////////////f//////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function parameters() external view returns (address debtToken, address collateralToken, int8 leverageTier) {
        debtToken = _DEBT_TOKEN;
        collateralToken = _COLLATERAL_TOKEN;
        leverageTier = _LEVERAGE_TIER;
    }

    function syntheticTokens() external view returns (address teaToken, address apeToken) {
        teaToken = address(_TEA_TOKEN);
        apeToken = address(_APE_TOKEN);
    }

    /**
     * @return total supply of MAAM (which is pegged to the collateral)
     *     @dev Override of virtual totalSupply() in MAAM.sol
     */
    function totalSupply() public view override returns (uint256) {
        bytes16 price = ORACLE.getPrice(_COLLATERAL_TOKEN);
        VaultStructs.Reserves memory reserves = _VAULT_LOGIC.getReserves(state, _LEVERAGE_TIER, price);
        return reserves.lpReserve;
    }

    // BRING THIS FUNCTION TO PERIPHERY
    // function priceStabilityRange()
    //     external
    //     view
    //     returns (
    //         bytes16 pLiq,
    //         bytes16 pLow,
    //         bytes16 pHigh
    //     )
    // {
    //     return _VAULT_LOGIC.priceStabilityRange(state, _LEVERAGE_TIER);
    // }

    // BRING THIS FUNCTION TO PERIPHERY
    // function LPAllocation() external view returns (uint256 collateralInTEA, uint256 collateralInAPE) {
    //     bytes16 price = ORACLE.getPrice(_COLLATERAL_TOKEN);
    //     VaultStructs.Reserves memory reserves = _VAULT_LOGIC.getReserves(state, _LEVERAGE_TIER, price);

    //     bytes16 x = FloatingPoint.divu(reserves.apesReserve, state.totalReserves);
    //     bytes16 y = FloatingPoint.divu(reserves.gentlemenReserve, state.totalReserves);

    //     (bytes16 leverageRatio, bytes16 collateralizationFactor) = _VAULT_LOGIC.calculateRatios(_LEVERAGE_TIER);

    //     if (y.cmp(collateralizationFactor.inv()) >= 0) {
    //         /**
    //             PRICE BELOW PSR
    //          */
    //         collateralInAPE = reserves.lpReserve;
    //     } else if (x.cmp(leverageRatio.inv()) < 0) {
    //         /**
    //             PRICE IN PSR
    //          */
    //         collateralInAPE = FloatingPoint.ONE.mulDiv(state.totalReserves, leverageRatio) - reserves.apesReserve;
    //         assert((collateralInAPE <= reserves.lpReserve));
    //         collateralInTEA = reserves.lpReserve - collateralInAPE;
    //     } else {
    //         /**
    //             PRICE ABOVE PSR
    //          */
    //         collateralInTEA = reserves.lpReserve;
    //     }
    // }

    /*////////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Multisig/daoFees withdraws collected _VAULT_LOGIC
     */
    function withdrawDAOFees() external returns (uint256 daoFees) {
        require(msg.sender == _VAULT_LOGIC.SYSTEM_CONTROL());
        daoFees = state.daoFees;
        state.daoFees = 0; // No re-entrancy attack
        TransferHelper.safeTransfer(_COLLATERAL_TOKEN, msg.sender, daoFees);
    }
}
