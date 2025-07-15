// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {VaultExternal} from "src/libraries/VaultExternal.sol";

/** @dev cli for local testnet:  forge script DeployVaultExternal --rpc-url mainnet --chain 1 --broadcast --verify --slow --etherscan-api-key YOUR_KEY --ledger --hd-paths PATHS
    @dev cli for Sepolia:        forge script DeployVaultExternal --rpc-url sepolia --chain sepolia --broadcast
*/
contract DeployVaultExternal is Script {
    uint256 deployerPrivateKey;

    bytes32 constant VAULT_EXTERNAL_SALT = 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e1b753cdc;

    function setUp() public {
        if (block.chainid == 11155111) {
            deployerPrivateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else if (block.chainid != 1) {
            revert("Network not supported");
        }
    }

    function run() external {
        bytes memory init = type(VaultExternal).creationCode;
        bytes32 initHash = keccak256(init);
        console.log("Init hash:", vm.toString(initHash));
        bytes memory data = abi.encodePacked(VAULT_EXTERNAL_SALT, init); // no selector

        address factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        vm.startBroadcast(deployerPrivateKey);

        (bool ok, bytes memory ret) = factory.call(data);
        require(ok, "create2 deploy failed");

        address lib = abi.decode(ret, (address)); // proxy returns the new address
        console.log("VaultExternal deployed at:", lib);

        vm.stopBroadcast();
    }
}
