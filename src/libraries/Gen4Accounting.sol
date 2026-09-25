// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Aggregate accounting for a gen-4 fill composed from multiple sources.
/// @dev Internal-only and independent of the final listings ABI. Actual quote debits and
///      token receipts are recorded after each source succeeds; failed listing attempts
///      change only the attempt counter, so they cannot corrupt prior fill accounting.
library Gen4Accounting {
    uint256 internal constant BPS = 10_000;

    error AttemptCapExceeded(uint256 attempts, uint256 cap);
    error CostExceedsCommittedInput(uint256 required, uint256 committed);
    error RefundExceedsRemainder(uint256 refund, uint256 remainder);
    error JarFeeExceedsSpread(uint256 jarFee, uint256 spread);
    error OutputTargetExceeded(uint256 filled, uint256 target);
    error MinimumOutputNotMet(uint256 received, uint256 minimum);

    struct Totals {
        uint256 poolTokens;
        uint256 listingTokens;
        uint256 poolQuote;
        uint256 listingQuote;
        uint256 listingAttempts;
    }

    struct Final {
        uint256 tokensOut;
        uint256 cost;
        uint256 spread;
        uint256 jarFee;
        uint256 retainedSpread;
        uint256 dust;
        uint256 refund;
        uint256 charged;
    }

    function recordPool(Totals memory totals, uint256 tokens, uint256 quote) internal pure {
        totals.poolTokens += tokens;
        totals.poolQuote += quote;
    }

    function recordListingAttempt(Totals memory totals, uint256 attemptCap, bool sold, uint256 tokens, uint256 quote)
        internal
        pure
    {
        uint256 attempts = totals.listingAttempts + 1;
        if (attempts > attemptCap) revert AttemptCapExceeded(attempts, attemptCap);
        totals.listingAttempts = attempts;
        if (!sold) return;
        totals.listingTokens += tokens;
        totals.listingQuote += quote;
    }

    /// @notice Finalize exact input from actual successful source receipts.
    /// @param refund Amount the executor has classified as genuinely unspent. The
    ///        remaining committed input is inversion/carve dust, matching gen-3's
    ///        distinct dust bucket rather than being silently folded into spread.
    function exactInput(Totals memory totals, uint256 committed, uint256 spreadBps, uint256 jarFeeBps, uint256 refund)
        internal
        pure
        returns (Final memory result)
    {
        result = _base(totals, spreadBps, jarFeeBps);
        uint256 required = result.cost + result.spread;
        if (required > committed) revert CostExceedsCommittedInput(required, committed);
        uint256 remainder = committed - required;
        if (refund > remainder) revert RefundExceedsRemainder(refund, remainder);
        result.refund = refund;
        result.dust = remainder - refund;
        result.charged = committed - refund;
    }

    function exactOutput(Totals memory totals, uint256 spreadBps, uint256 jarFeeBps)
        internal
        pure
        returns (Final memory result)
    {
        result = _base(totals, spreadBps, jarFeeBps);
        result.charged = result.cost + result.spread;
    }

    /// @notice The amount a later source may still be asked to fill.
    function remainingOutput(Totals memory totals, uint256 target) internal pure returns (uint256 remaining) {
        uint256 filled = totals.poolTokens + totals.listingTokens;
        if (filled > target) revert OutputTargetExceeded(filled, target);
        return target - filled;
    }

    function requireMinimumOutput(Totals memory totals, uint256 minimum) internal pure {
        uint256 received = totals.poolTokens + totals.listingTokens;
        if (received < minimum) revert MinimumOutputNotMet(received, minimum);
    }

    function _base(Totals memory totals, uint256 spreadBps, uint256 jarFeeBps)
        private
        pure
        returns (Final memory result)
    {
        result.tokensOut = totals.poolTokens + totals.listingTokens;
        result.cost = totals.poolQuote + totals.listingQuote;
        result.spread = Math.mulDiv(result.cost, spreadBps, BPS, Math.Rounding.Ceil);
        result.jarFee = Math.mulDiv(result.cost, jarFeeBps, BPS, Math.Rounding.Ceil);
        if (result.jarFee > result.spread) revert JarFeeExceedsSpread(result.jarFee, result.spread);
        result.retainedSpread = result.spread - result.jarFee;
    }
}
