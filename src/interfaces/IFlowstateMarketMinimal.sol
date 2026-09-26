// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice Minimal market surface the V4 hook consumes — the FINAL Phase 1 signatures
///         of the pass-1 FlowstateMarket (pull-exact model) plus the additive
///         exact-quote entry-point pair from build scope §2.2 (PR #8) as reshaped by
///         the multi-asset change (PR #11, origin/main @ fd5575c): every buy path
///         names the quote asset per trade.
/// @dev Verified against the REAL FlowstateMarket on an RH fork (Phase 1 final): the
///      whole fork suite runs the hook against the deployed pass-1 contracts, and the
///      Phase 0 mock has been deleted. Signature drift on the market side is therefore
///      a compile/test failure here, not a silent divergence.
/// @dev Pull-exact: the market computes the band-checked oracle cost internally and
///      pulls exactly that many quote-asset units from msg.sender via transferFrom,
///      then delivers the tokens to `buyer`. The pair is all-or-nothing with a typed
///      FillShortfall revert; each entry point performs exactly ONE oracle read.
interface IFlowstateMarketMinimal {
    /// @notice Canonical Market registry entry for a Flowstate pool.
    /// @dev The public mapping getter returns the PoolRecord fields in declaration order.
    function poolRecords(address pool) external view returns (address inventoryToken, bool exists);

    /// @notice Whether an asset is currently approved as executable quote input.
    function approvedQuoteAssets(address asset) external view returns (bool);

    /// @notice JUP-696 passive-lane rate used by both pool and listing settlement.
    function previewRate(address pool, address asset) external view returns (bool ok, uint256 rate);

    /// @notice JUP-612 executable passive inventory within the pool's bounded
    ///         MAX_FILL_NODES traversal. Returns zeroes rather than reverting when
    ///         the pool cannot currently execute.
    function maxBuy(address pool, address asset) external view returns (uint256 maxTokens, uint256 maxQuote);

    /// @notice Legacy exact-output buy (partial-fill semantics; kept for reference —
    ///         the hook's swap paths use the pair below).
    /// @return tokensFilled tokens delivered (may be < amount on inventory caps).
    /// @return quotePaid    quote-asset units pulled from msg.sender.
    function buyFromPool(address pool, address asset, uint256 amount, string calldata resellerCode, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid);

    function buyFromPoolBounded(
        address pool,
        address asset,
        uint256 amount,
        string calldata resellerCode,
        address buyer,
        uint256 maxCost,
        uint256 minTokensFilled,
        uint256 deadline
    ) external returns (uint256 tokensFilled, uint256 quotePaid);

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
    function buyFromPoolExactQuote(address pool, address asset, uint256 quoteIn, string calldata resellerCode, address buyer)
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
    function buyFromPoolExactOut(address pool, address asset, uint256 tokenAmountOut, string calldata resellerCode, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid);
}
