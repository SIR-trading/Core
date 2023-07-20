// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import "./interfaces/IVault.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/ISystemState.sol";

// Smart contracts
import {Owned} from "openzeppelin/access/Ownable.sol";

contract SystemControl is Ownable {
    event systemRunning();
    event withdrawalsOnly();
    event betaPeriodOver();

    IFactory private immutable _FACTORY;
    ISystemState private immutable _SYSTEM_STATE;

    uint256 private _sumTaxesToDAO;

    bool public betaPeriod = true;

    bytes32 public hashContributors = keccak256(abi.encodePacked(new address[](0)));
    bytes32 public hashVaults = keccak256(abi.encodePacked(new address[](0)));

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

    function setBasisFee(uint16 baseFee) external onlyOwner betaIsOn {
        require(baseFee <= 1000, "Unreasonably high fee");
        _SYSTEM_STATE.updateSystemParameters(0, baseFee, false);
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
     * @param prevVaults is an array of the vaults participating in the liquidity mining up to this instant
     *     @param nextVaults is an array of vaults participating in the liquidity mining from this instant
     *     @param taxesToDAO is an array containing the % of the fees revenue taken from each vault in nextVaults.
     */
    function updateVaultsIssuances(
        address[] calldata prevVaults,
        address[] calldata nextVaults,
        uint16[] calldata taxesToDAO
    ) public onlyOwner {
        require(nextVaults.length > 0 && nextVaults.length == taxesToDAO.length);

        // Check the array of prev vaults is correct
        require(keccak256(abi.encodePacked(prevVaults)) == hashVaults, "Incorrect list of vaults");

        // Get the MAAM supplies of all the previous vaults
        bytes16[] memory latestSuppliesMAAM = new bytes16[](prevVaults.length);
        for (uint256 i = 0; i < prevVaults.length; i++) {
            latestSuppliesMAAM[i] = IVault(prevVaults[i]).nonRebasingSupplyExcludePOL();
        }

        /**
         * Verify that the DAO taxes satisfy constraint
         *             taxesToDAO[0]**2 + ... + taxesToDAO[N]**2 ≤ (10%)**2
         *         Checks the vaults are valid by
         *             1) calling the alleged vault address
         *             2) retrieving its alleged parameters
         *             3) and computing the theoretical address
         */
        uint256 sumTaxesToDAO = 0;
        uint256 sumSqTaxes = 0;
        for (uint256 i = 0; i < nextVaults.length; i++) {
            sumTaxesToDAO += uint256(taxesToDAO[i]);
            sumSqTaxes += uint256(taxesToDAO[i]) ** 2;

            (address debtToken, , , ) = _FACTORY.vaultsParameters(nextVaults[i]);
            require(debtToken != address(0), "Not a SIR vault");
        }
        require(sumSqTaxes <= (1e4) ** 2, "Taxes too high");
        _sumTaxesToDAO = sumTaxesToDAO;

        for (uint256 i = 0; i < nextVaults.length; i++) {}

        // Set new issuances
        hashVaults = _SYSTEM_STATE.changeVaultsIssuances(
            prevVaults,
            latestSuppliesMAAM,
            nextVaults,
            taxesToDAO,
            sumTaxesToDAO
        );
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
        hashContributors = _SYSTEM_STATE.changeContributorsIssuances(
            prevContributors,
            nextContributors,
            issuances,
            false
        );
    }

    function updateContributorsIssuances(
        address[] calldata prevContributors,
        address[] calldata nextContributors,
        uint72[] calldata issuances,
        address[] calldata vaults
    ) external onlyOwner betaIsOn {
        require(nextContributors.length == issuances.length);

        // Check the array of prev contributors is correct
        require(keccak256(abi.encodePacked(prevContributors)) == hashContributors, "Incorrect list of contributors");

        // Check the array of vaults is correct
        require(keccak256(abi.encodePacked(vaults)) == hashVaults, "Incorrect list of vaults");

        // Set new issuances
        hashContributors = _SYSTEM_STATE.changeContributorsIssuances(
            prevContributors,
            nextContributors,
            issuances,
            true
        );

        // Get the MAAM supplies of all the previous vaults
        bytes16[] memory latestSuppliesMAAM = new bytes16[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            latestSuppliesMAAM[i] = IVault(vaults[i]).nonRebasingSupplyExcludePOL();
        }

        // Becaues the total vault issuance has change, the vaults need to be recalibrated
        _SYSTEM_STATE.recalibrateVaultsIssuances(vaults, latestSuppliesMAAM, _sumTaxesToDAO);
    }

    // MAKE A WITHDRAWAL FUNCTION!
    // function withdrawDAOFees(address vault) external onlyOwner returns () {
    //     daoFees = state.daoFees;
    //     state.daoFees = 0; // No re-entrancy attack
    //     TransferHelper.safeTransfer(COLLATERAL_TOKEN, msg.sender, daoFees);
    // }
}
