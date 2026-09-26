// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice Minimal wrapped-native surface the hook consumes (aeWETH on Robinhood
///         Chain — the Arbitrum bridge stack's canonical WETH deployment). The hook
///         is buy-only, so only `deposit` is ever needed: native taken from the
///         PoolManager is wrapped before the market's pull-exact transferFrom; the
///         unwrap direction never occurs.
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
