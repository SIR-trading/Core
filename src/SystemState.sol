// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {TEA, IERC20} from "./TEA.sol";
import {VaultStructs} from "./libraries/VaultStructs.sol";
import "forge-std/Test.sol";

contract SystemState is TEA {
    /** Choice of types for 'cumSIRPerTEAx96' and 'unclaimedRewards'

        unclaimedRewards ~ uint80
        cumSIRPerTEAx96 ~ uint176 ~ Q80.96

        Worst case analysis assuming all SIR is accumulated by a single LPer AND it never gets claimed.
        If SIR uses 12 decimals after the comma, 'uint80' is sufficient to store ALL SIR issued over 599 years
            2,015,000,000 sir/year * 599 years * 10^12 ≤ type(uint80).max

        Maximum TEA Supply
        The previous choice implies that if wish to store struct LPerIssuanceParams in a single slot (256 bits), cumSIRPerTEAx96 can use up to
            96 bits for the decimals (Q80.96)
        It is important that cumSIRPerTEAx96 does not underflow (if it is 0 it would wrongly imply that the LPers have not claim to any SIR):
            cumSIRPerTEAx96 = 8/10 * 63.9 SIR/s * 10^12 * timeInterval * 2^96 * (tax / cumTax) / T
        In the worst case scenario: timeInterval=1s, tax=1, cumTax=type(uint16).max and TEA has 18 decimals. So to avoid underflow:
            T ≤ 8/10 * 63.9 * 10^12 * 2^96 / (2^16-1)
        If TEA has 18 decimals
            Max Supply of TEA = T / 10^18 ≈ 6.18 * 10^19
        which is more than a Quintillion TEA, sufficient for almost any ERC-20.

        or in words, a bit more than a Sextillion TEA, sufficient for almost any ERC-20.
     */
    struct LPerIssuanceParams {
        uint176 cumSIRPerTEAx96; // Q80.96, cumulative SIR minted by an LPer per unit of TEA
        uint80 unclaimedRewards; // SIR owed to the LPer. 80 bits is enough to store the balance even if all SIR issued in +1000 years went to a single LPer
    }

    struct VaultIssuanceParams {
        uint8 tax; // (tax / type(uint8).max * 10%) of its fee revenue is directed to the DAO.
        uint40 tsLastUpdate; // timestamp of the last time cumSIRPerTEAx96 was updated. 0 => use systemParams.tsIssuanceStart instead
        uint176 cumSIRPerTEAx96; // Q104.96, cumulative SIR minted by the vaultId per unit of TEA.
    }

    address private immutable _SIR;

    mapping(uint256 vaultId => VaultIssuanceParams) internal _vaultsIssuanceParams;
    mapping(uint256 vaultId => mapping(address => LPerIssuanceParams)) private _lpersIssuances;

    VaultStructs.SystemParameters public systemParams =
        VaultStructs.SystemParameters({
            tsIssuanceStart: 0,
            baseFee: 5000, // Test start base fee with 50% base on analysis from SQUEETH
            lpFee: 50,
            emergencyStop: false, // Emergency stop is off
            cumTax: 0
        });

    /** This is the hash of the active vaults. It is used to make sure active vaults's issuances are nulled
        before new issuance parameters are stored. This is more gas efficient that storing all active vaults
        in an arry, but it requires that system control keeps track of the active vaults.
        If the vaults were in an unknown order, it maybe be problem because the hash would change.
        So by default the vaults must be ordered in increasing order.

        The default value is the hash of an empty array.
     */
    // bytes32 private _hashActiveVaults = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    constructor(address systemControl, address sir, address vaultExternal) TEA(systemControl, vaultExternal) {
        _SIR = sir;
    }

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function cumulativeSIRPerTEA(uint256 vaultId) public view returns (uint176 cumSIRPerTEAx96) {
        unchecked {
            VaultStructs.SystemParameters memory systemParams_ = systemParams;

            // Get the vault issuance parameters
            VaultIssuanceParams memory vaultIssuanceParams_ = _vaultsIssuanceParams[vaultId];
            cumSIRPerTEAx96 = vaultIssuanceParams_.cumSIRPerTEAx96;

            // Do nothing if no new SIR has been issued, or it has already been updated
            uint256 totalSupply_ = totalSupply[vaultId];
            if (
                systemParams_.tsIssuanceStart != 0 &&
                vaultIssuanceParams_.tax != 0 &&
                vaultIssuanceParams_.tsLastUpdate != uint40(block.timestamp) &&
                totalSupply_ != 0
            ) {
                // Find starting time to compute cumulative SIR per unit of TEA
                uint40 tsStart = systemParams_.tsIssuanceStart > vaultIssuanceParams_.tsLastUpdate
                    ? systemParams_.tsIssuanceStart
                    : vaultIssuanceParams_.tsLastUpdate;

                // Aggregate SIR issued before the first 3 years. Issuance is slightly lower during the first 3 years because some is diverged to contributors.
                uint40 ts3Years = systemParams_.tsIssuanceStart + THREE_YEARS;
                if (tsStart < ts3Years) {
                    uint256 issuance = (uint256(AGG_ISSUANCE_VAULTS) * vaultIssuanceParams_.tax) / systemParams_.cumTax;
                    // Cannot OF because 80 bits for the non-decimal part is enough to store the balance even if all SIR issued in 599 years went to a single LPer
                    cumSIRPerTEAx96 += uint176(
                        ((issuance *
                            ((uint40(block.timestamp) > ts3Years ? ts3Years : uint40(block.timestamp)) - tsStart)) <<
                            96) / totalSupply_
                    );
                }

                // Aggregate SIR issued after the first 3 years
                if (uint40(block.timestamp) > ts3Years) {
                    uint256 issuance = (uint256(ISSUANCE) * vaultIssuanceParams_.tax) / systemParams_.cumTax;
                    cumSIRPerTEAx96 += uint176(
                        (((issuance * (uint40(block.timestamp) - (tsStart > ts3Years ? tsStart : ts3Years))) << 96) /
                            totalSupply_)
                    );
                }
            }
        }
    }

    function unclaimedRewards(uint256 vaultId, address lper) external view returns (uint80) {
        return _unclaimedRewards(vaultId, lper, cumulativeSIRPerTEA(vaultId));
    }

    function _unclaimedRewards(uint256 vaultId, address lper, uint176 cumSIRPerTEAx96) private view returns (uint80) {
        unchecked {
            // Get the lper issuance parameters
            LPerIssuanceParams memory lperIssuanceParams_ = _lpersIssuances[vaultId][lper];

            // Get the LPer balance of TEA
            uint256 balance = balanceOf[lper][vaultId];

            // If LPer has no TEA
            if (balance == 0) return lperIssuanceParams_.unclaimedRewards;

            // It does not OF because uint80 is chosen so that it can stored all issued SIR for almost 600 years.
            return
                lperIssuanceParams_.unclaimedRewards +
                uint80((balance * uint256(cumSIRPerTEAx96 - lperIssuanceParams_.cumSIRPerTEAx96)) >> 96);
        }
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function updateLPerIssuanceParams(uint256 vaultId, address lper) external returns (uint80) {
        require(msg.sender == _SIR);

        return updateLPerIssuanceParams(true, vaultId, lper, address(0));
    }

    /**
     * @dev To be called BEFORE transfering/minting/burning TEA
     */
    function updateLPerIssuanceParams(
        bool sirIsCaller,
        uint256 vaultId,
        address lper0,
        address lper1
    ) internal override returns (uint80 unclaimedRewards0) {
        // If issuance has not started, return
        if (systemParams.tsIssuanceStart == 0) return 0;

        // Retrieve updated vault issuance parameters
        uint176 cumSIRPerTEAx96 = cumulativeSIRPerTEA(vaultId);
        console.log("contract cumSIRPerTEAx96", cumSIRPerTEAx96);

        // Retrieve updated LPer issuance parameters
        unclaimedRewards0 = _unclaimedRewards(vaultId, lper0, cumSIRPerTEAx96);

        // Update LPer0 issuance parameters
        _lpersIssuances[vaultId][lper0] = LPerIssuanceParams(cumSIRPerTEAx96, sirIsCaller ? 0 : unclaimedRewards0);

        if (lper1 != address(0))
            /** Transfer of TEA
                1. Must update the destinatary's issuance parameters too
                2. Valut issuance does not need to be updated because totalSupply does not change
             */
            _lpersIssuances[vaultId][lper1] = LPerIssuanceParams(
                cumSIRPerTEAx96,
                _unclaimedRewards(vaultId, lper1, cumSIRPerTEAx96)
            );
        else if (!sirIsCaller) {
            /** Mint or burn TEA
                1. Must update the vault's issuance
             */
            _vaultsIssuanceParams[vaultId].cumSIRPerTEAx96 = cumSIRPerTEAx96;
            _vaultsIssuanceParams[vaultId].tsLastUpdate = uint40(block.timestamp);
        }
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /// @dev All checks and balances to be done at system control
    function updateSystemState(VaultStructs.SystemParameters calldata systemParams_) external onlySystemControl {
        systemParams = systemParams_;
    }

    function updateVaults(
        uint40[] calldata oldVaults,
        uint40[] calldata newVaults,
        uint8[] calldata newTaxes,
        uint16 cumTax
    ) external onlySystemControl {
        // Stop old issuances
        for (uint256 i = 0; i < oldVaults.length; ++i) {
            // Retrieve the vault's current cumulative SIR per unit of TEA
            uint176 cumSIRPerTEAx96 = cumulativeSIRPerTEA(oldVaults[i]);

            // Update vault issuance parameters
            _vaultsIssuanceParams[oldVaults[i]] = VaultIssuanceParams({
                tax: 0, // Nul tax, and consequently nul SIR issuance
                tsLastUpdate: uint40(block.timestamp),
                cumSIRPerTEAx96: cumSIRPerTEAx96
            });
        }

        // Start new issuances
        for (uint256 i = 0; i < newVaults.length; ++i) {
            // Retrieve the vault's current cumulative SIR per unit of TEA
            uint176 cumSIRPerTEAx96 = cumulativeSIRPerTEA(newVaults[i]);

            // Update vault issuance parameters
            _vaultsIssuanceParams[newVaults[i]] = VaultIssuanceParams({
                tax: newTaxes[i],
                tsLastUpdate: uint40(block.timestamp),
                cumSIRPerTEAx96: cumSIRPerTEAx96
            });
        }

        // Update cumulative taxes
        systemParams.cumTax = cumTax;
    }
}
