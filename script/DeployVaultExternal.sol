// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {VaultExternal} from "src/libraries/VaultExternal.sol";

/** @dev cli for local testnet:  forge script DeployVaultExternal --rpc-url mainnet --chain 1 --broadcast --verify --slow --etherscan-api-key YOUR_KEY --ledger --hd-paths PATHS
    @dev cli for Sepolia:        forge script DeployVaultExternal --rpc-url sepolia --chain sepolia --broadcast
*/
contract DeployVaultExternal is Script {
    uint256 deployerPrivateKey;

    bytes32 constant VAULT_EXTERNAL_SALT = 0x5c6090c0461491a2941743bda5c3658bf1ea53bbd3edcde54e16205e19c67e4b;

    function setUp() public {
        if (block.chainid == 11155111) {
            deployerPrivateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        } else if (block.chainid != 1) {
            revert("Network not supported");
        }
    }

    function run() external {
        IFactory factory = IFactory(0xce0042B868300000d44A59004Da54A005ffdcf9f);

        bytes memory creationCode = vm.getCode("VaultExternal.sol:VaultExternal");

        vm.startBroadcast(deployerPrivateKey);

        address lib = factory.deploy(creationCode, VAULT_EXTERNAL_SALT);
        console.log("VaultExternal deployed at:", lib);

        vm.stopBroadcast();
    }
}

interface IFactory {
    function deploy(bytes memory _initCode, bytes32 _salt) external returns (address payable createdContract);
}
