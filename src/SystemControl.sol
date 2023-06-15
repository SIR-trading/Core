// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import "./interfaces/IPool.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/ISystemState.sol";

// Smart contracts
import "openzeppelin/access/Ownable.sol";

contract SystemControl is Ownable {
    event systemRunning();
    event withdrawalsOnly();
    event betaPeriodOver();

    IFactory private immutable _FACTORY;
    ISystemState private immutable _SYSTEM_STATE;

    uint256 private _sumTaxesToDAO;

    bool public betaPeriod = true;

    bytes32 public hashContributors = keccak256(abi.encodePacked(new address[](0)));
    bytes32 public hashPools = keccak256(abi.encodePacked(new address[](0)));

    modifier betaIsOn() {
        require(betaPeriod, "Beta is over");
        _;
    }

    constructor(address factory, address systemState) {
        _FACTORY = IFactory(factory);
        _SYSTEM_STATE = ISystemState(systemState);
    }

    /*///////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /**
     * @notice The next 3 functions control the only configurable parameters of SIR.
     *     @notice As soon as the protocol is redeemed safe and stable,
     *     @notice ownership will be revoked and SIR will be completely immutable
     */

    function setBasisFee(uint16 basisFee) external onlyOwner betaIsOn {
        require(basisFee <= 1000, "Unreasonably high fee");
        _SYSTEM_STATE.updateSystemParameters(0, basisFee, false);
    }

    function enableMinting() external onlyOwner betaIsOn {
        _SYSTEM_STATE.updateSystemParameters(0, 0, false);
        emit systemRunning();
    }

    function disableMinting() external onlyOwner betaIsOn {
        _SYSTEM_STATE.updateSystemParameters(0, 0, true);
        emit withdrawalsOnly();
    }

    function exitBeta() external onlyOwner betaIsOn {
        _SYSTEM_STATE.updateSystemParameters(0, 0, false);
        betaPeriod = false;
        emit betaPeriodOver();
    }

    // Start issuance and allows minting apes & gentlemen
    function startSIR() external onlyOwner {
        _SYSTEM_STATE.updateSystemParameters(uint40(block.timestamp), 0, false);
    }

    /**
     * @param prevPools is an array of the pools participating in the liquidity mining up to this instant
     *     @param nextPools is an array of pools participating in the liquidity mining from this instant
     *     @param taxesToDAO is an array containing the % of the fees revenue taken from each pool in nextPools.
     */
    function updatePoolsIssuances(
        address[] calldata prevPools,
        address[] calldata nextPools,
        uint16[] calldata taxesToDAO
    ) public onlyOwner {
        require(nextPools.length > 0 && nextPools.length == taxesToDAO.length);

        // Check the array of prev pools is correct
        require(keccak256(abi.encodePacked(prevPools)) == hashPools, "Incorrect list of pools");

        // Get the MAAM supplies of all the previous pools
        bytes16[] memory latestSuppliesMAAM = new bytes16[](prevPools.length);
        for (uint256 i = 0; i < prevPools.length; i++) {
            latestSuppliesMAAM[i] = IPool(prevPools[i]).nonRebasingSupplyExcludePOL();
        }

        /**
         * Verify that the DAO taxes satisfy constraint
         *             taxesToDAO[0]**2 + ... + taxesToDAO[N]**2 ≤ (10%)**2
         *         Checks the pools are valid by
         *             1) calling the alleged pool address
         *             2) retrieving its alleged parameters
         *             3) and computing the theoretical address
         */
        uint256 sumTaxesToDAO = 0;
        uint256 sumSqTaxes = 0;
        for (uint256 i = 0; i < nextPools.length; i++) {
            sumTaxesToDAO += uint256(taxesToDAO[i]);
            sumSqTaxes += uint256(taxesToDAO[i]) ** 2;

            (address debtToken,,,) = _FACTORY.poolsParameters(nextPools[i]);
            require(debtToken != address(0), "Not a SIR pool");
        }
        require(sumSqTaxes <= (1e4) ** 2, "Taxes too high");
        _sumTaxesToDAO = sumTaxesToDAO;

        for (uint256 i = 0; i < nextPools.length; i++) {}

        // Set new issuances
        hashPools =
            _SYSTEM_STATE.changePoolsIssuances(prevPools, latestSuppliesMAAM, nextPools, taxesToDAO, sumTaxesToDAO);
    }

    function updateContributorsIssuances(
        address[] calldata prevContributors,
        address[] calldata nextContributors,
        uint72[] calldata issuances
    ) external onlyOwner {
        require(nextContributors.length == issuances.length);

        // Check the array of prev contributors is correct
        require(keccak256(abi.encodePacked(prevContributors)) == hashContributors, "Incorrect list of contributors");

        // Set new issuances
        hashContributors =
            _SYSTEM_STATE.changeContributorsIssuances(prevContributors, nextContributors, issuances, false);
    }

    function updateContributorsIssuances(
        address[] calldata prevContributors,
        address[] calldata nextContributors,
        uint72[] calldata issuances,
        address[] calldata pools
    ) external onlyOwner betaIsOn {
        require(nextContributors.length == issuances.length);

        // Check the array of prev contributors is correct
        require(keccak256(abi.encodePacked(prevContributors)) == hashContributors, "Incorrect list of contributors");

        // Check the array of pools is correct
        require(keccak256(abi.encodePacked(pools)) == hashPools, "Incorrect list of pools");

        // Set new issuances
        hashContributors =
            _SYSTEM_STATE.changeContributorsIssuances(prevContributors, nextContributors, issuances, true);

        // Get the MAAM supplies of all the previous pools
        bytes16[] memory latestSuppliesMAAM = new bytes16[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            latestSuppliesMAAM[i] = IPool(pools[i]).nonRebasingSupplyExcludePOL();
        }

        // Becaues the total pool issuance has change, the pools need to be recalibrated
        _SYSTEM_STATE.recalibratePoolsIssuances(pools, latestSuppliesMAAM, _sumTaxesToDAO);
    }

    // MAKE A WITHDRAWAL FUNCTION!
    // function withdrawDAOFees(address pool) external onlyOwner returns () {
    //     DAOFees = state.DAOFees;
    //     state.DAOFees = 0; // No re-entrancy attack
    //     TransferHelper.safeTransfer(COLLATERAL_TOKEN, msg.sender, DAOFees);
    // }
}
