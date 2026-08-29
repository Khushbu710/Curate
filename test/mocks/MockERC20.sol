// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/tokens/ERC20.sol";

/// @notice Minimal mintable ERC20 test double standing in for token0/token1.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_, 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
