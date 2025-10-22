// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/Contributors.sol";

contract DeployAndAllocate is Script {
    uint256 constant BATCH_SIZE = 100; // Process 100 addresses at a time to avoid gas limits

    function run() external {
        // Load private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the Contributors contract
        Contributors contributors = new Contributors();

        console.log("Contributors contract deployed at:", address(contributors));

        vm.stopBroadcast();

        // Note: Actual allocation would be done off-chain in batches
        // due to the large number of addresses (4074) in allocations.json
        console.log("Contract deployed. Run allocation script separately to populate allocations.");
        console.log("Recommended batch size: 100 addresses per transaction");
    }
}