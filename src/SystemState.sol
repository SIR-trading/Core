// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import "./interfaces/IPool.sol";

// Libraries
import "./libraries/FloatingPoint.sol";

// Contracts
import "solmate/tokens/ERC20.sol";

contract SystemState is ERC20 {
    using FloatingPoint for bytes16;

    struct LPerIssuanceParams {
        bytes16 cumSIRperMAAM; // Cumulative SIR minted by an LPer per unit of MAAM (it should only be active when his balance is non-zero)
        uint104 rewards; // SIR owed to the LPer
        uint24 indexLiquidations; // For efficiency purposes when searching through poolIssuanceParams[pool]._liquidationsCumSIRperMAAM
    }

    struct PoolIssuanceParams {
        uint16 taxToDAO; // [‱] A value of 1e4 means that the pool pays 10% of its fee revenue to the DAO.
        uint72 issuance;
        uint40 tsLastUpdate; // timestamp of the last time cumSIRperMAAM was updated. 0 => use systemParams.tsIssuanceStart instead
        bytes16 cumSIRperMAAM; // Cumulative SIR minted by the pool per unit of MAAM.
    }

    struct ContributorIssuanceParams {
        uint72 issuance; // [SIR/s]
        uint40 tsLastUpdate; // timestamp of the last mint. 0 => use systemParams.tsIssuanceStart instead
        uint128 rewards; // SIR owed to the contributor
    }

    struct SystemParameters {
        // Timestamp when issuance (re)started. 0 => issuance has not started yet
        uint40 tsIssuanceStart;
        /**
         * Base fee in basis points charged to gentlmen/apes per unit of liquidity.
         *     For example, in a pool with 3x target leverage but an actual leverage of 2.9, apes are charged a fee for minting APE, and gentlemen are charged for burning TEA.
         *     If the the actual leverage was higher than the target leverage, then apes would be charged a fee for burning APE, and gentlemen would be charged for minting TEA.
         *     In this particular example, ideally for every unit of collateral backing APE, 2 units of collateral should back TEA.
         *     Thus the fee charge upon minting APE (if actual leverage is 2.9) is fee = (2 * systemParams.basisFee / 10,000) * collateralDeposited
         */
        uint16 basisFee;
        uint72 issuanceAllPools; // Tokens issued per second excluding tokens issued to contributorsReceivingSIR
        bool onlyWithdrawals;
    }

    modifier onlySystemControl() {
        _onlySystemControl();
        _;
    }

    // Tokens issued per second
    uint72 public constant ISSUANCE = 1e2 * 1e18;
    uint256 private constant _THREE_YEARS = 365 * 24 * 60 * 60;

    address public immutable SYSTEM_CONTROL;

    mapping(address => ContributorIssuanceParams) internal _contributorsIssuances;
    mapping(address => PoolIssuanceParams) internal _poolsIssuances;
    mapping(address => bytes16[]) internal _liquidationsCumSIRperMAAM; // Stores cumSIRperMAAM value during LP liquidations
    mapping(address => mapping(address => LPerIssuanceParams)) internal _lpersIssuances;

    SystemParameters public systemParams =
        SystemParameters({tsIssuanceStart: 0, basisFee: 100, onlyWithdrawals: false, issuanceAllPools: ISSUANCE});

    constructor(address systemControl) ERC20("Governance token of the SIR protocol", "SIR", 18) {
        SYSTEM_CONTROL = systemControl;
    }

    /*////////////////////////////////////////////////////////////////
                        READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function maxSupply() public view returns (uint256) {
        if (systemParams.tsIssuanceStart == 0) return 0;

        return ISSUANCE * (block.timestamp - systemParams.tsIssuanceStart);
    }

    function getContributorIssuance(address contributor)
        public
        view
        returns (ContributorIssuanceParams memory contributorParams)
    {
        if (systemParams.tsIssuanceStart == 0) return contributorParams; // Issuance has not started yet

        contributorParams = _contributorsIssuances[contributor];

        if (block.timestamp < systemParams.tsIssuanceStart + _THREE_YEARS) {
            // Still within the 3 years that contributors receive rewards
            contributorParams.rewards += contributorParams.issuance
                * uint128(
                    block.timestamp
                        - (
                            systemParams.tsIssuanceStart > contributorParams.tsLastUpdate
                                ? systemParams.tsIssuanceStart
                                : contributorParams.tsLastUpdate
                        )
                );
        } else {
            // Already exceeded 3 years
            if (contributorParams.tsLastUpdate < systemParams.tsIssuanceStart + _THREE_YEARS) {
                // Update the rewards up to 3 yeards
                contributorParams.rewards += contributorParams.issuance
                    * uint128(
                        systemParams.tsIssuanceStart + _THREE_YEARS
                            - (
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

    function getLPerIssuance(address pool, address LPer) public view returns (LPerIssuanceParams memory) {
        (bytes16 lastNonZeroBalance, bytes16 latestBalance, bytes16 latestSupplyMAAM) =
            IPool(pool).parametersForSIRContract(LPer);
        return _getLPerIssuance(pool, LPer, lastNonZeroBalance, latestBalance, latestSupplyMAAM);
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

    function LPerMint(address pool) external {
        // Get LPer issuance parameters
        LPerIssuanceParams memory lperIssuance = getLPerIssuance(pool, msg.sender);

        // Mint if any rewards
        require(lperIssuance.rewards > 0);
        _mint(msg.sender, lperIssuance.rewards);

        // Update state
        lperIssuance.rewards = 0;
        _lpersIssuances[pool][msg.sender] = lperIssuance;
    }

    /*////////////////////////////////////////////////////////////////
                            POOL ACCESS FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @dev To be called BEFORE minting/burning MAAM in Pool.sol
     *     @dev Pool parameters get updated only once in the 1st tx in the block
     *     @dev LPer parameters get updated on every call
     *     @dev No-op unless caller is a pool
     */
    function updateIssuance(address LPer, bytes16 lastNonZeroBalance, bytes16 latestBalance, bytes16 latestSupplyMAAM)
        external
    {
        if (systemParams.tsIssuanceStart == 0) return; // Issuances has not started

        // Update pool issuance params (they only get updated once per block)
        _updatePoolIssuance(latestSupplyMAAM);

        // Update LPer issuances params
        LPerIssuanceParams memory lperIssuance =
            _getLPerIssuance(msg.sender, LPer, lastNonZeroBalance, latestBalance, latestSupplyMAAM);
        _lpersIssuances[msg.sender][LPer] = lperIssuance;
    }

    function haultLPersIssuances(bytes16 latestSupplyMAAM) external {
        if (systemParams.tsIssuanceStart == 0 || _poolsIssuances[msg.sender].issuance == 0) return; // This pool gets no SIR anyway

        // Update pool issuance params (they only get updated once per block)
        bytes16 cumSIRperMAAM = _updatePoolIssuance(latestSupplyMAAM);

        // Hault LPers issuance because their balances were just liquidated
        _liquidationsCumSIRperMAAM[msg.sender].push(cumSIRperMAAM);
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM CONTROL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @dev Only one parameter can be updated at one. We use a single function to reduce bytecode size.
     */
    function updateSystemParameters(uint40 tsIssuanceStart_, uint16 basisFee_, bool onlyWithdrawals_)
        external
        onlySystemControl
    {
        if (tsIssuanceStart_ > 0) {
            require(systemParams.tsIssuanceStart == 0, "Issuance already started");
            systemParams.tsIssuanceStart = tsIssuanceStart_;
        } else if (basisFee_ > 0) {
            systemParams.basisFee = basisFee_;
        } else {
            systemParams.onlyWithdrawals = onlyWithdrawals_;
        }
    }

    /*////////////////////////////////////////////////////////////////
                            ADMIN ISSUANCE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function recalibratePoolsIssuances(address[] calldata pools, bytes16[] memory latestSuppliesMAAM, uint256 sumTaxes)
        public
        onlySystemControl
    {
        // Reset issuance of prev pools
        for (uint256 i = 0; i < pools.length; i++) {
            // Update pool issuance params (they only get updated once per block thanks to function getCumSIRperMAAM)
            _poolsIssuances[pools[i]].cumSIRperMAAM = _getCumSIRperMAAM(pools[i], latestSuppliesMAAM[i]);
            _poolsIssuances[pools[i]].tsLastUpdate = uint40(block.timestamp);
            if (sumTaxes == 0) {
                _poolsIssuances[pools[i]].taxToDAO = 0;
                _poolsIssuances[pools[i]].issuance = 0;
            } else {
                _poolsIssuances[pools[i]].issuance =
                    uint72((systemParams.issuanceAllPools * _poolsIssuances[pools[i]].taxToDAO) / sumTaxes);
            }
        }
    }

    function changePoolsIssuances(
        address[] calldata prevPools,
        bytes16[] memory latestSuppliesMAAM,
        address[] calldata nextPools,
        uint16[] calldata taxesToDAO,
        uint256 sumTaxes
    ) external onlySystemControl returns (bytes32) {
        // Reset issuance of prev pools
        recalibratePoolsIssuances(prevPools, latestSuppliesMAAM, 0);

        // Set next issuances
        for (uint256 i = 0; i < nextPools.length; i++) {
            _poolsIssuances[nextPools[i]].tsLastUpdate = uint40(block.timestamp);
            _poolsIssuances[nextPools[i]].taxToDAO = taxesToDAO[i];
            _poolsIssuances[nextPools[i]].issuance = uint72((systemParams.issuanceAllPools * taxesToDAO[i]) / sumTaxes);
        }

        return keccak256(abi.encodePacked(nextPools));
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
            // Recalibrate pools' issuances
            systemParams.issuanceAllPools = ISSUANCE - issuanceAllContributors;
        } else {
            require(
                ISSUANCE == issuanceAllContributors + systemParams.issuanceAllPools, "Total issuance must not change"
            );
        }

        return keccak256(abi.encodePacked(nextContributors));
    }

    /*////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _updatePoolIssuance(bytes16 latestSupplyMAAM) private returns (bytes16 cumSIRperMAAM) {
        // Update pool issuance params (they only get updated once per block)
        cumSIRperMAAM = _getCumSIRperMAAM(msg.sender, latestSupplyMAAM);
        _poolsIssuances[msg.sender].cumSIRperMAAM = cumSIRperMAAM;
        _poolsIssuances[msg.sender].tsLastUpdate = uint40(block.timestamp);
    }

    function _getLPerIssuance(
        address pool,
        address LPer,
        bytes16 lastNonZeroBalance,
        bytes16 latestBalance,
        bytes16 latestSupplyMAAM
    ) internal view returns (LPerIssuanceParams memory lperIssuance) {
        if (systemParams.tsIssuanceStart == 0) return lperIssuance; // Emission of SIR has not started

        /**
         * Update cumSIRperMAAM
         */
        lperIssuance.cumSIRperMAAM = _getCumSIRperMAAM(pool, latestSupplyMAAM);

        /**
         * Update lperIssuance.rewards taking into account any possible liquidation events
         */
        // Find event that liquidated the LPer if it existed
        uint256 i = _lpersIssuances[pool][LPer].indexLiquidations;
        while (
            i < _liquidationsCumSIRperMAAM[pool].length
                && _lpersIssuances[pool][LPer].cumSIRperMAAM.cmp(_liquidationsCumSIRperMAAM[pool][i]) >= 0
        ) {
            i++;
        }

        /**
         * Find out if we must use
         *             latestBalance
         *             lperIssuance.cumSIRperMAAM
         *         or 
         *             lastNonZeroBalance
         *             _liquidationsCumSIRperMAAM[pool][i]
         */
        bool liquidated = i < _liquidationsCumSIRperMAAM[pool].length;

        // Compute rewards
        lperIssuance.rewards = _lpersIssuances[pool][LPer].rewards
            + uint104(
                (liquidated ? _liquidationsCumSIRperMAAM[pool][i] : lperIssuance.cumSIRperMAAM).mul(
                    liquidated ? lastNonZeroBalance : latestBalance
                ).toUInt()
            );

        /**
         * Update lperIssuance.indexLiquidations
         */
        lperIssuance.indexLiquidations = _liquidationsCumSIRperMAAM[pool].length < type(uint24).max
            ? uint24(_liquidationsCumSIRperMAAM[pool].length)
            : type(uint24).max;
    }

    function _getCumSIRperMAAM(address pool, bytes16 latestSupplyMAAM) internal view returns (bytes16) {
        if (systemParams.tsIssuanceStart == 0) return 0; // Issuance has not started yet

        PoolIssuanceParams storage poolIssuanceParams = _poolsIssuances[pool];
        bytes16 cumSIRperMAAM = poolIssuanceParams.cumSIRperMAAM;

        // If cumSIRperMAAM is already updated in this block, just return it
        if (poolIssuanceParams.tsLastUpdate == uint40(block.timestamp)) return cumSIRperMAAM;

        // If the supply is 0, cumSIRperMAAM does not increase
        if (latestSupplyMAAM == FloatingPoint.ZERO) return cumSIRperMAAM;

        // Return updated value
        return cumSIRperMAAM.add(
            FloatingPoint.fromUInt(
                poolIssuanceParams.issuance
                    * (
                        block.timestamp
                            - (
                                systemParams.tsIssuanceStart > poolIssuanceParams.tsLastUpdate
                                    ? systemParams.tsIssuanceStart
                                    : poolIssuanceParams.tsLastUpdate
                            )
                    )
            ).div(latestSupplyMAAM)
        );
    }

    function _onlySystemControl() private view {
        require(msg.sender == SYSTEM_CONTROL);
    }
}
