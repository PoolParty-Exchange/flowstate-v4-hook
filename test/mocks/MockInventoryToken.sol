// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockInventoryToken is ERC20 {
    constructor() ERC20("Flowstate Mock Inventory", "FLOWMOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
