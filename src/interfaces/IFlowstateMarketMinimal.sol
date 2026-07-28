// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice Minimal market surface the V4 hook consumes. Shaped to match the pass-1
///         FlowstateMarket (pull-exact model) plus the additive exact-quote entry point
///         from the build scope §2.2, so Phase 1 swaps the Phase 0 mock for the real
///         market with no hook changes.
/// @dev Pull-exact: the market computes the oracle cost internally and pulls exactly
///      that many quote-asset units from msg.sender via transferFrom, then delivers
///      the tokens to `buyer`. Fill semantics are all-or-nothing with typed reverts.
interface IFlowstateMarketMinimal {
    /// @notice Exact-output buy: caller names the token amount, market pulls the cost.
    /// @param pool          C1 pool to buy from.
    /// @param amount        token amount to buy.
    /// @param resellerCode  fee-attribution code; "" for none.
    /// @param buyer         recipient of the purchased tokens.
    /// @return tokensFilled tokens delivered (== amount under all-or-nothing).
    /// @return quotePaid    quote-asset units pulled from msg.sender.
    function buyFromPool(address pool, uint256 amount, string calldata resellerCode, address buyer)
        external
        returns (uint256 tokensFilled, uint256 quotePaid);

    /// @notice Exact-input buy: caller names the quote amount, market pulls exactly it
    ///         and delivers the tokens it buys, inverting inside a single oracle read.
    /// @param pool          C1 pool to buy from.
    /// @param quoteIn       quote-asset units to spend (pulled exactly).
    /// @param resellerCode  fee-attribution code; "" for none.
    /// @param buyer         recipient of the purchased tokens.
    /// @return tokensFilled tokens delivered.
    function buyFromPoolExactQuote(address pool, uint256 quoteIn, string calldata resellerCode, address buyer)
        external
        returns (uint256 tokensFilled);

    /// @notice View twin of buyFromPool's pricing.
    /// @return quoteCost quote-asset units buyFromPool would pull for `amount` tokens.
    function quoteBuyFromPool(address pool, uint256 amount) external view returns (uint256 quoteCost);
}
