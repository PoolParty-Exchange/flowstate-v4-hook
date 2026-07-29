// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/**
 * @title IFlowstateBuyFunder
 * @notice Funding callback for FlowstateMarket.buyFromPoolExactOut (V4 hook build
 *         scope §2.2, Phase 0 funding-order finding). On an exact-output V4 swap the
 *         hook must learn the band-checked oracle cost BEFORE PoolManager.take can
 *         fund it, while the market's pull-exact model pulls from a balance that only
 *         exists AFTER take. The market therefore computes the cost inside its single
 *         oracle read and — only when the caller's balance + allowance do not already
 *         cover it — calls back into the caller, which funds itself (the V4 hook does
 *         PoolManager.take here) before the market pulls exactly the cost.
 * @dev The market invokes this on msg.sender only, never on a third party, and only
 *      when msg.sender has code. Pre-funded callers (EOA or contract) are never
 *      called back and need not implement this interface.
 */
interface IFlowstateBuyFunder {
    /// @notice Fund the in-flight exact-output buy: after this returns, the market
    ///         (msg.sender of this call) pulls exactly `cost` of `quoteAsset` from
    ///         the callee via transferFrom.
    /// @param quoteAsset quote asset the market is about to pull.
    /// @param cost       exact amount the market will pull.
    function fundBuy(address quoteAsset, uint256 cost) external;
}
