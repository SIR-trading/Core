// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {TEA, IERC20} from "./TEA.sol";
import {SystemCommons} from "./SystemCommons.sol";
import {VaultStructs} from "./libraries/VaultStructs.sol";
import "forge-std/Test.sol";

contract SystemState is SystemCommons, TEA {
    struct VaultIssuanceParams {
        uint16 taxToDAO; // (taxToDAO / type(uint16).max * 10%) of its fee revenue is directed to the DAO.
        uint40 tsLastUpdate; // timestamp of the last time cumSIRPerTEA was updated. 0 => use systemParams.tsIssuanceStart instead
        uint152 cumSIRPerTEA; // Q104.48, cumulative SIR minted by the vaultId per unit of TEA.
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
            cumTaxes: 0
        });

    /** This is the hash of the active vaults. It is used to make sure active vaults's issuances are nulled
        before new issuance parameters are stored. This is more gas efficient that storing all active vaults
        in an arry, but it requires that system control keeps track of the active vaults.
        If the vaults were in an unknown order, it maybe be problem because the hash would change.
        So by default the vaults must be ordered in increasing order.

        The default value is the hash of an empty array.
     */
    // bytes32 private _hashActiveVaults = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    constructor(
        address systemControl,
        address sir,
        address vaultExternal
    ) SystemCommons(systemControl) TEA(vaultExternal) {
        _SIR = sir;
    }

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function cumulativeSIRPerTEA(uint256 vaultId) public view returns (uint152 cumSIRPerTEA) {
        unchecked {
            VaultStructs.SystemParameters memory systemParams_ = systemParams;

            // Get the vault issuance parameters
            VaultIssuanceParams memory vaultIssuanceParams_ = _vaultsIssuanceParams[vaultId];
            cumSIRPerTEA = vaultIssuanceParams_.cumSIRPerTEA;

            // Do nothing if no new SIR has been issued, or it has already been updated
            uint256 totalSupply_ = totalSupply[vaultId];
            if (
                systemParams_.tsIssuanceStart != 0 &&
                vaultIssuanceParams_.taxToDAO != 0 &&
                vaultIssuanceParams_.tsLastUpdate != uint40(block.timestamp) &&
                totalSupply_ != 0
            ) {
                // Find starting time to compute cumulative SIR per unit of TEA
                uint40 tsStart = systemParams_.tsIssuanceStart > vaultIssuanceParams_.tsLastUpdate
                    ? systemParams_.tsIssuanceStart
                    : vaultIssuanceParams_.tsLastUpdate;

                // Aggregate SIR issued before the first 3 years. Issuance is slightly lower during the first 3 years because some is diverged to contributors.
                uint40 ts3Years = systemParams_.tsIssuanceStart + THREE_YEARS;
                // console.log("tsStart", tsStart);
                // console.log("ts3Years", ts3Years);
                if (tsStart < ts3Years) {
                    uint256 issuance = (uint256(AGG_ISSUANCE_VAULTS) * vaultIssuanceParams_.taxToDAO) /
                        systemParams_.cumTaxes;
                    cumSIRPerTEA += uint152(
                        ((issuance *
                            ((uint40(block.timestamp) > ts3Years ? ts3Years : uint40(block.timestamp)) - tsStart)) <<
                            48) / totalSupply_
                    );
                    // console.log("cumSIRPerTEA", cumSIRPerTEA);
                }

                // Aggregate SIR issued after the first 3 years
                console.log("uint40(block.timestamp)", uint40(block.timestamp));
                console.log("ts3Years", ts3Years);
                if (uint40(block.timestamp) > ts3Years) {
                    console.log("time interval", uint40(block.timestamp) - (tsStart > ts3Years ? tsStart : ts3Years));
                    uint256 issuance = (uint256(ISSUANCE) * vaultIssuanceParams_.taxToDAO) / systemParams_.cumTaxes;
                    console.log("issuance", issuance);
                    console.log("contract cumSIRPerTEA", cumSIRPerTEA);
                    cumSIRPerTEA += uint152(
                        (((issuance * (uint40(block.timestamp) - (tsStart > ts3Years ? tsStart : ts3Years))) << 48) /
                            totalSupply_)
                    );
                    console.log("contract cumSIRPerTEA", cumSIRPerTEA);
                }
            }
        }
    }

    function unclaimedRewards(uint256 vaultId, address lper) external view returns (uint104) {
        return _unclaimedRewards(vaultId, lper, cumulativeSIRPerTEA(vaultId));
    }

    function _unclaimedRewards(uint256 vaultId, address lper, uint152 cumSIRPerTEA) private view returns (uint104) {
        unchecked {
            // Get the lper issuance parameters
            LPerIssuanceParams memory lperIssuanceParams_ = _lpersIssuances[vaultId][lper];

            // Get the LPer balance of TEA
            uint256 balance = balanceOf[lper][vaultId];

            // If LPer has no TEA
            if (balance == 0) return lperIssuanceParams_.unclaimedRewards;

            /** Cannot OF/UF because:
                    (1) balance * cumSIRPerTEA ≤ issuance * 1000 years * 2^48 ≤ 2^104 * 2^48
                    (2) cumSIRPerTEA ≥ lperIssuanceParams_.cumSIRPerTEA
                 */
            return
                lperIssuanceParams_.unclaimedRewards +
                uint104((balance * uint256(cumSIRPerTEA - lperIssuanceParams_.cumSIRPerTEA)) >> 48);
        }
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function updateLPerIssuanceParams(uint256 vaultId, address lper) external returns (uint104) {
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
    ) internal override returns (uint104 unclaimedRewards0) {
        // If issuance has not started, return
        if (systemParams.tsIssuanceStart == 0) return 0;

        // Retrieve updated vault issuance parameters
        uint152 cumSIRPerTEA = cumulativeSIRPerTEA(vaultId);
        console.log("contract cumSIRPerTEA", cumSIRPerTEA);

        // Retrieve updated LPer issuance parameters
        unclaimedRewards0 = _unclaimedRewards(vaultId, lper0, cumSIRPerTEA);

        // Update LPer0 issuance parameters
        _lpersIssuances[vaultId][lper0] = LPerIssuanceParams(cumSIRPerTEA, sirIsCaller ? 0 : unclaimedRewards0);

        if (lper1 != address(0))
            /** Transfer of TEA
                1. Must update the destinatary's issuance parameters too
                2. Valut issuance does not need to be updated because totalSupply does not change
             */
            _lpersIssuances[vaultId][lper1] = LPerIssuanceParams(
                cumSIRPerTEA,
                _unclaimedRewards(vaultId, lper1, cumSIRPerTEA)
            );
        else {
            /** Mint or burn TEA
                1. Must update the vault's issuance
             */
            _vaultsIssuanceParams[vaultId].cumSIRPerTEA = cumSIRPerTEA;
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
        uint16[] calldata newTaxes,
        uint184 cumTaxes
    ) external onlySystemControl {
        // Stop old issuances
        for (uint256 i = 0; i < oldVaults.length; ++i) {
            // Retrieve the vault's current cumulative SIR per unit of TEA
            uint152 cumSIRPerTEA = cumulativeSIRPerTEA(oldVaults[i]);

            // Update vault issuance parameters
            _vaultsIssuanceParams[oldVaults[i]] = VaultIssuanceParams({
                taxToDAO: 0, // Nul tax, and consequently nul SIR issuance
                tsLastUpdate: uint40(block.timestamp),
                cumSIRPerTEA: cumSIRPerTEA
            });
        }

        // Start new issuances
        for (uint256 i = 0; i < newVaults.length; ++i) {
            // Retrieve the vault's current cumulative SIR per unit of TEA
            uint152 cumSIRPerTEA = cumulativeSIRPerTEA(newVaults[i]);

            // Update vault issuance parameters
            _vaultsIssuanceParams[newVaults[i]] = VaultIssuanceParams({
                taxToDAO: newTaxes[i],
                tsLastUpdate: uint40(block.timestamp),
                cumSIRPerTEA: cumSIRPerTEA
            });
        }

        // Update cumulative taxes
        systemParams.cumTaxes = cumTaxes;
    }
}
