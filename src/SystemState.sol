// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {SystemConstants} from "./libraries/SystemConstants.sol";

contract SystemState is SystemConstants {
    struct LPerIssuanceParams {
        uint128 cumSIRperMAAM; // Q104.24, cumulative SIR minted by an LPer per unit of MAAM
        uint104 rewards; // SIR owed to the LPer. 104 bits is enough to store the balance even if all SIR issued in +1000 years went to a single LPer
    }

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

    modifier onlySystemControl() {
        _onlySystemControl();
        _;
    }

    address public immutable systemControl;

    mapping(uint256 vaultId => VaultIssuanceParams) internal vaultsIssuanceParams;
    mapping(uint256 vaultId => mapping(address => LPerIssuanceParams)) internal lpersIssuances;

    SystemParameters public systemParams =
        SystemParameters({
            tsIssuanceStart: 0,
            baseFee: 5000, // Test start base fee with 50% base on analysis from SQUEETH
            emergencyStop: false, // Emergency stop is off
            issuanceTotalVaults: ISSUANCE // All issuance go to the vaults by default (no contributors)
        });

    constructor(address systemControl_) {
        systemControl = systemControl_;
    }

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function totalSupply(uint256 vaultId) public view virtual returns (uint256);

    function getVaultsIssuanceParams(uint256 vaultId) public view returns (VaultIssuanceParams memory) {
        // Get the vault issuance parameters
        VaultIssuanceParams memory vaultIssuanceParams = vaultsIssuanceParams[vaultId];

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
            totalSupply(vaultId);

        // Update timestamp
        vaultIssuanceParams.tsLastUpdate = uint40(block.timestamp);

        return vaultIssuanceParams;
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
    function updateIssuances(uint256 vaultId, address[] memory lpers, uint256[] memory balances) internal {
        // If issuance has not started, return
        if (systemParams.tsIssuanceStart == 0) return;

        // Get the vault issuance parameters
        VaultIssuanceParams memory vaultIssuanceParams = getVaultsIssuanceParams(vaultId);

        // Update storage
        vaultsIssuanceParams[vaultId] = vaultIssuanceParams;

        // Update lpers issuances params
        // REDO THIS!!!!!!!!
        for (uint256 i = 0; i < lpers.length; i++) {
            LPerIssuanceParams memory lperIssuance = _getLPerIssuance(
                vaultId,
                nonRebasingBalances,
                lpers[i],
                nonRebasingSupplyExcVault
            );
            vaultsIssuanceParams[vaultId].lpersIssuances[lpers[i]] = lperIssuance;
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
            vaultsIssuanceParams[vaultId[i]].vaultIssuance.cumSIRperMAAM = _getCumSIRperMAAM(
                vaults[i],
                latestSuppliesMAAM[i]
            );
            vaultsIssuanceParams[vaultId[i]].vaultIssuance.tsLastUpdate = uint40(block.timestamp);
            if (sumTaxes == 0) {
                vaultsIssuanceParams[vaultId[i]].vaultIssuance.taxToDAO = 0;
                vaultsIssuanceParams[vaultId[i]].vaultIssuance.issuance = 0;
            } else {
                vaultsIssuanceParams[vaultId[i]].vaultIssuance.issuance = uint72(
                    (systemParams.issuanceTotalVaults * vaultsIssuanceParams[vaultId[i]].vaultIssuance.taxToDAO) /
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
            vaultsIssuanceParams[nextVaults[i]].vaultIssuance.tsLastUpdate = uint40(block.timestamp);
            vaultsIssuanceParams[nextVaults[i]].vaultIssuance.taxToDAO = taxesToDAO[i];
            vaultsIssuanceParams[nextVaults[i]].vaultIssuance.issuance = uint72(
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
        uint256 i = vaultsIssuanceParams[vaultId].lpersIssuances[LPer].indexLiquidations;
        while (
            i < vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM.length &&
            vaultsIssuanceParams[vaultId].lpersIssuances[LPer].cumSIRperMAAM.cmp(
                vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM[i]
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
         *             vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM[i]
         */
        bool liquidated = i < vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM.length;

        // Compute rewards
        lperIssuance.rewards =
            vaultsIssuanceParams[vaultId].lpersIssuances[LPer].rewards +
            uint104(
                (liquidated ? vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM[i] : lperIssuance.cumSIRperMAAM)
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
        lperIssuance.indexLiquidations = vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM.length <
            type(uint24).max
            ? uint24(vaultsIssuanceParams[vaultId].liquidationsCumSIRperMAAM.length)
            : type(uint24).max;
    }

    function _onlySystemControl() private view {
        require(msg.sender == systemControl);
    }
}
