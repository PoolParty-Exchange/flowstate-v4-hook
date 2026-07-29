// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice Minimal market surface the V4 hook consumes — the FINAL Phase 1 signatures
///         of the pass-1 FlowstateMarket (pull-exact model) plus the additive
///         exact-quote entry-point pair from build scope §2.2 (PoolParty_Contracts
///         PR #8, on origin/main).
/// @dev Verified against the REAL FlowstateMarket on an RH fork (Phase 1 final): the
///      whole fork suite runs the hook against the deployed pass-1 contracts, and the
///      Phase 0 mock has been deleted. Signature drift on the market side is therefore
///      a compile/test failure here, not a silent divergence.
/// @dev Pull-exact: the market computes the band-checked oracle cost internally and
///      pulls exactly that many quote-asset units from msg.sender via transferFrom,
///      then delivers the tokens to `buyer`. The pair is all-or-nothing with a typed
///      FillShortfall revert; each entry point performs exactly ONE oracle read.
interface IFlowstateMarketMinimal {
    /// @notice Legacy exact-output buy (partial-fill semantics; kept for reference —
    ///         the hook's swap paths use the pair below).
    /// @return tokensFilled tokens delivered (may be < amount on inventory caps).
    /// @return quotePaid    quote-asset units pulled from msg.sender.
    function buyFromPool(address pool, uint256 amount, string calldata resellerCode, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid);

    /// @notice Exact-input buy in quote terms: the market inverts quoteIn to a token
    ///         amount inside its single oracle read, pulls exactly the oracle cost of
    ///         the tokens delivered (quotePaid <= quoteIn; inversion dust stays with
    ///         the caller), and delivers the tokens. All-or-nothing.
    /// @param pool          C1 pool to buy from.
    /// @param quoteIn       quote-asset units the caller commits.
    /// @param resellerCode  fee-attribution code; "" for none.
    /// @param buyer         recipient of the purchased tokens.
    /// @return tokensFilled tokens delivered.
    /// @return quotePaid    quote-asset units actually pulled (<= quoteIn).
    function buyFromPoolExactQuote(address pool, uint256 quoteIn, string calldata resellerCode, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid);

    /// @notice Exact-output buy with funding callback (the Phase 0 funding-order fix):
    ///         the market computes the cost in its single oracle read, then — only if
    ///         msg.sender has code and its balance/allowance do not already cover the
    ///         cost — calls IFlowstateBuyFunder(msg.sender).fundBuy(quoteAsset, cost)
    ///         so the caller can fund itself (the hook does manager.take there) before
    ///         the market pulls exactly cost. All-or-nothing (FillShortfall unless
    ///         tokensFilled == tokenAmountOut).
    /// @return tokensFilled tokens delivered (== tokenAmountOut).
    /// @return quotePaid    quote-asset units pulled from msg.sender.
    function buyFromPoolExactOut(address pool, uint256 tokenAmountOut, string calldata resellerCode, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid);
}
