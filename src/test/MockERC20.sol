// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Smart contracts
import "solmate/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) {}

    function mint(uint256 amount) external {
        _mint(msg.sender, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnAll() external {
        _burn(msg.sender, balanceOf[msg.sender]);
    }
}
