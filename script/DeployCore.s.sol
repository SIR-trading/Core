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

/** @dev cli for HyperEVM testnet with big blocks:
        BB_GAS=$(cast rpc --rpc-url hypertest eth_bigBlockGasPrice | tr -d '"' | cast to-dec)
        forge script script/DeployCore.s.sol --rpc-url hypertest --chain 998 --broadcast --ledger --hd-paths "m/44'/60'/0'/0/0" --with-gas-price $BB_GAS --slow
    @dev cli for HyperEVM mainnet with big blocks:
        BB_GAS=$(cast rpc --rpc-url hyperevm eth_bigBlockGasPrice | tr -d '"' | cast to-dec)
        forge script script/DeployCore.s.sol --rpc-url hyperevm --chain 999 --broadcast --ledger --hd-paths "m/44'/60'/0'/0/0" --with-gas-price $BB_GAS --slow
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
contract DeployCore is Script {
    uint256 constant BATCH_SIZE = 100;

    struct AllocationEntry {
        address addr;
        uint56 allocation;
    }

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
        allocateContributors(contributors);

        // Verify all allocations are done
        uint56 remaining = Contributors(contributors).remainingAllocation();
        console.log("Remaining allocation:", remaining);
        require(remaining == 0, "Remaining allocation must be 0");
        console.log("All allocations completed successfully!");

        vm.stopBroadcast();
    }

    function allocateContributors(address contributorsContract) internal {
        // Read the JSON file
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/allocations/allocations.json");
        string memory json = vm.readFile(path);

        // The JSON structure has addresses as keys, so we need to parse it differently
        // We'll extract all keys (addresses) from the allocations object
        string[] memory allocationKeys = vm.parseJsonKeys(json, ".allocations");

        console.log("Total addresses to allocate:", allocationKeys.length);

        // Process in batches
        uint256 totalAddresses = allocationKeys.length;
        uint256 batchCount = (totalAddresses + BATCH_SIZE - 1) / BATCH_SIZE;

        for (uint256 batchIndex = 0; batchIndex < batchCount; batchIndex++) {
            uint256 startIdx = batchIndex * BATCH_SIZE;
            uint256 endIdx = startIdx + BATCH_SIZE;
            if (endIdx > totalAddresses) {
                endIdx = totalAddresses;
            }
            uint256 batchLength = endIdx - startIdx;

            address[] memory addresses = new address[](batchLength);
            uint56[] memory amounts = new uint56[](batchLength);

            for (uint256 i = 0; i < batchLength; i++) {
                string memory addrKey = allocationKeys[startIdx + i];
                addresses[i] = vm.parseAddress(addrKey);

                // Get the allocation amount for this address
                amounts[i] = uint56(
                    abi.decode(
                        vm.parseJson(json, string.concat(".allocations.", addrKey, ".allocation")),
                        (uint256)
                    )
                );
            }

            // Call allocate for this batch
            Contributors(contributorsContract).allocate(addresses, amounts);
            console.log("Allocated batch", batchIndex + 1, "of", batchCount);
        }
    }
}
