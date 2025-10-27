// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {AddressesHyperEVMTest} from "src/libraries/AddressesHyperEVMTest.sol";
import {AddressesHyperEVM} from "src/libraries/AddressesHyperEVM.sol";
import {Oracle} from "src/Oracle.sol";
import {SystemControl} from "src/SystemControl.sol";
import {Contributors} from "src/Contributors.sol";
import {SIR} from "src/SIR.sol";
import {Vault} from "src/Vault.sol";
import {APE} from "src/APE.sol";
import {SirStructs} from "src/libraries/SirStructs.sol";
import {AllocationsHelper} from "./AllocationsHelper.sol";

/** @dev cli for HyperEVM testnet with big blocks:
        forge script script/DeployCore.s.sol --rpc-url hypertest --chain 998 --broadcast --ledger --hd-paths $HD_PATH
    @dev cli for HyperEVM mainnet with big blocks:
        forge script script/DeployCore.s.sol --rpc-url hyperevm --chain 999 --broadcast --ledger --hd-paths $HD_PATH  \
        --with-gas-price 0.8gwei --priority-gas-price 0.1gwei --slow --verify --etherscan-api-key $API_KEY
    @dev Steps:
        1. Deploy Oracle.sol
        2. Deploy SystemControl.sol
        3. Deploy SIR.sol
        4. Deploy Vault.sol (and VaultExternal.sol) with addresses of SystemControl.sol, SIR.sol, and Oracle.sol
        5. Initialize SIR.sol with address of Vault.sol
        6. Initialize SystemControl.sol with addresses of Vault.sol and SIR.sol
        7. Allocate all contributors from allocations.json
        8. Verify remainingAllocation is 0
*/
contract DeployCore is AllocationsHelper {
    function setUp() public view {
        if (block.chainid != 998 && block.chainid != 999) {
            revert("Only HyperEVM testnet (chain 998) and mainnet (chain 999) are supported");
        }
    }

    function run() public {
        vm.startBroadcast();

        // Get the correct addresses based on chain
        address uniswapFactory;
        address whype;

        if (block.chainid == 998) {
            uniswapFactory = AddressesHyperEVMTest.ADDR_UNISWAPV3_FACTORY;
            whype = AddressesHyperEVMTest.ADDR_WHYPE;
        } else {
            uniswapFactory = AddressesHyperEVM.ADDR_UNISWAPV3_FACTORY;
            whype = AddressesHyperEVM.ADDR_WHYPE;
        }

        // Deploy oracle
        address oracle = address(new Oracle(uniswapFactory));
        console.log("Oracle deployed at: ", oracle);

        // Deploy SystemControl
        address systemControl = address(new SystemControl());
        console.log("SystemControl deployed at: ", systemControl);

        // Deploy Contributors
        address contributors = address(new Contributors());
        console.log("Contributors deployed at: ", contributors);

        // Deploy SIR
        address payable sir = payable(address(new SIR(contributors, whype, systemControl)));
        console.log("SIR deployed at: ", sir);

        // Deploy APE implementation
        address apeImplementation = address(new APE());
        console.log("APE implementation deployed at: ", apeImplementation);

        // Deploy Vault
        address vault = address(new Vault(systemControl, sir, oracle, apeImplementation, whype));
        console.log("Vault deployed at: ", vault);

        // Initialize SIR
        SIR(sir).initialize(vault);
        console.log("SIR initialized.");

        // Initialize SystemControl
        SystemControl(systemControl).initialize(vault, sir);
        console.log("SystemControl initialized.");

        // Allocate contributors from JSON file
        console.log("Starting contributor allocations...");
        (uint256 totalAddresses, uint256 totalAllocations) = readAndAllocate(contributors);

        // Verify all allocations are done
        console.log("Total addresses allocated:", totalAddresses);
        console.log("Total allocations sum:", totalAllocations);
        uint56 remaining = Contributors(contributors).remainingAllocation();
        console.log("Remaining allocation:", remaining);
        require(remaining == 0, "Remaining allocation must be 0");
        require(totalAllocations == uint256(type(uint56).max), "Total allocations must equal type(uint56).max");
        console.log("All allocations completed successfully!");

        vm.stopBroadcast();
    }
}
