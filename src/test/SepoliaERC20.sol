// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Smart contracts
import {ERC20} from "solmate/tokens/ERC20.sol";

// import {Ownable} from "openzeppelin/access/Ownable.sol";

contract SepoliaERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) {
        _mint(msg.sender, 10000 * 10 ** decimals); // To bootstrap Uniswap
    }

    function mint() external {
        _mint(msg.sender, 1000 * 10 ** decimals); // Fixed amounts for testing
    }
}
