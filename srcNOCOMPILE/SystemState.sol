// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import {ERC20} from "solmate/tokens/ERC20.sol";

contract SystemState is ERC20 {
    struct LPerIssuanceParams {
        uint192 cumSIRperMAAM; // Q64.128, cumulative SIR minted by an LPer per unit of MAAM
        uint64 rewards; // SIR owed to the LPer
    }

    struct VaultIssuanceParams {
        uint16 taxToDAO; // [‱] A value of 1e4 means that the vaultId pays 10% of its fee revenue to the DAO.
        uint72 issuance;
        uint40 tsLastUpdate; // timestamp of the last time cumSIRperMAAM was updated. 0 => use systemParams.tsIssuanceStart instead
        bytes16 cumSIRperMAAM; // Cumulative SIR minted by the vaultId per unit of MAAM.
    }

    struct ContributorIssuanceParams {
        uint72 issuance; // [SIR/s]
        uint40 tsLastUpdate; // timestamp of the last mint. 0 => use systemParams.tsIssuanceStart instead
        uint128 rewards; // SIR owed to the contributor
    }

    struct VaultIssuanceState {
        VaultIssuanceParams vaultIssuance;
        bytes16[] liquidationsCumSIRperMAAM;
        mapping(address => LPerIssuanceParams) lpersIssuances;
    }

    struct SystemParameters {
        // Timestamp when issuance (re)started. 0 => issuance has not started yet
        uint40 tsIssuanceStart;
        /**
         * Base fee in basis points charged to gentlmen/apes per unit of liquidity.
         *     For example, in a vaultId with 3x target leverage but an actual leverage of 2.9, apes are charged a fee for minting APE, and gentlemen are charged for burning TEA.
         *     If the the actual leverage was higher than the target leverage, then apes would be charged a fee for burning APE, and gentlemen would be charged for minting TEA.
         *     In this particular example, ideally for every unit of collateral backing APE, 2 units of collateral should back TEA.
         *     Thus the fee charge upon minting APE (if actual leverage is 2.9) is fee = (2 * systemParams.baseFee / 10,000) * collateralDeposited
         */
        uint16 baseFee;
        uint72 issuanceAllVaults; // Tokens issued per second excluding tokens issued to contributorsReceivingSIR
        bool onlyWithdrawals;
    }

    modifier onlySystemControl() {
        _onlySystemControl();
        _;
    }

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    // Tokens issued per second
    /**
     *  100 SIR/s issued forever. To allow enough precission for cumSIRperMAAM, we only use 6 decimals in SIR
     *  which implies that we only need 64 bits to fit up to +1000 years of issued supply.
     *  If LPerIssuanceParams is stored in 1 word, we are left with 128 bits for decimals digits in cumSIRperMAAAM
     *  which is enough even in vault where tokens with really large supply.
     */
    uint72 public constant ISSUANCE = 1e2 * 1e6;
    uint256 private constant _THREE_YEARS = 365 * 24 * 60 * 60;

    address public immutable SYSTEM_CONTROL;
    address public immutable VAULT;

    mapping(address => ContributorIssuanceParams) internal _contributorsIssuances;
    mapping(vaultId => VaultIssuanceState) internal _vaultIssuanceStates;

    SystemParameters public systemParams =
        SystemParameters({tsIssuanceStart: 0, baseFee: 100, onlyWithdrawals: false, issuanceAllVaults: ISSUANCE});

    constructor(address vault, address systemControl) ERC20("Governance token of the SIR protocol", "SIR", 18) {
        VAULT = vault;
        SYSTEM_CONTROL = systemControl;
    }

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function maxSupply() public view returns (uint256) {
        if (systemParams.tsIssuanceStart == 0) return 0;

        return ISSUANCE * (block.timestamp - systemParams.tsIssuanceStart);
    }

    function getContributorIssuance(
        address contributor
    ) public view returns (ContributorIssuanceParams memory contributorParams) {
        if (systemParams.tsIssuanceStart == 0) return contributorParams; // Issuance has not started yet

        contributorParams = _contributorsIssuances[contributor];

        if (block.timestamp < systemParams.tsIssuanceStart + _THREE_YEARS) {
            // Still within the 3 years that contributors receive rewards
            contributorParams.rewards +=
                contributorParams.issuance *
                uint128(
                    block.timestamp -
                        (
                            systemParams.tsIssuanceStart > contributorParams.tsLastUpdate
                                ? systemParams.tsIssuanceStart
                                : contributorParams.tsLastUpdate
                        )
                );
        } else {
            // Already exceeded 3 years
            if (contributorParams.tsLastUpdate < systemParams.tsIssuanceStart + _THREE_YEARS) {
                // Update the rewards up to 3 yeards
                contributorParams.rewards +=
                    contributorParams.issuance *
                    uint128(
                        systemParams.tsIssuanceStart +
                            _THREE_YEARS -
                            (
                                systemParams.tsIssuanceStart > contributorParams.tsLastUpdate
                                    ? systemParams.tsIssuanceStart
                                    : contributorParams.tsLastUpdate
                            )
                    );
            }
            contributorParams.issuance = 0;
        }

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
    ) external onlyVault {
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

    function haultIssuance(uint256 vaultId) external onlyVault {
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
            systemParams.onlyWithdrawals = onlyWithdrawals_;
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
                    (systemParams.issuanceAllVaults * _vaultIssuanceStates[vaultId[i]].vaultIssuance.taxToDAO) /
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
                (systemParams.issuanceAllVaults * taxesToDAO[i]) / sumTaxes
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
            systemParams.issuanceAllVaults = ISSUANCE - issuanceAllContributors;
        } else {
            require(
                ISSUANCE == issuanceAllContributors + systemParams.issuanceAllVaults,
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
        require(msg.sender == SYSTEM_CONTROL);
    }

    function _onlyVault() private view {
        require(msg.sender == VAULT);
    }
}
