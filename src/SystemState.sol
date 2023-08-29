// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {TEA, IERC20} from "./TEA.sol";
import {SystemCommons} from "./SystemCommons.sol";

abstract contract SystemState is SystemCommons, TEA {
    event IssuanceStart(uint40 tsIssuanceStart);
    event EmergencyStop(bool indexed);
    event NewFees(uint16 baseFee, uint8 lpFee);

    struct LPerIssuanceParams {
        uint144 cumSIRperTEA; // Q104.40, cumulative SIR minted by an LPer per unit of TEA
        uint104 rewards; // SIR owed to the LPer. 104 bits is enough to store the balance even if all SIR issued in +1000 years went to a single LPer
    }

    struct VaultIssuanceParams {
        uint16 taxToDAO; // (taxToDAO / type(uint16).max * 10%) of its fee revenue is directed to the DAO.
        uint16 aggTaxesToDAO; // Aggregated taxToDAO of all vaults
        uint40 tsLastUpdate; // timestamp of the last time cumSIRperTEA was updated. 0 => use systemParams.tsIssuanceStart instead
        uint40 tsIssuanceEnd; // timestamp when issuance ends. 0 => continue forever
        uint144 cumSIRperTEA; // Q104.40, cumulative SIR minted by the vaultId per unit of TEA.
    }

    struct SystemParameters {
        // Timestamp when issuance (re)started. 0 => issuance has not started yet
        uint40 tsIssuanceStart;
        /**
         * Base fee in basis points charged to apes per unit of liquidity, so fee = baseFee/1e4*(l-1).
         * For example, in a vaultId with 3x target leverage, apes are charged 2*baseFee/1e4 on minting and on burning.
         */
        uint16 baseFee; // Base fee in basis points. Given type(uint16).max, the max baseFee is 655.35%.
        uint8 lpFee; // Base fee in basis points. Given type(uint8).max, the max baseFee is 2.56%.
        bool emergencyStop;
    }

    uint256[] activeVaults;
    mapping(uint256 vaultId => VaultIssuanceParams) internal _vaultsIssuanceParams;
    mapping(uint256 vaultId => mapping(address => LPerIssuanceParams)) private _lpersIssuances;

    SystemParameters public systemParams =
        SystemParameters({
            tsIssuanceStart: 0,
            baseFee: 5000, // Test start base fee with 50% base on analysis from SQUEETH
            lpFee: 50,
            emergencyStop: false // Emergency stop is off
        });

    constructor(address systemControl_) SystemCommons(systemControl_) {}

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function vaultIssuanceParams(uint256 vaultId) public view returns (VaultIssuanceParams memory) {
        unchecked {
            // Get the vault issuance parameters
            VaultIssuanceParams memory vaultIssuanceParams_ = _vaultsIssuanceParams[vaultId];

            // Return the current vault issuance parameters if no SIR is issued, or it has already been updated
            if (
                systemParams.tsIssuanceStart == 0 ||
                vaultIssuanceParams_.taxToDAO == 0 ||
                vaultIssuanceParams_.tsLastUpdate == uint40(block.timestamp) ||
                (vaultIssuanceParams_.tsIssuanceEnd != 0 &&
                    vaultIssuanceParams_.tsLastUpdate >= vaultIssuanceParams_.tsIssuanceEnd)
            ) return vaultIssuanceParams_;

            // Find starting time to compute cumulative SIR per unit of TEA
            uint40 tsStart = systemParams.tsIssuanceStart > vaultIssuanceParams_.tsLastUpdate
                ? systemParams.tsIssuanceStart
                : vaultIssuanceParams_.tsLastUpdate;

            // Find ending time to compute cumulative SIR per unit of TEA
            uint40 tsEnd = vaultIssuanceParams_.tsIssuanceEnd == 0 ||
                vaultIssuanceParams_.tsIssuanceEnd > block.timestamp
                ? uint40(block.timestamp)
                : vaultIssuanceParams_.tsIssuanceEnd;

            // Aggregate SIR issued before the first 3 years. Issuance is slightly lower during the first 3 years because some is diverged to contributors.
            uint40 ts3Years = systemParams.tsIssuanceStart + _THREE_YEARS;
            if (tsStart < ts3Years) {
                uint256 issuance = (uint256(_AGG_ISSUANCE_VAULTS) * vaultIssuanceParams_.taxToDAO) /
                    vaultIssuanceParams_.aggTaxesToDAO;
                vaultIssuanceParams_.cumSIRperTEA += uint144(
                    ((issuance * ((tsEnd > ts3Years ? ts3Years : tsEnd) - tsStart)) << 40) / totalSupply[vaultId]
                );
            }

            // Aggregate SIR issued after the first 3 years
            if (tsEnd > ts3Years) {
                uint256 issuance = (uint256(ISSUANCE) * vaultIssuanceParams_.taxToDAO) /
                    vaultIssuanceParams_.aggTaxesToDAO;
                vaultIssuanceParams_.cumSIRperTEA += uint144(
                    ((issuance * (tsEnd - (tsStart > ts3Years ? tsStart : ts3Years))) << 40) / totalSupply[vaultId]
                );
            }

            // Update timestamp
            vaultIssuanceParams_.tsLastUpdate = uint40(block.timestamp);

            return vaultIssuanceParams_;
        }
    }

    function lperIssuanceParams(uint256 vaultId, address lper) external view returns (LPerIssuanceParams memory) {
        return _lperIssuanceParams(vaultId, lper, vaultIssuanceParams(vaultId));
    }

    function _lperIssuanceParams(
        uint256 vaultId,
        address lper,
        VaultIssuanceParams memory vaultIssuanceParams_
    ) private view returns (LPerIssuanceParams memory lperIssuanceParams_) {
        // Get the lper issuance parameters
        lperIssuanceParams_ = _lpersIssuances[vaultId][lper];

        // Get the LPer balance of TEA
        uint256 balance = balanceOf[lper][vaultId];

        // If LPer has no TEA
        if (balance == 0) return lperIssuanceParams_;

        // If rewards need to be updated
        if (vaultIssuanceParams_.cumSIRperTEA != lperIssuanceParams_.cumSIRperTEA) {
            lperIssuanceParams_.rewards += uint104(
                (balance * uint256(vaultIssuanceParams_.cumSIRperTEA - lperIssuanceParams_.cumSIRperTEA)) >> 40
            );
            lperIssuanceParams_.cumSIRperTEA = vaultIssuanceParams_.cumSIRperTEA;
        }
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/
    /**
     * @dev To be called BEFORE minting/burning TEA
     */
    function _updateIssuanceParams(uint256 vaultId, address lper) internal override {
        // If issuance has not started, return
        if (systemParams.tsIssuanceStart == 0) return;

        // Retrieve updated vault issuance parameters
        VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams(vaultId);

        // Update storage
        _vaultsIssuanceParams[vaultId] = vaultIssuanceParams_;

        // Update LPer issuances params
        _lpersIssuances[vaultId][lper] = _lperIssuanceParams(vaultId, lper, vaultIssuanceParams_);
    }

    /**
     * @dev To be called BEFORE transfering TEA
     */
    function _updateLPerIssuanceParams(uint256 vaultId, address lper0, address lper1) internal override {
        // If issuance has not started, return
        if (systemParams.tsIssuanceStart == 0) return;

        // Retrieve updated vault issuance parameters
        VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams(vaultId);

        // Update lpers issuances params
        _lpersIssuances[vaultId][lper0] = _lperIssuanceParams(vaultId, lper0, vaultIssuanceParams_);
        _lpersIssuances[vaultId][lper1] = _lperIssuanceParams(vaultId, lper1, vaultIssuanceParams_);
    }

    /*////////////////////////////////////////////////////////////////
                            VAULT ACCESS FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    // I INCLUDE CHECKS HERE, BUT MOVE THEM TO SYSTEMCONTROL IF CONTRACT IS TOO LARGE OR JUST MAKE SURE IT CANNOT HAPPEN.

    function updateSystemParameters(
        uint40 tsIssuanceStart,
        uint16 baseFee,
        uint8 lpFee,
        bool emergencyStop
    ) external onlySystemControl {
        SystemParameters memory systemParams_ = systemParams;

        require(tsIssuanceStart == 0 || (systemParams_.tsIssuanceStart == 0 && tsIssuanceStart >= block.timestamp));

        if (tsIssuanceStart != systemParams_.tsIssuanceStart) emit IssuanceStart(tsIssuanceStart);
        if (baseFee != systemParams.baseFee || lpFee != systemParams.lpFee) emit NewFees(baseFee, lpFee);
        if (emergencyStop != systemParams_.emergencyStop) emit EmergencyStop(emergencyStop);

        systemParams = SystemParameters({
            tsIssuanceStart: tsIssuanceStart == 0 ? systemParams_.tsIssuanceStart : tsIssuanceStart,
            baseFee: baseFee,
            lpFee: lpFee,
            emergencyStop: emergencyStop
        });
    }

    /** @dev Imperative this calls less gas than newVaultIssuances to ensure issuances can always be changed.
        @dev So if newVaultIssuances costs less gas than 1 block, so does stopVaultIssuances.
     */
    function stopVaultIssuances() external onlySystemControl {
        uint256 lenActiveVaults = activeVaults.length;
        for (uint256 i = 0; i < lenActiveVaults; ++i) _vaultsIssuanceParams[i].tsIssuanceEnd = uint40(block.timestamp);

        delete activeVaults;
    }

    /// @dev Important to call stopVaultIssuances before calling this function
    function newVaultIssuances(uint40[] calldata vaults, uint16[] calldata taxesToDAO) external onlySystemControl {
        uint256 lenVaults = vaults.length;
        require(lenVaults == taxesToDAO.length);

        // Compute aggregated taxes
        uint16 aggTaxesToDAO;
        for (uint256 i = 0; i < lenVaults; ++i) aggTaxesToDAO += taxesToDAO[i];

        // Start new issuances
        VaultIssuanceParams memory vaultIssuanceParams_;
        for (uint256 i = 0; i < lenVaults; ++i) {
            vaultIssuanceParams_ = vaultIssuanceParams(vaults[i]);

            vaultIssuanceParams_.taxToDAO = taxesToDAO[i]; // New issuance allocation
            vaultIssuanceParams_.aggTaxesToDAO = aggTaxesToDAO;
            vaultIssuanceParams_.tsLastUpdate = uint40(block.timestamp);
            vaultIssuanceParams_.tsIssuanceEnd = 0; // No forseable end to the allocation

            _vaultsIssuanceParams[vaults[i]] = vaultIssuanceParams_;
        }
    }
}
