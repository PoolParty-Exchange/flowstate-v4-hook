// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only. The stack fixture's USDC mock (PoolParty_Contracts test/mocks/MockERC20: an
///         OpenZeppelin v5 ERC20 plus one uint8 decimals slot) with WETH's deposit and withdraw added.
///         The stack harness installs this RUNTIME code over the fixture's USDC with hardhat_setCode,
///         so every balance, allowance and the name, symbol and decimals stay as they were (the
///         harness asserts it), and then deploys the hook with it as weth9. Both ETH V4 pools
///         (native and "aeWETH") then sell one C1 pool priced by the fixture's venue in this asset:
///         the production shape, where aeWETH is the C1 pool's quote asset under both pools.
///         One wei of native is one unit. No immutables: setCode installs runtime code only.
contract StackWrappedDollar is ERC20 {
    uint8 private _decimals;

    constructor() ERC20("", "") {}

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw");
    }

    receive() external payable {
        deposit();
    }
}
