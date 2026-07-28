// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice Funding callback for FlowstateMarket.buyFromPoolExactOut (build scope
///         §2.2, Phase 0 funding-order finding). The market computes the exact
///         band-checked oracle cost inside its single read and — only when the
///         caller's balance + allowance do not already cover it — calls back so the
///         caller can fund itself before the market's pull-exact transferFrom. The
///         hook implements this by taking exactly `cost` from the PoolManager.
/// @dev Mirror of PoolParty_Contracts/contracts/interface/IFlowstateBuyFunder.sol
///      (solc 0.8.29 there, ^0.8.26 here).
interface IFlowstateBuyFunder {
    /// @param quoteAsset quote asset the market is about to pull.
    /// @param cost       exact amount the market will pull after this returns.
    function fundBuy(address quoteAsset, uint256 cost) external;
}
