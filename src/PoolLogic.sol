// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import "./SystemState.sol";

// Interfaces
import "@uniswap/v2-core/contracts/interfaces/IERC20.sol";
import "./interfaces/PoolStructs.sol";

// Libraries
import "./libraries/FullMath.sol";
import "./libraries/FloatingPoint.sol";
import "./libraries/Fees.sol";

contract PoolLogic is SystemState {
    using FloatingPoint for bytes16;

    constructor(address systemControl) SystemState(systemControl) {}

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    // CREATE FUNCTION THAT RETURNS WHAT MAAM CORRESPONDS TO IN TERMS OF TEA AND APE, OR TEA/APE AND COLLATERAL.

    /**
        @notice No-op variation of mint() for simulation and quoting purposes.
        @notice If it reverts, mint() also reverts; but the opposite is not always true.
     */
    function quoteMint(
        PoolStructs.State memory state,
        int8 leverageTier,
        bytes16 price,
        uint256 syntheticSupply,
        address collateralToken,
        bool isTEA
    )
        external
        view
        returns (
            PoolStructs.Reserves memory reservesPre,
            uint256 amountSyntheticToken,
            uint256 feeToPOL
        )
    {
        // Until SIR is running, only LPers are allowed to mint (deposit collateral)
        require(systemParams.tsIssuanceStart > 0);

        // Get deposited collateral
        uint256 collateralDeposited = _getCollateralDeposited(state, collateralToken);

        // Get reserves
        reservesPre = getReserves(state, leverageTier, price);

        // Substract fee
        Fees.FeesParameters memory feesParams = isTEA
            ? Fees.FeesParameters({
                basisFee: systemParams.basisFee,
                isMint: true,
                collateralInOrOut: collateralDeposited,
                reserveSyntheticToken: reservesPre.gentlemenReserve,
                reserveOtherToken: reservesPre.apesReserve,
                collateralizationOrLeverageTier: -leverageTier
            })
            : Fees.FeesParameters({
                basisFee: systemParams.basisFee,
                isMint: true,
                collateralInOrOut: collateralDeposited,
                reserveSyntheticToken: reservesPre.apesReserve,
                reserveOtherToken: reservesPre.gentlemenReserve,
                collateralizationOrLeverageTier: leverageTier
            });
        (uint256 collateralIn, uint256 collateralFee) = Fees._hiddenFee(feesParams);

        // Mint amount
        amountSyntheticToken = feesParams.reserveSyntheticToken == 0
            ? collateralIn // Peg APE to the collateral token on the 1st mint
            : FullMath.mulDiv(syntheticSupply, collateralIn, feesParams.reserveSyntheticToken);

        // Update reserves
        PoolStructs.Reserves memory reservesPost;
        (reservesPost, feeToPOL) = _updateReserves(reservesPre, collateralIn, collateralFee, isTEA, true);

        // Update state
        _updateState(state, reservesPost, leverageTier, price);
    }

    function quoteBurn(
        PoolStructs.State memory state,
        int8 leverageTier,
        bytes16 price,
        uint256 syntheticSupply,
        uint256 amountSyntheticToken,
        bool isTEA
    )
        external
        view
        returns (
            PoolStructs.Reserves memory reservesPre,
            uint256 collateralWithdrawn,
            uint256 feeToPOL
        )
    {
        // Get reserves
        reservesPre = getReserves(state, leverageTier, price);

        // Get collateralOut
        uint256 collateralOut = FullMath.mulDiv(
            isTEA ? reservesPre.gentlemenReserve : reservesPre.apesReserve,
            amountSyntheticToken,
            syntheticSupply
        );

        // Substract fee
        Fees.FeesParameters memory feesParams = isTEA
            ? Fees.FeesParameters({
                basisFee: systemParams.basisFee,
                isMint: false,
                collateralInOrOut: collateralOut,
                reserveSyntheticToken: reservesPre.gentlemenReserve,
                reserveOtherToken: reservesPre.apesReserve,
                collateralizationOrLeverageTier: -leverageTier
            })
            : Fees.FeesParameters({
                basisFee: systemParams.basisFee,
                isMint: false,
                collateralInOrOut: collateralOut,
                reserveSyntheticToken: reservesPre.apesReserve,
                reserveOtherToken: reservesPre.gentlemenReserve,
                collateralizationOrLeverageTier: leverageTier
            });

        uint256 collateralFee;
        (collateralWithdrawn, collateralFee) = Fees._hiddenFee(feesParams);

        // Update reserves
        PoolStructs.Reserves memory reservesPost;
        (reservesPost, feeToPOL) = _updateReserves(reservesPre, collateralOut, collateralFee, isTEA, false);

        // Update state
        _updateState(state, reservesPost, leverageTier, price);
    }

    function quoteMintMAAM(
        PoolStructs.State memory state,
        int8 leverageTier,
        bytes16 price,
        address collateralToken
    ) external view returns (uint256 LPReservePre, uint256 collateralDeposited) {
        // Get deposited collateral
        collateralDeposited = _getCollateralDeposited(state, collateralToken);

        // Get reserves
        PoolStructs.Reserves memory reserves = getReserves(state, leverageTier, price);

        // Update reserves
        LPReservePre = reserves.LPReserve;
        reserves.LPReserve += collateralDeposited;

        // Update state
        _updateState(state, reserves, leverageTier, price);
    }

    function quoteBurnMAAM(
        PoolStructs.State memory state,
        int8 leverageTier,
        bytes16 price,
        uint256 amountMAAM
    ) external pure returns (uint256 LPReservePre) {
        // Get reserves
        PoolStructs.Reserves memory reserves = getReserves(state, leverageTier, price);

        // Update reserves
        LPReservePre = reserves.LPReserve;
        reserves.LPReserve -= amountMAAM;

        // Update state
        _updateState(state, reserves, leverageTier, price);
    }

    /*////////////////////////////////////////////////////////////////
                        UTILITY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
        Connections Between State Variables (R,pLow,pHigh) & Reserves (G,A,L)
        where R = Total reserve, G = Gentlemen reserve, A = Apes reserve, L = LP reserve
        (R,pLow,pHigh) ⇔ (G,A,L)
        (R,  0 ,pHigh) ⇔ (0,A,L)
        (R,pLow,  ∞  ) ⇔ (G,0,L)
        (R,pLow, pLow) ⇔ (G,A,0)
        (R,  0 ,  ∞  ) ⇔ (0,0,L)
        (R,  0 ,  0  ) ⇔ (0,A,0)
        (R,pLow,  ∞  ) ⇔ (G,0,0)
        (0,pLow,pHigh) ⇔ (0,0,0)
     */

    function getReserves(
        PoolStructs.State memory state,
        int8 leverageTier,
        bytes16 price
    ) public pure returns (PoolStructs.Reserves memory reserves) {
        unchecked {
            reserves.DAOFees = state.DAOFees;

            // RESERVE IS EMPTY
            if (state.totalReserves == 0) return reserves;

            // All APE
            if (state.pHigh == FloatingPoint.ZERO) {
                reserves.apesReserve = state.totalReserves;
                return reserves;
            }

            (bytes16 leverageRatio, bytes16 collateralizationFactor) = _calculateRatios(leverageTier);
            bytes16 pLow = state.pLiq.mul(collateralizationFactor); // Ape & LPers liquidation price

            // All TEA
            if (price.cmp(state.pLiq) <= 0) {
                // pLow == INFINITY <=> pLiq == INFINITY
                reserves.gentlemenReserve = state.totalReserves;
                return reserves;
            }

            // COMPUTE GENTLEMEN RESERVE
            reserves.gentlemenReserve = state.pLiq.mulDiv(state.totalReserves, price); // From the formula of pLiq, we can derive the gentlemenReserve
            /**
                Numercial Concerns
                    Division by 0 not possible because NEVER price == 0
                    pLiq not Infinity because that case has already been taken taken care
                    gentlemenReserve <= totalReserves BECAUSE price > pLiq
            */

            // COMPUTE APES RESERVE
            if (pLow == state.pHigh)
                reserves.apesReserve = state.totalReserves - reserves.gentlemenReserve; // No liquidity providers
            else if (state.pHigh == FloatingPoint.INFINITY)
                reserves.apesReserve = 0; // No apes
            else if (price.cmp(pLow) <= 0) {
                /**
                    PRICE BELOW PSR
                    LPers are 100% in APE
                */
                reserves.apesReserve = pLow.div(state.pHigh).pow(leverageRatio.dec()).mulu(
                    state.totalReserves - reserves.gentlemenReserve
                );
                /**
                    Proof gentlemenReserve + apesReserve ≤ totalReserves
                        pLow.div(state.pHigh).pow(leverageRatio.dec()) ≤ 1
                        ⇒ apesReserve ≤ totalReserves - gentlemenReserve
                    Proof apesReserve ≥ 0
                        totalReserves ≥ gentlemenReserve
                */
            } else if (price.cmp(state.pHigh) < 0) {
                /**
                    PRICE IN PSR
                    Leverage behaves as expected
                */
                reserves.apesReserve = price.div(state.pHigh).pow(leverageRatio.dec()).mulDiv(
                    state.totalReserves,
                    leverageRatio
                );
                /**
                    Proof gentlemenReserve + apesReserve ≤ totalReserves
                        1) price < pHigh ⇒ price.div(pHigh).pow(leverageRatio.dec()).mulDiv(totalReserves,leverageRatio) < totalReserves / leverageRatio
                        2) gentlemenReserve = pLiq.mulDiv(totalReserves, price)
                        ⇒ gentlemenReserve ≤ pLow * totalReserves / (price * collateralizationFactor) (because of rounding down)
                        ⇒ gentlemenReserve ≤ totalReserves / collateralizationFactor
                        By 1) & 2) apesReserve + gentlemenReserve ≤ totalReserves / leverageRatio + totalReserves / collateralizationFactor = totalReserves
                    Proof apesReserve ≥ 0
                        All variables are possitive
                */
            } else {
                /**
                    PRICE ABOVE PSR
                    LPers are 100% in TEA.
                */
                reserves.apesReserve = state.totalReserves - state.pHigh.mulDiv(reserves.gentlemenReserve, pLow);
                /**
                    Proof gentlemenReserve + apesReserve ≤ totalReserves
                        pHigh / pLow ≥ 1
                        ⇒ apesReserve ≤ totalReserves - gentlemenReserve
                    Proof apesReserve ≥ 0
                        pHigh.mulDiv(gentlemenReserve, pLow) ≤  pHigh / price * totalReserves / collateralizationFactor
                        ⇒ pHigh.mulDiv(gentlemenReserve, pLow) ≤ totalReserves / collateralizationFactor
                        ⇒ totalReserves - pHigh.mulDiv(gentlemenReserve, pLow) ≥ 0
                */
            }

            assert(reserves.gentlemenReserve + reserves.apesReserve <= state.totalReserves);

            // COMPUTE LP RESERVE
            reserves.LPReserve = state.totalReserves - reserves.gentlemenReserve - reserves.apesReserve;
        }
    }

    /*////////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _getCollateralDeposited(PoolStructs.State memory state, address collateralToken)
        private
        view
        returns (uint256)
    {
        require(!systemParams.onlyWithdrawals);

        // Get deposited collateral
        return IERC20(collateralToken).balanceOf(address(msg.sender)) - state.DAOFees - state.totalReserves;
    }

    function _updateReserves(
        PoolStructs.Reserves memory reservesPre,
        uint256 collateralInOrOut,
        uint256 collateralFee,
        bool isTEA,
        bool goesIn
    ) private view returns (PoolStructs.Reserves memory reservesPost, uint256 feeToPOL) {
        // Calculate fee to the DAO
        uint256 feeToDAO = FullMath.mulDiv(collateralFee, _poolsIssuances[msg.sender].taxToDAO, 1e5);

        reservesPost = PoolStructs.Reserves({
            DAOFees: reservesPre.DAOFees + feeToDAO,
            gentlemenReserve: isTEA
                ? (
                    goesIn
                        ? reservesPre.gentlemenReserve + collateralInOrOut
                        : reservesPre.gentlemenReserve - collateralInOrOut // Reverts if too much collateral is withdrawn
                )
                : reservesPre.gentlemenReserve,
            apesReserve: isTEA
                ? reservesPre.apesReserve
                : (goesIn ? reservesPre.apesReserve + collateralInOrOut : reservesPre.apesReserve - collateralInOrOut),
            LPReserve: reservesPre.LPReserve + collateralFee - feeToDAO
        });

        // A chunk of the LP fee is diverged to Protocol Owned Liquidity (POL)
        feeToPOL = collateralFee / 10;
    }

    function _updateState(
        PoolStructs.State memory state,
        PoolStructs.Reserves memory reserves,
        int8 leverageTier,
        bytes16 price
    ) private pure {
        (bytes16 leverageRatio, bytes16 collateralizationFactor) = _calculateRatios(leverageTier);

        state.DAOFees = reserves.DAOFees;
        state.totalReserves = reserves.gentlemenReserve + reserves.apesReserve + reserves.LPReserve;

        unchecked {
            if (state.totalReserves == 0) return; // When the reserve is empty, pLow and pHigh are undetermined

            // COMPUTE pLiq & pLow
            state.pLiq = reserves.gentlemenReserve == 0
                ? FloatingPoint.ZERO
                : price.mulDivuUp(reserves.gentlemenReserve, state.totalReserves);
            bytes16 pLow = collateralizationFactor.mulUp(state.pLiq);
            /**
                Why round up numerical errors?
                    To enable TEA to become a stablecoin, its price long term should not decay, even if extremely slowly.
                    By rounding up we ensure it decays UP.
                Numerical concerns
                    Division by 0 not possible because totalReserves != 0
             */

            // COMPUTE pHigh
            if (reserves.apesReserve == 0) state.pHigh = FloatingPoint.INFINITY;
            else if (reserves.LPReserve == 0) state.pHigh = pLow;
            else if (price.cmp(pLow) <= 0) {
                // PRICE BELOW PSR
                state.pHigh = pLow.div(
                    FloatingPoint.divu(reserves.apesReserve, reserves.apesReserve + reserves.LPReserve).pow(
                        collateralizationFactor.dec()
                    )
                );
                /**
                    Numerical Concerns
                        Division by 0 not possible because apesReserve != 0
                        Righ hand side could still be ∞ because of the power.
                        0 * ∞ not possible because  pLow > price > 0
                    Proof pHigh ≥ pLow
                        apesReserve + LPReserve ≥ apesReserve 
                */
            } else if (reserves.apesReserve < leverageRatio.inv().mulu(state.totalReserves)) {
                // PRICE IN PSR
                state.pHigh = price.div(
                    leverageRatio.mulDivu(reserves.apesReserve, state.totalReserves).pow(collateralizationFactor.dec())
                );
                /**
                    Numerical Concerns
                        Division by 0 not possible because totalReserves != 0
                    Proof pHigh ≥ pLow
                        leverageRatio.mulDivu(apesReserve,totalReserves) ≤ 1 & price ≥ pLow
                */
            } else {
                // PRICE ABOVE PSR
                state.pHigh = collateralizationFactor.mul(price).mulDivu(
                    reserves.gentlemenReserve + reserves.LPReserve,
                    state.totalReserves
                );
                /**
                    Numerical Concerns
                        Division by 0 not possible because totalReserves != 0
                    Proof pHigh ≥ pLow
                        Yes, because
                        collateralizationFactor.mul(price).mulDivu(gentlemenReserve + LPReserve,state.totalReserves) >
                        collateralizationFactor.mul(price).mulDivu(gentlemenReserve,state.totalReserves) = pLow
                */
            }

            assert(pLow.cmp(FloatingPoint.INFINITY) < 0);
            assert(pLow.cmp(state.pHigh) <= 0);
        }
    }

    function _calculateRatios(int8 leverageTier)
        private
        pure
        returns (bytes16 leverageRatio, bytes16 collateralizationFactor)
    {
        bytes16 temp = FloatingPoint.fromInt(leverageTier).pow_2();
        collateralizationFactor = temp.inv().inc();
        leverageRatio = temp.inc();
    }
}
