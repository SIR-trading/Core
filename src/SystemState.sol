// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {TEA, IERC20} from "./TEA.sol";
import {SystemCommons} from "./SystemCommons.sol";

abstract contract SystemState is SystemCommons, TEA {
    struct VaultIssuanceParams {
        uint16 taxToDAO; // (taxToDAO / type(uint16).max * 10%) of its fee revenue is directed to the DAO.
        uint40 tsLastUpdate; // timestamp of the last time cumSIRperTEA was updated. 0 => use systemParams.tsIssuanceStart instead
        uint152 cumSIRperTEA; // Q104.48, cumulative SIR minted by the vaultId per unit of TEA.
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
        uint184 aggTaxesToDAO; // Aggregated taxToDAO of all vaults
    }

    address private immutable _SIR;

    mapping(uint256 vaultId => VaultIssuanceParams) internal _vaultsIssuanceParams;
    mapping(uint256 vaultId => mapping(address => LPerIssuanceParams)) private _lpersIssuances;

    SystemParameters public systemParams =
        SystemParameters({
            tsIssuanceStart: 0,
            baseFee: 5000, // Test start base fee with 50% base on analysis from SQUEETH
            lpFee: 50,
            emergencyStop: false, // Emergency stop is off
            aggTaxesToDAO: 0
        });

    /** This is the hash of the active vaults. It is used to make sure active vaults's issuances are nulled
        before new issuance parameters are stored. This is more gas efficient that storing all active vaults
        in an arry, but it requires that system control keeps track of the active vaults.
        If the vaults were in an unknown order, it maybe be problem because the hash would change.
        So by default the vaults must be ordered in increasing order.

        The default value is the hash of an empty array.
     */
    // bytes32 private _hashActiveVaults = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    constructor(address systemControl, address sir) SystemCommons(systemControl) {
        _SIR = sir;
    }

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function vaultIssuanceParams(uint256 vaultId) public view returns (VaultIssuanceParams memory) {
        unchecked {
            SystemParameters memory systemParams_ = systemParams;

            // Get the vault issuance parameters
            VaultIssuanceParams memory vaultIssuanceParams_ = _vaultsIssuanceParams[vaultId];

            // Update timestamp
            vaultIssuanceParams_.tsLastUpdate = uint40(block.timestamp);

            // Return the current vault issuance parameters if no SIR is issued, or it has already been updated
            if (
                systemParams_.tsIssuanceStart == 0 ||
                vaultIssuanceParams_.taxToDAO == 0 ||
                vaultIssuanceParams_.tsLastUpdate == uint40(block.timestamp)
            ) return vaultIssuanceParams_;

            // Find starting time to compute cumulative SIR per unit of TEA
            uint40 tsStart = systemParams_.tsIssuanceStart > vaultIssuanceParams_.tsLastUpdate
                ? systemParams_.tsIssuanceStart
                : vaultIssuanceParams_.tsLastUpdate;

            // Aggregate SIR issued before the first 3 years. Issuance is slightly lower during the first 3 years because some is diverged to contributors.
            uint40 ts3Years = systemParams_.tsIssuanceStart + _THREE_YEARS;
            if (tsStart < ts3Years) {
                uint256 issuance = (uint256(_AGG_ISSUANCE_VAULTS) * vaultIssuanceParams_.taxToDAO) /
                    systemParams_.aggTaxesToDAO;
                vaultIssuanceParams_.cumSIRperTEA += uint152(
                    ((issuance *
                        ((uint40(block.timestamp) > ts3Years ? ts3Years : uint40(block.timestamp)) - tsStart)) << 48) /
                        totalSupply[vaultId]
                );
            }

            // Aggregate SIR issued after the first 3 years
            if (uint40(block.timestamp) > ts3Years) {
                uint256 issuance = (uint256(ISSUANCE) * vaultIssuanceParams_.taxToDAO) / systemParams_.aggTaxesToDAO;
                vaultIssuanceParams_.cumSIRperTEA += uint152(
                    ((issuance * (uint40(block.timestamp) - (tsStart > ts3Years ? tsStart : ts3Years))) << 48) /
                        totalSupply[vaultId]
                );
            }

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
        unchecked {
            // Get the lper issuance parameters
            lperIssuanceParams_ = _lpersIssuances[vaultId][lper];

            // Get the LPer balance of TEA
            uint256 balance = balanceOf[lper][vaultId];

            // If LPer has no TEA
            if (balance == 0) return lperIssuanceParams_;

            // If unclaimedRewards need to be updated
            if (vaultIssuanceParams_.cumSIRperTEA != lperIssuanceParams_.cumSIRperTEA) {
                /** Cannot OF/UF because:
                    (1) balance * vaultIssuanceParams_.cumSIRperTEA ≤ issuance * 1000 years * 2^48 ≤ 2^104 * 2^48
                    (2) vaultIssuanceParams_.cumSIRperTEA ≥ lperIssuanceParams_.cumSIRperTEA
                 */
                lperIssuanceParams_.unclaimedRewards += uint104(
                    (balance * uint256(vaultIssuanceParams_.cumSIRperTEA - lperIssuanceParams_.cumSIRperTEA)) >> 48
                );
                lperIssuanceParams_.cumSIRperTEA = vaultIssuanceParams_.cumSIRperTEA;
            }
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

    function updateLPerIssuanceParams(uint256 vaultId, address lper) external returns (uint104 unclaimedRewards) {
        require(msg.sender == _SIR);

        // If issuance has not started, return
        if (systemParams.tsIssuanceStart == 0) return 0;

        // Retrieve updated vault issuance parameters
        VaultIssuanceParams memory vaultIssuanceParams_ = vaultIssuanceParams(vaultId);

        // Retrieve updated LPer issuance parameters
        LPerIssuanceParams memory lperIssuanceParams_ = _lperIssuanceParams(vaultId, lper, vaultIssuanceParams_);
        unclaimedRewards = lperIssuanceParams_.unclaimedRewards;

        // Update lpers issuances params
        lperIssuanceParams_.unclaimedRewards = 0;
        _lpersIssuances[vaultId][lper] = _lperIssuanceParams(vaultId, lper, vaultIssuanceParams_);
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function updateSystemState(
        uint40 tsIssuanceStart_,
        uint16 baseFee_,
        uint8 lpFee_,
        bool isEmergency,
        bool isNotEmergency,
        uint40[] calldata oldVaults,
        uint40[] calldata newVaults,
        uint16[] calldata newTaxes
    ) external onlySystemControl {
        if (tsIssuanceStart_ != 0) {
            require(systemParams.tsIssuanceStart == 0 && tsIssuanceStart_ >= block.timestamp);
            systemParams.tsIssuanceStart = tsIssuanceStart_;
        } else if (baseFee_ != 0) systemParams.baseFee = baseFee_;
        else if (lpFee_ != 0) systemParams.lpFee = lpFee_;
        else if (isEmergency) {
            require(!systemParams.emergencyStop);
            systemParams.emergencyStop = true;
        } else if (isNotEmergency) {
            require(systemParams.emergencyStop);
            systemParams.emergencyStop = false;
        } else {
            VaultIssuanceParams memory vaultIssuanceParams_;

            // Stop old issuances
            uint256 lenVaults = oldVaults.length;
            for (uint256 i = 0; i < lenVaults; ++i) {
                // Retrieve the vault's current issuance state and parameters
                vaultIssuanceParams_ = vaultIssuanceParams(oldVaults[i]);

                // Nul tax, and consequently nul issuance
                vaultIssuanceParams_.taxToDAO = 0;

                // Update storage
                _vaultsIssuanceParams[oldVaults[i]] = vaultIssuanceParams_;
            }

            // Aggregate taxes and squared taxes
            lenVaults = newVaults.length;
            uint184 aggTaxesToDAO;
            for (uint256 i = 0; i < lenVaults; ++i) {
                aggTaxesToDAO += newTaxes[i];
            }

            // Start new issuances
            for (uint256 i = 0; i < lenVaults; ++i) {
                // if (i > 0) require(newVaults[i] > newVaults[i - 1]); // Ensure increasing order

                // Retrieve the vault's current issuance state and parameters
                vaultIssuanceParams_ = vaultIssuanceParams(newVaults[i]);

                // Nul tax, and consequently nul issuance
                vaultIssuanceParams_.taxToDAO = newTaxes[i];

                // Update storage
                _vaultsIssuanceParams[newVaults[i]] = vaultIssuanceParams_;
            }

            // Update storage
            systemParams.aggTaxesToDAO = aggTaxesToDAO;
        }
    }
}
