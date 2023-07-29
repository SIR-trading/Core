// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Contracts
import {MAAM} from "./MAAM.sol";
import {SystemCommons} from "./SystemCommons.sol";

contract SystemState is SystemCommons, MAAM {
    struct LPerIssuanceParams {
        uint128 cumSIRperMAAM; // Q104.24, cumulative SIR minted by an LPer per unit of MAAM
        uint104 rewards; // SIR owed to the LPer. 104 bits is enough to store the balance even if all SIR issued in +1000 years went to a single LPer
    }

    // ADD tsEnd TO EASILY FINISH ISSUANCE?!
    struct VaultIssuanceParams {
        uint16 taxToDAO; // (taxToDAO / type(uint16).max * 10%) of its fee revenue is directed to the DAO.
        uint72 issuance; // [SIR/s] Assert that issuance <= ISSUANCE
        uint40 tsLastUpdate; // timestamp of the last time cumSIRperMAAM was updated. 0 => use systemParams.tsIssuanceStart instead
        uint128 cumSIRperMAAM; // Q104.24, cumulative SIR minted by the vaultId per unit of MAAM.
    }

    struct SystemParameters {
        // Timestamp when issuance (re)started. 0 => issuance has not started yet
        uint40 tsIssuanceStart;
        /**
         * Base fee in basis points charged to apes per unit of liquidity, so fee = baseFee/1e4*(l-1).
         * For example, in a vaultId with 3x target leverage, apes are charged 2*baseFee/1e4 on minting and on burning.
         */
        uint16 baseFee; // Given type(uint16).max, the max baseFee is 655.35%.
        uint72 issuanceTotalVaults; // Tokens issued per second excluding tokens issued to contributorsReceivingSIR
        bool emergencyStop;
    }

    mapping(uint256 vaultId => VaultIssuanceParams) internal _vaultsIssuanceParams;
    mapping(uint256 vaultId => mapping(address => LPerIssuanceParams)) internal _lpersIssuances;

    SystemParameters public systemParams =
        SystemParameters({
            tsIssuanceStart: 0,
            baseFee: 5000, // Test start base fee with 50% base on analysis from SQUEETH
            emergencyStop: false, // Emergency stop is off
            issuanceTotalVaults: ISSUANCE // All issuance go to the vaults by default (no contributors)
        });

    constructor(address systemControl_) SystemCommons(systemControl_) {}

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function vaultsIssuanceParams(uint256 vaultId) public view returns (VaultIssuanceParams memory) {
        // Get the vault issuance parameters
        VaultIssuanceParams memory vaultIssuanceParams = _vaultsIssuanceParams[vaultId];

        // Return the current vault issuance parameters if no SIR is issued, or it has already been updated
        if (
            systemParams.tsIssuanceStart == 0 ||
            vaultIssuanceParams.issuance == 0 ||
            vaultIssuanceParams.tsLastUpdate == uint40(block.timestamp)
        ) return vaultIssuanceParams;

        // Compute the cumulative SIR per unit of MAAM, if it has not been updated in this block
        bool rewardsNeverUpdated = systemParams.tsIssuanceStart > vaultIssuanceParams.tsLastUpdate;
        vaultIssuanceParams.cumSIRperMAAM +=
            ((
                uint128(vaultIssuanceParams.issuance) *
                    uint128(
                        uint40(block.timestamp) -
                            (rewardsNeverUpdated ? systemParams.tsIssuanceStart : contributorParams.tsLastUpdate)
                    ),
                b,
                denominator
            ) << 24) /
            totalSupply[vaultId];

        // Update timestamp
        vaultIssuanceParams.tsLastUpdate = uint40(block.timestamp);

        return vaultIssuanceParams;
    }

    function lperIssuanceParams(
        uint256 vaultId,
        address lper
    ) public view returns (LPerIssuanceParams memory lperIssuanceParams) {
        // Get the lper issuance parameters
        lperIssuanceParams = _lpersIssuances[vaultId][lper];

        // Get the LPer balance of MAAM
        uint256 balance = balanceOf[lper][vaultId];

        // If LPer has no MAAM
        if (balance == 0) return lperIssuanceParams;

        // If rewards need to be updated
        VaultIssuanceParams memory vaultIssuanceParams = _vaultsIssuanceParams[vaultId];
        if (vaultIssuanceParams.cumSIRperMAAM != lperIssuanceParams.cumSIRperMAAM) {
            lperIssuanceParams.rewards += uint104(
                (balance * uint256(vaultIssuanceParams.cumSIRperMAAM - lperIssuanceParams.cumSIRperMAAM)) >> 24
            );
            lperIssuanceParams.cumSIRperMAAM = vaultIssuanceParams.cumSIRperMAAM;
        }
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @dev To be called BEFORE minting/burning MAAM in Vault.sol
     *     @dev Vault parameters get updated only once in the 1st tx in the block
     *     @dev LPer parameters get updated on every call
     *     @dev No-op unless caller is a vaultId
     */
    function _updateIssuances(uint256 vaultId, address[] memory lpers) internal override {
        // If issuance has not started, return
        if (systemParams.tsIssuanceStart == 0) return;

        // Get the vault issuance parameters
        VaultIssuanceParams memory vaultIssuanceParams = vaultsIssuanceParams(vaultId);

        // Update storage
        _vaultsIssuanceParams[vaultId] = vaultIssuanceParams;

        // Update lpers issuances params
        for (uint256 i = 0; i < lpers.length; i++) {
            LPerIssuanceParams memory lperIssuanceParams = lperIssuanceParams(vaultId, lpers[i]);
            _lpersIssuances[vaultId][lpers[i]] = lperIssuance;
        }
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
        uint40 tsIssuanceStart_,
        uint16 basisFee_,
        bool onlyWithdrawals_
    ) external onlySystemControl {
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

    function recalibrateVaultsIssuances(
        address[] calldata vaults,
        bytes16[] memory latestSuppliesMAAM,
        uint256 sumTaxes
    ) public onlySystemControl {
        // Reset issuance of prev vaults
        for (uint256 i = 0; i < vaults.length; i++) {
            // Update vaultId issuance params (they only get updated once per block thanks to function getCumSIRperMAAM)
            _vaultsIssuanceParams[vaultId[i]].vaultIssuance.cumSIRperMAAM = _getCumSIRperMAAM(
                vaults[i],
                latestSuppliesMAAM[i]
            );
            _vaultsIssuanceParams[vaultId[i]].vaultIssuance.tsLastUpdate = uint40(block.timestamp);
            if (sumTaxes == 0) {
                _vaultsIssuanceParams[vaultId[i]].vaultIssuance.taxToDAO = 0;
                _vaultsIssuanceParams[vaultId[i]].vaultIssuance.issuance = 0;
            } else {
                _vaultsIssuanceParams[vaultId[i]].vaultIssuance.issuance = uint72(
                    (systemParams.issuanceTotalVaults * _vaultsIssuanceParams[vaultId[i]].vaultIssuance.taxToDAO) /
                        sumTaxes
                );
            }
        }
    }

    function changeVaultsIssuances(
        address[] calldata prevVaults,
        bytes16[] memory latestSuppliesMAAM,
        address[] calldata nextVaults,
        uint16[] calldata taxesToDAO,
        uint256 sumTaxes
    ) external onlySystemControl returns (bytes32) {
        // Reset issuance of prev vaults
        recalibrateVaultsIssuances(prevVaults, latestSuppliesMAAM, 0);

        // Set next issuances
        for (uint256 i = 0; i < nextVaults.length; i++) {
            _vaultsIssuanceParams[nextVaults[i]].vaultIssuance.tsLastUpdate = uint40(block.timestamp);
            _vaultsIssuanceParams[nextVaults[i]].vaultIssuance.taxToDAO = taxesToDAO[i];
            _vaultsIssuanceParams[nextVaults[i]].vaultIssuance.issuance = uint72(
                (systemParams.issuanceTotalVaults * taxesToDAO[i]) / sumTaxes
            );
        }

        return keccak256(abi.encodePacked(nextVaults));
    }

    /*////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _getLPerIssuance(
        uint256 vaultId,
        ResettableBalancesBytes16.ResettableBalances memory nonRebasingBalances,
        address LPer,
        bytes16 nonRebasingSupplyExcVault
    ) internal view returns (LPerIssuanceParams memory lperIssuance) {
        /**
         * Update cumSIRperMAAM
         */
        lperIssuance.cumSIRperMAAM = _getCumSIRperMAAM(vaultId, nonRebasingSupplyExcVault);

        /**
         * Update lperIssuance.rewards taking into account any possible liquidation events
         */
        // Find event that liquidated the LPer if it existed
        uint256 i = _vaultsIssuanceParams[vaultId]._lpersIssuances[LPer].indexLiquidations;
        while (
            i < _vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM.length &&
            _vaultsIssuanceParams[vaultId]._lpersIssuances[LPer].cumSIRperMAAM.cmp(
                _vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM[i]
            ) >=
            0
        ) {
            i++;
        }

        /**
         * Find out if we must use
         *             nonRebasingBalances.get(LPer)
         *             lperIssuance.cumSIRperMAAM
         *         or
         *             nonRebasingBalances.timestampedBalances[LPer].balance
         *             _vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM[i]
         */
        bool liquidated = i < _vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM.length;

        // Compute rewards
        lperIssuance.rewards =
            _vaultsIssuanceParams[vaultId]._lpersIssuances[LPer].rewards +
            uint104(
                (liquidated ? _vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM[i] : lperIssuance.cumSIRperMAAM)
                    .mul(
                        liquidated
                            ? nonRebasingBalances.timestampedBalances[LPer].balance
                            : nonRebasingBalances.get(LPer)
                    )
                    .toUInt()
            );

        /**
         * Update lperIssuance.indexLiquidations
         */
        lperIssuance.indexLiquidations = _vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM.length <
            type(uint24).max
            ? uint24(_vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM.length)
            : type(uint24).max;
    }
}
