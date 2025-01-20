// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {SirStructs} from "./libraries/SirStructs.sol";
import {SystemControlAccess} from "./SystemControlAccess.sol";
import {SystemConstants} from "./libraries/SystemConstants.sol";

/** @dev Contract handling the few protocol-wide parameters,
    @dev and some of the functions for keeping track of the SIR rewards assign to vaults.
 */
abstract contract SystemState is SystemControlAccess {
    /** Choice of types for 'cumulativeSIRPerTEAx96' and 'unclaimedRewards'

        unclaimedRewards ~ uint80
        cumulativeSIRPerTEAx96 ~ uint176 ~ Q80.96

        Worst case analysis assuming all SIR is accumulated by a single LPer AND it never gets claimed.
        If SIR uses 12 decimals after the comma, 'uint80' is sufficient to store ALL SIR issued over 599 years
            2,015,000,000 sir/year * 599 years * 10^12 ≤ type(uint80).max

        Maximum TEA Supply
        The previous choice implies that if wish to store struct LPerIssuanceParams in a single slot (256 bits), cumulativeSIRPerTEAx96 can use up to
            96 bits for the decimals (Q80.96)
        It is important that cumulativeSIRPerTEAx96 does not underflow (if it is 0 it would wrongly imply that the LPers have not claim to any SIR):
            cumulativeSIRPerTEAx96 = 8/10 * 63.9 SIR/s * 10^12 * timeInterval * 2^96 * (tax / cumulativeTax) / T
        In the worst case scenario: timeInterval=1s, tax=1, cumulativeTax=type(uint16).max and TEA has 18 decimals. So to avoid underflow:
            T ≤ 8/10 * 63.9 * 10^12 * 2^96 / (2^16-1)
        If TEA has 18 decimals
            Max Supply of TEA = T / 10^18 ≈ 6.18 * 10^19
        which is more than a Quintillion TEA, sufficient for almost any ERC-20.
     */

    event VaultNewTax(uint48 indexed vault, uint8 tax, uint16 cumulativeTax);

    struct LPerIssuanceParams {
        uint176 cumulativeSIRPerTEAx96; // Q80.96, cumulative SIR minted by an LPer per unit of TEA
        uint80 unclaimedRewards; // SIR owed to the LPer. 80 bits is enough to store the balance even if all SIR issued in +1000 years went to a single LPer
    }

    struct LPersBalances {
        address lper0;
        uint256 balance0;
        address lper1;
        uint256 balance1;
    }

    uint40 public immutable TIMESTAMP_ISSUANCE_START;

    address internal immutable _SIR;

    mapping(uint256 vaultId => SirStructs.VaultIssuanceParams) internal vaultIssuanceParams;
    mapping(uint256 vaultId => mapping(address => LPerIssuanceParams)) private _lpersIssuances;

    SirStructs.SystemParameters internal _systemParams;

    constructor(address systemControl, address sir_) SystemControlAccess(systemControl) {
        TIMESTAMP_ISSUANCE_START = uint40(block.timestamp);

        _SIR = sir_;

        /** Apes pay fees to the gentlemen for their liquidity when minting or burning APE. They are paid twice to encourage LPers to
            continue to provide liqduidity after a mint of APE.

            Gentlemen pay a fee when minting TEA given to the protocol. Protocol will never touch these fees and act as its own pool of liquidity.
            These fee is very important because it mitigate an LP sandwich attack. If there were no fees charge to the gentlemen, when an ape mints
            (or burns) APE, the attacker could mint before the ape and burn after the ape, earning the fees risk-free.
         */
        _systemParams = SirStructs.SystemParameters({
            baseFee: SirStructs.FeeStructure({fee: 3000, feeNew: 0, timestampUpdate: 0}), // At 1.5 leverage, apes would pay 24% of their deposit as upfront fee.
            lpFee: SirStructs.FeeStructure({fee: 989, feeNew: 0, timestampUpdate: 0}), // To mitigate LP sandwich attacks. LPers would pay 9% of their deposit as upfront fee.
            mintingStopped: false,
            cumulativeTax: 0
        });
    }

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** 
        @dev Ideally, the cumulative SIR minted by the vaultId per unit of TEA (a).
        @dev    a_i = a_{i-i} + issuance * Δt_i * 2^96 / totalSupplyTEA_i
        @dev where i is the i-th time the cumulative SIR is updated, and timeInterval is the time since the last update.
        @dev Because of the implicity rounding of the division operation the actual computed value of
        @dev    â_i = â_{i-1} + issuance * Δt_i * 2^96 / totalSupplyTEA_i + n_i
        @dev        = â_{i-1} + Δa_i + n_i
        @dev where n_i ∈ (- 1,0] is the rounding error due to the division, and Δa_i = issuance * Δt_i * 2^96 / totalSupplyTEA_i.
        @dev Alternatively,
        @dev    â_i = Σ_i (Δa_i + n_i)
        @dev        = Σ_i Δa_i + n
        @dev where n ∈ (- M,0] is the cumulative rounding error, and M is the number of updates on the cumulative SIR per unit of TEA.
        @return cumulativeSIRPerTEAx96 cumulative SIR issued to the vault per unit of TEA.            
    */
    function cumulativeSIRPerTEA(
        uint16 cumulativeTax,
        SirStructs.VaultIssuanceParams memory vaultIssuanceParams_,
        uint256 supplyExcludeVault_
    ) internal view returns (uint176 cumulativeSIRPerTEAx96) {
        unchecked {
            // Get the vault issuance parameters
            cumulativeSIRPerTEAx96 = vaultIssuanceParams_.cumulativeSIRPerTEAx96;

            // Do nothing if no new SIR has been issued, or it has already been updated
            if (
                vaultIssuanceParams_.tax != 0 &&
                vaultIssuanceParams_.timestampLastUpdate != uint40(block.timestamp) &&
                supplyExcludeVault_ != 0
            ) {
                assert(vaultIssuanceParams_.tax <= cumulativeTax);

                // Starting time for the issuance in this vault
                uint40 timestampStart = vaultIssuanceParams_.timestampLastUpdate;

                // Aggregate SIR issued before the first 3 years. Issuance is slightly lower during the first 3 years because some is diverged to contributors.
                uint40 timestamp3Years = TIMESTAMP_ISSUANCE_START + SystemConstants.THREE_YEARS;
                if (timestampStart < timestamp3Years) {
                    uint256 issuance = (uint256(SystemConstants.LP_ISSUANCE_FIRST_3_YEARS) * vaultIssuanceParams_.tax) /
                        cumulativeTax;
                    // Cannot OF because 80 bits for the non-decimal part is enough to store the balance even if all SIR issued in 599 years went to a single LPer
                    cumulativeSIRPerTEAx96 += uint176(
                        ((issuance *
                            ((block.timestamp > timestamp3Years ? timestamp3Years : block.timestamp) -
                                timestampStart)) << 96) / supplyExcludeVault_
                    );
                }

                // Aggregate SIR issued after the first 3 years
                if (uint40(block.timestamp) > timestamp3Years) {
                    uint256 issuance = (uint256(SystemConstants.ISSUANCE) * vaultIssuanceParams_.tax) / cumulativeTax;
                    cumulativeSIRPerTEAx96 += uint176(
                        (((issuance *
                            (block.timestamp -
                                (timestampStart > timestamp3Years ? timestampStart : timestamp3Years))) << 96) /
                            supplyExcludeVault_)
                    );
                }
            }
        }
    }

    /**
        @dev Ideally, the unclaimed SIR of an LPer is computed as
        @dev    u = balance * (a_i - a_j) / 2^96
        @dev where i is the last time the cumulative SIR was updated, and j is the last time the LPer claimed its rewards.
        @dev In reality we only have access to â_i,
        @dev    û = balance * (â_i - â_j) / 2^96 =
        @dev      = balance * (Σ_{k=j+1}^i Δa_k + Σ_{k=j+1}^i n_k)) / 2^96
        @dev      = u + balance * (Σ_{k=j+1}^i n_k)) / 2^96
        @dev      = u + balance * q / 2^96
        @dev where q ∈ (- M,0] is the rounding whose range depends on the number (M) of updates on the cumulative SIR per unit of TEA (x).
        @dev Because of the division error, we actually compute
        @dev    ũ = û + r
        @dev where r ∈ (- 1,0] is the rounding error. Thus,
        @dev    ũ ∈ u + (-balance * M / 2^96 -1, 0]
        @param vaultId The id of the vault to query.
        @param lper The address of the LPer to query.
        @param cumulativeSIRPerTEAx96 The current cumulative SIR minted by the vaultId per unit of TEA.
     */
    function unclaimedRewards(
        uint256 vaultId,
        address lper,
        uint256 balance,
        uint176 cumulativeSIRPerTEAx96
    ) internal view returns (uint80) {
        unchecked {
            if (lper == address(this)) return 0;

            // Get the lper issuance parameters
            LPerIssuanceParams memory lperIssuanceParams_ = _lpersIssuances[vaultId][lper];

            // If LPer has no TEA
            if (balance == 0) return lperIssuanceParams_.unclaimedRewards;

            // It does not OF because uint80 is chosen so that it can stored all issued SIR for almost 600 years.
            return
                lperIssuanceParams_.unclaimedRewards +
                uint80((balance * uint256(cumulativeSIRPerTEAx96 - lperIssuanceParams_.cumulativeSIRPerTEAx96)) >> 96);
        }
    }

    function unclaimedRewards(uint256 vaultId, address lper) external view returns (uint80) {
        return unclaimedRewards(vaultId, lper, balanceOf(lper, vaultId), cumulativeSIRPerTEA(vaultId));
    }

    function vaultTax(uint48 vaultId) external view returns (uint8) {
        return vaultIssuanceParams[vaultId].tax;
    }

    function systemParams() public view returns (SirStructs.SystemParameters memory systemParams_) {
        systemParams_ = _systemParams;

        // Check if baseFee needs to be updated
        if (
            systemParams_.baseFee.timestampUpdate != 0 &&
            block.timestamp >= systemParams_.baseFee.timestampUpdate + SystemConstants.FEE_CHANGE_DELAY
        ) {
            systemParams_.baseFee.fee = systemParams_.baseFee.feeNew;
            systemParams_.baseFee.timestampUpdate = 0;
        }

        // Check if lpFee needs to be updated
        if (
            systemParams_.lpFee.timestampUpdate != 0 &&
            block.timestamp >= systemParams_.lpFee.timestampUpdate + SystemConstants.FEE_CHANGE_DELAY
        ) {
            systemParams_.lpFee.fee = systemParams_.lpFee.feeNew;
            systemParams_.lpFee.timestampUpdate = 0;
        }
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function claimSIR(uint256 vaultId, address lper) external returns (uint80) {
        require(msg.sender == _SIR);

        LPersBalances memory lpersBalances = LPersBalances(lper, balanceOf(lper, vaultId), address(0), 0);

        return
            updateLPerIssuanceParams(
                true,
                vaultId,
                _systemParams.cumulativeTax,
                vaultIssuanceParams[vaultId],
                supplyExcludeVault(vaultId),
                lpersBalances
            );
    }

    /** @dev To be called BEFORE transfering/minting/burning TEA
     */
    function updateLPerIssuanceParams(
        bool sirIsCaller,
        uint256 vaultId,
        uint16 cumulativeTax,
        SirStructs.VaultIssuanceParams memory vaultIssuanceParams_,
        uint256 supplyExcludeVault_,
        LPersBalances memory lpersBalances
    ) internal returns (uint80 unclaimedRewards0) {
        // Retrieve cumulative SIR per unit of TEA
        uint176 cumulativeSIRPerTEAx96 = cumulativeSIRPerTEA(cumulativeTax, vaultIssuanceParams_, supplyExcludeVault_);

        // Retrieve updated LPer0 issuance parameters
        unclaimedRewards0 = unclaimedRewards(
            vaultId,
            lpersBalances.lper0,
            lpersBalances.balance0,
            cumulativeSIRPerTEAx96
        );

        // Update LPer0 issuance parameters
        _lpersIssuances[vaultId][lpersBalances.lper0] = LPerIssuanceParams(
            cumulativeSIRPerTEAx96,
            sirIsCaller ? 0 : unclaimedRewards0
        );

        // Protocol owned liquidity (POL) in the vault does not receive SIR rewards
        if (lpersBalances.lper1 != address(this)) {
            /** Transfer/mint of TEA
                Must update the 2nd user's issuance parameters too
             */
            _lpersIssuances[vaultId][lpersBalances.lper1] = LPerIssuanceParams(
                cumulativeSIRPerTEAx96,
                unclaimedRewards(vaultId, lpersBalances.lper1, lpersBalances.balance1, cumulativeSIRPerTEAx96)
            );
        }

        /** Update the vault's issuance
            We may be tempted to skip updating the vault's issuance if the vault's issuance has not changed (i.e. totalSupply has not changed),
            like in the case of a Transfer of TEA. However, this could result in rounding errors causing SIR issuance to be larger than expected.
         */
        vaultIssuanceParams[vaultId].cumulativeSIRPerTEAx96 = cumulativeSIRPerTEAx96;
        vaultIssuanceParams[vaultId].timestampLastUpdate = uint40(block.timestamp);
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /** @notice This function can only be called by the SystemControl contract
        @notice It updates the base fee charge to apes, the fee charged to LPers when minting or haults all minting.
        @dev All these parameters are update in a single function for minimize bytecode.
        @dev All checks and balances to be done at system control
     */
    function updateSystemState(uint16 baseFee, uint16 lpFee, bool mintingStopped) external onlySystemControl {
        SirStructs.SystemParameters memory systemParams_ = systemParams();

        if (baseFee != 0) {
            systemParams_.baseFee.timestampUpdate = uint40(block.timestamp);
            systemParams_.baseFee.feeNew = baseFee;
        } else if (lpFee != 0) {
            systemParams_.lpFee.timestampUpdate = uint40(block.timestamp);
            systemParams_.lpFee.feeNew = lpFee;
        } else {
            systemParams_.mintingStopped = mintingStopped;
        }

        _systemParams = systemParams_;
    }

    /** @notice Updates the tax of the vaults whose fees are distributed to stakers of SIR.
        @notice The amount of SIR rewards received by LPers of a vault is proportional to the tax of the vault. 0 tax implies no SIR rewards.
        @notice This function can only be called by the SystemControl contract.
     */
    function updateVaults(
        uint48[] calldata oldVaults,
        uint48[] calldata newVaults,
        uint8[] calldata newTaxes,
        uint16 cumulativeTax
    ) external onlySystemControl {
        uint176 cumulativeSIRPerTEAx96;

        // Stop old issuances
        for (uint256 i = 0; i < oldVaults.length; ++i) {
            // Retrieve the vault's current cumulative SIR per unit of TEA
            cumulativeSIRPerTEAx96 = cumulativeSIRPerTEA(oldVaults[i]);

            // Update vault issuance parameters
            vaultIssuanceParams[oldVaults[i]] = SirStructs.VaultIssuanceParams({
                tax: 0, // Nul tax, and consequently nul SIR issuance
                timestampLastUpdate: uint40(block.timestamp),
                cumulativeSIRPerTEAx96: cumulativeSIRPerTEAx96
            });

            emit VaultNewTax(oldVaults[i], 0, 0);
        }

        // Start new issuances
        for (uint256 i = 0; i < newVaults.length; ++i) {
            // Retrieve the vault's current cumulative SIR per unit of TEA
            cumulativeSIRPerTEAx96 = cumulativeSIRPerTEA(newVaults[i]);

            // Update vault issuance parameters
            vaultIssuanceParams[newVaults[i]] = SirStructs.VaultIssuanceParams({
                tax: newTaxes[i],
                timestampLastUpdate: uint40(block.timestamp),
                cumulativeSIRPerTEAx96: cumulativeSIRPerTEAx96
            });

            emit VaultNewTax(newVaults[i], newTaxes[i], cumulativeTax);
        }

        // Update cumulative taxes
        _systemParams.cumulativeTax = cumulativeTax;
    }

    /*////////////////////////////////////////////////////////////////
                        FUNCTION TO BE IMPLEMENTED BY TEA
    ////////////////////////////////////////////////////////////////*/

    function cumulativeSIRPerTEA(uint256 vaultId) public view virtual returns (uint176 cumulativeSIRPerTEAx96);

    function balanceOf(address owner, uint256 vaultId) public view virtual returns (uint256);

    function supplyExcludeVault(uint256 vaultId) internal view virtual returns (uint256);
}
