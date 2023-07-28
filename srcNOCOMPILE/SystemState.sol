// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
contract SystemState {
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

    struct ContributorIssuanceParams {
        uint72 issuance; // [SIR/s]
        uint40 tsLastUpdate; // timestamp of the last mint. 0 => use systemParams.tsIssuanceStart instead
        uint104 rewards; // SIR owed to the contributor
    }

    struct VaultIssuanceState {
        VaultIssuanceParams vaultIssuance;
        mapping(address => LPerIssuanceParams) lpersIssuances;
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

    // Tokens issued per second
    uint72 public constant ISSUANCE = 1e2 * 1e18;
    uint40 private constant _THREE_YEARS = 3 * 365 days;

    address public immutable systemControl;

    mapping(address => ContributorIssuanceParams) internal _contributorsIssuances;
    mapping(uint256 vaultId => VaultIssuanceState) internal _vaultIssuanceStates;

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

    // MOVE IT TO SIR CONTRACT????
    function maxSupplySIR() external view returns (uint256) {
        if (systemParams.tsIssuanceStart == 0) return 0;

        return ISSUANCE * (block.timestamp - systemParams.tsIssuanceStart);
    }

    function getContributorIssuance(address contributor) public view returns (ContributorIssuanceParams memory) {
        if (systemParams.tsIssuanceStart == 0) return contributorParams; // Issuance has not started yet

        ContributorIssuanceParams memory contributorParams = _contributorsIssuances[contributor];

        // Last date of rewards
        uint40 tsIssuanceEnd = systemParams.tsIssuanceStart + _THREE_YEARS;

        // If rewards have already been updated for the last time
        if (contributorParams.tsLastUpdate >= tsIssuanceEnd) return contributorParams;

        // If  issuance is over but rewards have not been updated for the last time
        bool issuanceIsOver = uint40(block.timestamp) >= tsIssuanceEnd;

        // If rewards have never been updated
        bool rewardsNeverUpdated = systemParams.tsIssuanceStart > contributorParams.tsLastUpdate;

        contributorParams.rewards +=
            contributorParams.issuance *
            uint72(
                (issuanceIsOver ? tsIssuanceEnd : uint40(block.timestamp)) -
                    (rewardsNeverUpdated ? systemParams.tsIssuanceStart : contributorParams.tsLastUpdate)
            );
        contributorParams.issuance = 0;
        contributorParams.tsLastUpdate = uint40(block.timestamp);
    }

    /*////////////////////////////////////////////////////////////////
                            MINT EXTERNAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function contributorMint() external {
        // Get contributor issuance parameters
        ContributorIssuanceParams memory contributorParams = getContributorIssuance(msg.sender);

        // Mint if any rewards
        require(contributorParams.rewards > 0);
        _mint(msg.sender, contributorParams.rewards);

        // Update state
        contributorParams.rewards = 0;
        _contributorsIssuances[msg.sender] = contributorParams;
    }

    /**
        TO CHANGE: PERIPHERY IN CHARGE OF UPDATING VAULT ISSUANCE STATE
        SO WE CAN PASS FIRST REQUIRE
        Don't query vault here but just check its issuance has been updated.
        Assume issuances have been updated just before. The periphery would take care of this.
     */
    function LPerMint(uint256 vaultId) external {
        // Check issuance data is up to date
        require(_vaultIssuanceStates[vaultId].vaultIssuance.tsLastUpdate == uint40(block.timestamp));

        // Get LPer issuance parameters
        LPerIssuanceParams memory lperIssuance = _vaultIssuanceStates[vaultId].lpersIssuances[msg.sender];

        // Mint if any rewards
        require(lperIssuance.rewards > 0);
        _mint(msg.sender, lperIssuance.rewards);

        // Update state
        lperIssuance.rewards = 0;
        _vaultIssuanceStates[vaultId].lpersIssuances[msg.sender] = lperIssuance;
    }

    /*////////////////////////////////////////////////////////////////
                            VAULT ACCESS FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @dev To be called BEFORE minting/burning MAAM in Vault.sol
     *     @dev Vault parameters get updated only once in the 1st tx in the block
     *     @dev LPer parameters get updated on every call
     *     @dev No-op unless caller is a vaultId
     */
    function updateIssuances(
        uint256 vaultId,
        ResettableBalancesBytes16.ResettableBalances memory nonRebasingBalances,
        address[] memory LPers
    ) internal {
        // Issuances has not started
        if (systemParams.tsIssuanceStart == 0) return;

        // Get the MAAM total supply excluding the one owned by the vault
        bytes16 nonRebasingSupplyExcVault = nonRebasingBalances.nonRebasingSupply.subUp(
            _nonRebasingBalances.get(VAULT)
        );

        // Compute the cumulative SIR per unit of MAAM
        cumSIRperMAAM = _getCumSIRperMAAM(vaultId, nonRebasingSupplyExcVault);

        // Update vault's issuance params (they only get updated once per block)
        _vaultIssuanceStates[vaultId].vaultIssuance.cumSIRperMAAM = cumSIRperMAAM;
        _vaultIssuanceStates[vaultId].vaultIssuance.tsLastUpdate = uint40(block.timestamp);

        // Update LPers issuances params
        for (uint256 i = 0; i < LPers.length; i++) {
            LPerIssuanceParams memory lperIssuance = _getLPerIssuance(
                vaultId,
                nonRebasingBalances,
                LPers[i],
                nonRebasingSupplyExcVault
            );
            _vaultIssuanceStates[vaultId].lpersIssuances[LPers[i]] = lperIssuance;
        }
    }

    function haultIssuance(uint256 vaultId) internal {
        if (systemParams.tsIssuanceStart == 0 || _vaultIssuanceStates[vaultId].vaultIssuance.issuance == 0) return; // This vault gets no SIR anyway

        // Record the value of cumSIRperMAAM at the time of the liquidation event
        _vaultIssuanceStates[vaultId].liquidationsCumSIRperMAAM.push(
            _vaultIssuanceStates[vaultId].vaultIssuance.cumSIRperMAAM
        );
    }

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
            _vaultIssuanceStates[vaultId[i]].vaultIssuance.cumSIRperMAAM = _getCumSIRperMAAM(
                vaults[i],
                latestSuppliesMAAM[i]
            );
            _vaultIssuanceStates[vaultId[i]].vaultIssuance.tsLastUpdate = uint40(block.timestamp);
            if (sumTaxes == 0) {
                _vaultIssuanceStates[vaultId[i]].vaultIssuance.taxToDAO = 0;
                _vaultIssuanceStates[vaultId[i]].vaultIssuance.issuance = 0;
            } else {
                _vaultIssuanceStates[vaultId[i]].vaultIssuance.issuance = uint72(
                    (systemParams.issuanceTotalVaults * _vaultIssuanceStates[vaultId[i]].vaultIssuance.taxToDAO) /
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
            _vaultIssuanceStates[nextVaults[i]].vaultIssuance.tsLastUpdate = uint40(block.timestamp);
            _vaultIssuanceStates[nextVaults[i]].vaultIssuance.taxToDAO = taxesToDAO[i];
            _vaultIssuanceStates[nextVaults[i]].vaultIssuance.issuance = uint72(
                (systemParams.issuanceTotalVaults * taxesToDAO[i]) / sumTaxes
            );
        }

        return keccak256(abi.encodePacked(nextVaults));
    }

    function changeContributorsIssuances(
        address[] calldata prevContributors,
        address[] calldata nextContributors,
        uint72[] calldata issuances,
        bool allowAnyTotalIssuance
    ) external onlySystemControl returns (bytes32) {
        // Stop issuance of previous contributors
        for (uint256 i = 0; i < prevContributors.length; i++) {
            ContributorIssuanceParams memory contributorParams = getContributorIssuance(prevContributors[i]);
            contributorParams.issuance = 0;
            _contributorsIssuances[prevContributors[i]] = contributorParams;
        }

        // Set next issuances
        uint72 issuanceAllContributors = 0;
        for (uint256 i = 0; i < nextContributors.length; i++) {
            _contributorsIssuances[nextContributors[i]].issuance = issuances[i];
            _contributorsIssuances[nextContributors[i]].tsLastUpdate = uint40(block.timestamp);

            issuanceAllContributors += issuances[i]; // Check total issuance does not change
        }

        if (allowAnyTotalIssuance) {
            // Recalibrate vaults' issuances
            systemParams.issuanceTotalVaults = ISSUANCE - issuanceAllContributors;
        } else {
            require(
                ISSUANCE == issuanceAllContributors + systemParams.issuanceTotalVaults,
                "Total issuance must not change"
            );
        }

        return keccak256(abi.encodePacked(nextContributors));
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
        uint256 i = _vaultIssuanceStates[vaultId].lpersIssuances[LPer].indexLiquidations;
        while (
            i < _vaultIssuanceStates[vaultId].liquidationsCumSIRperMAAM.length &&
            _vaultIssuanceStates[vaultId].lpersIssuances[LPer].cumSIRperMAAM.cmp(
                _vaultIssuanceStates[vaultId].liquidationsCumSIRperMAAM[i]
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
         *             _vaultIssuanceStates[vaultId].liquidationsCumSIRperMAAM[i]
         */
        bool liquidated = i < _vaultIssuanceStates[vaultId].liquidationsCumSIRperMAAM.length;

        // Compute rewards
        lperIssuance.rewards =
            _vaultIssuanceStates[vaultId].lpersIssuances[LPer].rewards +
            uint104(
                (liquidated ? _vaultIssuanceStates[vaultId].liquidationsCumSIRperMAAM[i] : lperIssuance.cumSIRperMAAM)
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
        lperIssuance.indexLiquidations = _vaultIssuanceStates[vaultId].liquidationsCumSIRperMAAM.length <
            type(uint24).max
            ? uint24(_vaultIssuanceStates[vaultId].liquidationsCumSIRperMAAM.length)
            : type(uint24).max;
    }

    function _getCumSIRperMAAM(uint256 vaultId, bytes16 nonRebasingSupplyExcVault) internal view returns (bytes16) {
        if (systemParams.tsIssuanceStart == 0) return FloatingPoint.ZERO; // Issuance has not started yet

        VaultIssuanceParams storage vaultIssuanceParams = _vaultIssuanceStates[vaultId].vaultIssuance;
        bytes16 cumSIRperMAAM = vaultIssuanceParams.cumSIRperMAAM;

        /** If cumSIRperMAAM is already updated in this block,
         *  OR the supply is 0,
         *  OR the issuance is 0,
         *      return cumSIRperMAAM unchanged
         */
        if (
            vaultIssuanceParams.issuance == 0 ||
            vaultIssuanceParams.tsLastUpdate == uint40(block.timestamp) ||
            nonRebasingSupplyExcVault == FloatingPoint.ZERO
        ) return cumSIRperMAAM;

        // Return updated value
        return
            cumSIRperMAAM.add(
                FloatingPoint
                    .fromUInt(
                        vaultIssuanceParams.issuance *
                            (block.timestamp -
                                (
                                    systemParams.tsIssuanceStart > vaultIssuanceParams.tsLastUpdate
                                        ? systemParams.tsIssuanceStart
                                        : vaultIssuanceParams.tsLastUpdate
                                ))
                    )
                    .div(nonRebasingSupplyExcVault)
            );
    }

    function _onlySystemControl() private view {
        require(msg.sender == systemControl);
    }
}
