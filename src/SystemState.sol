// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {TEA, IERC20} from "./TEA.sol";
import {SystemCommons} from "./SystemCommons.sol";

abstract contract SystemState is SystemCommons, TEA {
    event IssuanceStart(uint40 tsIssuanceStart);

    struct LPerIssuanceParams {
        uint152 cumSIRperTEA; // Q104.48, cumulative SIR minted by an LPer per unit of TEA
        uint104 rewards; // SIR owed to the LPer. 104 bits is enough to store the balance even if all SIR issued in +1000 years went to a single LPer
    }

    struct VaultIssuanceParams {
        uint16 taxToDAO; // (taxToDAO / type(uint16).max * 10%) of its fee revenue is directed to the DAO.
        uint16 aggTaxesToDAO; // Aggregated taxToDAO of all vaults
        uint40 tsLastUpdate; // timestamp of the last time cumSIRperTEA was updated. 0 => use systemParams.tsIssuanceStart instead
        uint32 indexTsEndIssuance; // Points to the last timestamp in iussanceChanges that is smaller or equal than tsLastUpdate
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
    }

    struct IssuanceChange {
        uint40 timeStamp; // Time the issuance changed
        uint72 issuanceAggVaults; // SIR issued per second excluding contributors
    }

    /** iussanceChanges is an array of timestamps. Each timestamp corresponds to the end time of an issuance.
        Issuance of a vault ends at time min(t : tsLastUpdate < t , t ∈ iussanceChanges )
        A new timestamp is pused to iussanceChanges every time issuances are recalibrated, to end previous issuances. 
     */
    IssuanceChange[] iussanceChanges;
    mapping(uint256 vaultId => VaultIssuanceParams) internal _vaultsIssuanceParams;
    mapping(uint256 vaultId => mapping(address => LPerIssuanceParams)) internal _lpersIssuances;

    SystemParameters public systemParams =
        SystemParameters({
            tsIssuanceStart: 0,
            baseFee: 5000, // Test start base fee with 50% base on analysis from SQUEETH
            lpFee: 50,
            emergencyStop: false, // Emergency stop is off
            issuanceTotalVaults: ISSUANCE // All issuance go to the vaults by default (no contributors)
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
                vaultIssuanceParams_.tsLastUpdate == uint40(block.timestamp)
            ) return vaultIssuanceParams_;

            // Find starting time to compute cumulative SIR per unit of TEA
            uint40 tsStart = systemParams.tsIssuanceStart > vaultIssuanceParams_.tsLastUpdate
                ? systemParams.tsIssuanceStart
                : vaultIssuanceParams_.tsLastUpdate;

            // Find issuance change events that happened after tsStart
            uint256 lenTsEndIssuance = iussanceChanges.length;

            // Find the first issuance change that is relevant
            uint32 i;
            for (
                i = vaultIssuanceParams_.indexTsEndIssuance;
                i < lenTsEndIssuance && tsStart >= iussanceChanges[i].timeStamp;
                ++i
            ) {}
            // uint40 tsEnd = i == lenTsEndIssuance ? uint40(block.timestamp) : iussanceChanges[i];

            // Aggregate the SIR issued taking into account the the issuance changes
            uint40 tsEnd = uint40(block.timestamp);
            uint256 issuance;
            for (; i < lenTsEndIssuance; ++i) {
                // Compute the implicity issuance given taxToDAO
                issuance =
                    (uint256(iussanceChanges[i - 1].issuanceAggVaults) * vaultIssuanceParams_.taxToDAO) /
                    vaultIssuanceParams_.aggTaxesToDAO;

                // If it has not been updated in this block, compute the cumulative SIR per unit of TEA
                vaultIssuanceParams_.cumSIRperTEA += uint152(
                    ((issuance * (iussanceChanges[i].timeStamp - tsStart)) << 48) / totalSupply[vaultId]
                );

                // For the next iteration
                tsStart = iussanceChanges[i].timeStamp;

                if (iussanceChanges[i].issuanceAggVaults == 0) {
                    tsEnd = iussanceChanges[i].timeStamp;
                    break;
                }
            }

            // Aggregate remaining SIR issued if issuance has not ended
            if (i == lenTsEndIssuance) {
                issuance =
                    (uint256(iussanceChanges[lenTsEndIssuance - 1].issuanceAggVaults) * vaultIssuanceParams_.taxToDAO) /
                    vaultIssuanceParams_.aggTaxesToDAO;

                vaultIssuanceParams_.cumSIRperTEA += uint152(
                    ((issuance * (uint40(block.timestamp) - tsStart)) << 48) / totalSupply[vaultId]
                );
            }

            // Next time we start from this index
            vaultIssuanceParams_.indexTsEndIssuance = lenTsEndIssuance;
            // VERY IMPORTANT THAT WHEN DOING A NEW ISSUANCE ALLOCATION, ALL NEW POOLS ARE UPDATED WITH THIS FUNCTION

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
                (balance * uint256(vaultIssuanceParams_.cumSIRperTEA - lperIssuanceParams_.cumSIRperTEA)) >> 48
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

    /**
     * @dev Only one parameter can be updated at one. We use a single function to reduce bytecode size.
     */
    function updateSystemParameters(
        uint40 tsIssuanceStart,
        uint16 baseFee,
        uint8 lpFee,
        uint72 issuanceTotalVaults,
        bool emergencyStop
    ) external onlySystemControl {
        SystemParameters memory systemParams_ = systemParams;

        if (systemParams_.tsIssuanceStart == 0 && tsIssuanceStart > 0) {
            systemParams_.tsIssuanceStart = tsIssuanceStart;
            emit IssuanceStart(tsIssuanceStart);
        }

        if (tsIssuanceStart_ > 0) {
            require(systemParams.tsIssuanceStart == 0, "Issuance already started");
            systemParams.tsIssuanceStart = tsIssuanceStart_;
        } else if (basisFee_ > 0) {
            systemParams.baseFee = basisFee_;
        } else {
            systemParams.emergencyStop = onlyWithdrawals_;
        }
    }

    /*////////////////////////////////////////////////////////////////
                            ADMIN ISSUANCE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    // function recalibrateVaultsIssuances(
    //     address[] calldata vaults,
    //     bytes16[] memory latestSuppliesTEA,
    //     uint256 sumTaxes
    // ) public onlySystemControl {
    //     // Reset issuance of prev vaults
    //     for (uint256 i = 0; i < vaults.length; i++) {
    //         // Update vaultId issuance params (they only get updated once per block thanks to function getCumSIRperTEA)
    //         _vaultsIssuanceParams[vaultId[i]].vaultIssuance.cumSIRperTEA = _getCumSIRperTEA(
    //             vaults[i],
    //             latestSuppliesTEA[i]
    //         );
    //         _vaultsIssuanceParams[vaultId[i]].vaultIssuance.tsLastUpdate = uint40(block.timestamp);
    //         if (sumTaxes == 0) {
    //             _vaultsIssuanceParams[vaultId[i]].vaultIssuance.taxToDAO = 0;
    //             _vaultsIssuanceParams[vaultId[i]].vaultIssuance.issuance = 0;
    //         } else {
    //             _vaultsIssuanceParams[vaultId[i]].vaultIssuance.issuance = uint72(
    //                 (systemParams.issuanceTotalVaults * _vaultsIssuanceParams[vaultId[i]].vaultIssuance.taxToDAO) /
    //                     sumTaxes
    //             );
    //         }
    //     }
    // }

    // function changeVaultsIssuances(
    //     address[] calldata prevVaults,
    //     bytes16[] memory latestSuppliesTEA,
    //     address[] calldata nextVaults,
    //     uint16[] calldata taxesToDAO,
    //     uint256 sumTaxes
    // ) external onlySystemControl returns (bytes32) {
    //     // Reset issuance of prev vaults
    //     recalibrateVaultsIssuances(prevVaults, latestSuppliesTEA, 0);

    //     // Set next issuances
    //     for (uint256 i = 0; i < nextVaults.length; i++) {
    //         _vaultsIssuanceParams[nextVaults[i]].vaultIssuance.tsLastUpdate = uint40(block.timestamp);
    //         _vaultsIssuanceParams[nextVaults[i]].vaultIssuance.taxToDAO = taxesToDAO[i];
    //         _vaultsIssuanceParams[nextVaults[i]].vaultIssuance.issuance = uint72(
    //             (systemParams.issuanceTotalVaults * taxesToDAO[i]) / sumTaxes
    //         );
    //     }

    //     return keccak256(abi.encodePacked(nextVaults));
    // }
}
