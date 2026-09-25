// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Gen4Queue} from "../src/libraries/Gen4Queue.sol";
import {Gen4Accounting} from "../src/libraries/Gen4Accounting.sol";

/// @dev Test-only stand-in for the required one-candidate settlement semantics.
///      This is intentionally not a proposed production interface.
contract MockSelectedListingSettlement {
    error SettlementFailed();

    function attempt(bool fail, uint256 tokens, uint256 quote) external pure returns (uint256, uint256) {
        if (fail) revert SettlementFailed();
        return (tokens, quote);
    }
}

/// @notice Deterministic pre-integration model for JUP-698.
/// @dev No type here is a proposed JUP-697 ABI. The model states only the semantics
///      the hook needs from whichever final registry/settlement surface lands.
contract Gen4MixedQueueModelTest is Test {
    using Gen4Queue for Gen4Queue.Candidate;

    uint256 internal constant SPREAD_BPS = 16;
    uint256 internal constant JAR_BPS = 8;

    struct Listing {
        uint64 createdBlock;
        uint64 tieBreaker;
        uint256 tokens;
        uint256 quote;
        bool live;
        bool settlementReverts;
    }

    function _candidate(Gen4Queue.Source source, uint64 block_, uint64 tie, uint256 available, bool resolved)
        internal
        pure
        returns (Gen4Queue.Candidate memory)
    {
        return Gen4Queue.Candidate(source, available, Gen4Queue.OrderKey(block_, tie, resolved), true);
    }

    function _select(Gen4Queue.Candidate memory pool, Gen4Queue.Candidate memory listing)
        internal
        pure
        returns (Gen4Queue.Source source, bool blocked)
    {
        return Gen4Queue.select(pool, listing);
    }

    function test_PoolOlderThanListing() public pure {
        (Gen4Queue.Source source, bool blocked) = _select(
            _candidate(Gen4Queue.Source.Pool, 10, 1, 5, true), _candidate(Gen4Queue.Source.Listing, 11, 1, 5, true)
        );
        assertFalse(blocked);
        assertEq(uint256(source), uint256(Gen4Queue.Source.Pool));
    }

    function test_ListingOlderThanPool() public pure {
        (Gen4Queue.Source source, bool blocked) = _select(
            _candidate(Gen4Queue.Source.Pool, 11, 1, 5, true), _candidate(Gen4Queue.Source.Listing, 10, 1, 5, true)
        );
        assertFalse(blocked);
        assertEq(uint256(source), uint256(Gen4Queue.Source.Listing));
    }

    function test_SameBlockUsesOnlyCrossSourceTieMetadata() public pure {
        (Gen4Queue.Source source, bool blocked) = _select(
            _candidate(Gen4Queue.Source.Pool, 10, 7, 5, true), _candidate(Gen4Queue.Source.Listing, 10, 8, 5, true)
        );
        assertFalse(blocked);
        assertEq(uint256(source), uint256(Gen4Queue.Source.Pool));
    }

    function test_SameBlockWithoutUniqueTieMetadataBlocks() public pure {
        (Gen4Queue.Source source, bool blocked) = _select(
            _candidate(Gen4Queue.Source.Pool, 10, 0, 5, true), _candidate(Gen4Queue.Source.Listing, 10, 0, 5, true)
        );
        assertTrue(blocked);
        assertEq(uint256(source), uint256(Gen4Queue.Source.None));
    }

    function test_UnstampedPoolNeverSortsNumericallyAheadOfListing() public pure {
        (Gen4Queue.Source source, bool blocked) = _select(
            _candidate(Gen4Queue.Source.Pool, 0, 0, 5, false), _candidate(Gen4Queue.Source.Listing, 100, 1, 5, true)
        );
        assertTrue(blocked);
        assertEq(uint256(source), uint256(Gen4Queue.Source.None));
    }

    function test_UnstampedPoolStillBlocksIfAdapterIncorrectlyMarksItResolved() public pure {
        (Gen4Queue.Source source, bool blocked) = _select(
            _candidate(Gen4Queue.Source.Pool, 0, 99, 5, true), _candidate(Gen4Queue.Source.Listing, 100, 1, 5, true)
        );
        assertTrue(blocked);
        assertEq(uint256(source), uint256(Gen4Queue.Source.None));
    }

    function test_UnstampedLocalHeadCanRunWhenNoCompetingSourceExists() public pure {
        (Gen4Queue.Source source, bool blocked) = _select(
            _candidate(Gen4Queue.Source.Pool, 0, 0, 5, false), _candidate(Gen4Queue.Source.Listing, 0, 0, 0, false)
        );
        assertFalse(blocked);
        assertEq(uint256(source), uint256(Gen4Queue.Source.Pool));
    }

    function test_UnknownListingHeadNeverFallsBackToPool() public pure {
        Gen4Queue.Candidate memory pool = _candidate(Gen4Queue.Source.Pool, 20, 1, 5, true);
        Gen4Queue.Candidate memory listing = _candidate(Gen4Queue.Source.Listing, 0, 0, 0, false);
        listing.definitive = false; // e.g. bounded traversal exhausted, not proven empty
        (Gen4Queue.Source source, bool blocked) = _select(pool, listing);
        assertTrue(blocked);
        assertEq(uint256(source), uint256(Gen4Queue.Source.None));
    }

    /// @dev Regression for the current PR #54 shape. An amount-based settleHead can
    ///      skip dead listing A and sell younger listing C, even though pool B should
    ///      have been re-compared and selected after A was pruned.
    function test_UnsafeSettlementCanJumpAcrossOlderPoolNode() public pure {
        Listing[2] memory listings = [Listing(10, 1, 4, 40, false, false), Listing(30, 1, 4, 40, true, false)];
        uint64 poolBlock = 20;

        uint256 soldIndex = _unsafeSettleAmount(listings);
        assertEq(soldIndex, 1, "unsafe API consumed younger listing");
        assertGt(listings[soldIndex].createdBlock, poolBlock, "pool node was older and should have won");

        // Required semantics: attempt exactly the selected head, observe SKIPPED,
        // then re-read both heads before any younger listing can be consumed.
        bool firstSold = _attemptSelected(listings[0]);
        assertFalse(firstSold);
        (Gen4Queue.Source source, bool blocked) = _select(
            _candidate(Gen4Queue.Source.Pool, poolBlock, 1, 4, true),
            _candidate(Gen4Queue.Source.Listing, listings[1].createdBlock, listings[1].tieBreaker, 4, true)
        );
        assertFalse(blocked);
        assertEq(uint256(source), uint256(Gen4Queue.Source.Pool));
    }

    function test_FailedAttemptDoesNotCorruptEarlierSuccessfulAccounting() public pure {
        Gen4Accounting.Totals memory totals;
        Gen4Accounting.recordPool(totals, 3, 30);
        Gen4Accounting.recordListingAttempt(totals, 3, true, 2, 20);
        Gen4Accounting.recordListingAttempt(totals, 3, false, 999, 999);

        Gen4Accounting.Final memory result = Gen4Accounting.exactOutput(totals, SPREAD_BPS, JAR_BPS);
        assertEq(totals.listingAttempts, 2);
        assertEq(result.tokensOut, 5);
        assertEq(result.cost, 50);
        assertEq(result.spread, 1);
        assertEq(result.jarFee, 1);
    }

    function test_RevertingExternalSettlementDoesNotCorruptEarlierAccounting() public {
        MockSelectedListingSettlement settlement = new MockSelectedListingSettlement();
        Gen4Accounting.Totals memory totals;
        Gen4Accounting.recordPool(totals, 3, 30);

        try settlement.attempt(true, 999, 999) returns (uint256 tokens, uint256 quote) {
            Gen4Accounting.recordListingAttempt(totals, 2, true, tokens, quote);
        } catch {
            Gen4Accounting.recordListingAttempt(totals, 2, false, 0, 0);
        }

        Gen4Accounting.Final memory result = Gen4Accounting.exactOutput(totals, SPREAD_BPS, JAR_BPS);
        assertEq(totals.listingAttempts, 1);
        assertEq(result.tokensOut, 3);
        assertEq(result.cost, 30);
    }

    function test_AttemptCapCountsFailures() public {
        Gen4Accounting.Totals memory totals;
        Gen4Accounting.recordListingAttempt(totals, 2, false, 0, 0);
        Gen4Accounting.recordListingAttempt(totals, 2, false, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(Gen4Accounting.AttemptCapExceeded.selector, 3, 2));
        this.recordListingAttempt(totals, 2, true, 1, 10);
    }

    function test_ExactInputRefundsOnlyClassifiedUnspentInput() public pure {
        Gen4Accounting.Totals memory totals;
        Gen4Accounting.recordPool(totals, 3, 30);
        Gen4Accounting.recordListingAttempt(totals, 4, true, 4, 40);

        Gen4Accounting.Final memory result = Gen4Accounting.exactInput(totals, 100, SPREAD_BPS, JAR_BPS, 28);
        assertEq(result.tokensOut, 7);
        assertEq(result.cost, 70);
        assertEq(result.spread, 1);
        assertEq(result.jarFee, 1);
        assertEq(result.refund, 28);
        assertEq(result.dust, 1);
        assertEq(result.charged, 72);
    }

    function test_ExactOutputAggregatesBeforeSpreadAndNeverDoubleCountsSatisfiedAmount() public pure {
        Gen4Accounting.Totals memory totals;
        // Listing satisfies 4 first; the pool is asked only for the remaining 6.
        Gen4Accounting.recordListingAttempt(totals, 4, true, 4, 40);
        uint256 target = 10;
        uint256 poolRequest = Gen4Accounting.remainingOutput(totals, target);
        Gen4Accounting.recordPool(totals, poolRequest, 60);

        Gen4Accounting.Final memory result = Gen4Accounting.exactOutput(totals, SPREAD_BPS, JAR_BPS);
        assertEq(poolRequest, 6);
        assertEq(result.tokensOut, target);
        assertEq(result.cost, 100);
        assertEq(result.spread, 1);
        assertEq(result.jarFee, 1);
        assertEq(result.charged, 101);
    }

    function test_PartialPoolThenListingAggregatesInExecutionOrder() public pure {
        Gen4Accounting.Totals memory totals;
        Gen4Accounting.recordPool(totals, 4, 40);
        uint256 listingRequest = Gen4Accounting.remainingOutput(totals, 10);
        Gen4Accounting.recordListingAttempt(totals, 2, true, listingRequest, 60);
        Gen4Accounting.Final memory result = Gen4Accounting.exactOutput(totals, SPREAD_BPS, JAR_BPS);
        assertEq(listingRequest, 6);
        assertEq(result.tokensOut, 10);
        assertEq(result.cost, 100);
    }

    function test_PartialListingThenPoolAggregatesInExecutionOrder() public pure {
        Gen4Accounting.Totals memory totals;
        Gen4Accounting.recordListingAttempt(totals, 2, true, 4, 40);
        uint256 poolRequest = Gen4Accounting.remainingOutput(totals, 10);
        Gen4Accounting.recordPool(totals, poolRequest, 60);
        Gen4Accounting.Final memory result = Gen4Accounting.exactOutput(totals, SPREAD_BPS, JAR_BPS);
        assertEq(poolRequest, 6);
        assertEq(result.tokensOut, 10);
        assertEq(result.cost, 100);
    }

    function test_AggregateRoundingAvoidsPerChunkSpreadInflation() public pure {
        Gen4Accounting.Totals memory totals;
        Gen4Accounting.recordPool(totals, 1, 1);
        Gen4Accounting.recordListingAttempt(totals, 1, true, 1, 1);
        Gen4Accounting.Final memory result = Gen4Accounting.exactOutput(totals, SPREAD_BPS, JAR_BPS);
        assertEq(result.spread, 1, "spread must be computed once over aggregate cost");
    }

    function test_AccountingTotalsAreCurrencyRepresentationAgnostic() public pure {
        Gen4Accounting.Totals memory token0Quote = _twoSourceTotals();
        Gen4Accounting.Totals memory token1Quote = _twoSourceTotals();
        Gen4Accounting.Totals memory nativeWrappedQuote = _twoSourceTotals();

        Gen4Accounting.Final memory a = Gen4Accounting.exactOutput(token0Quote, SPREAD_BPS, JAR_BPS);
        Gen4Accounting.Final memory b = Gen4Accounting.exactOutput(token1Quote, SPREAD_BPS, JAR_BPS);
        Gen4Accounting.Final memory c = Gen4Accounting.exactOutput(nativeWrappedQuote, SPREAD_BPS, JAR_BPS);
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)));
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(c)));
    }

    function test_MinimumOutputCanBeCheckedOnAggregateReceipt() public pure {
        Gen4Accounting.Totals memory totals = _twoSourceTotals();
        Gen4Accounting.Final memory result = Gen4Accounting.exactInput(totals, 100, SPREAD_BPS, JAR_BPS, 28);
        uint256 minimumOutput = 8;
        Gen4Accounting.requireMinimumOutput(totals, minimumOutput);
        assertEq(result.tokensOut, minimumOutput);
    }

    function test_MinimumOutputEnforcementRevertsBelowFloor() public {
        Gen4Accounting.Totals memory totals = _twoSourceTotals();
        vm.expectRevert(abi.encodeWithSelector(Gen4Accounting.MinimumOutputNotMet.selector, 8, 9));
        this.requireMinimumOutput(totals, 9);
    }

    function _twoSourceTotals() internal pure returns (Gen4Accounting.Totals memory totals) {
        Gen4Accounting.recordPool(totals, 3, 30);
        Gen4Accounting.recordListingAttempt(totals, 4, true, 5, 40);
    }

    /// @dev External test boundary so Foundry can observe a library revert at a lower
    ///      call depth than the expectRevert cheatcode.
    function recordListingAttempt(
        Gen4Accounting.Totals memory totals,
        uint256 cap,
        bool sold,
        uint256 tokens,
        uint256 quote
    ) external pure returns (Gen4Accounting.Totals memory) {
        Gen4Accounting.recordListingAttempt(totals, cap, sold, tokens, quote);
        return totals;
    }

    function requireMinimumOutput(Gen4Accounting.Totals memory totals, uint256 minimum) external pure {
        Gen4Accounting.requireMinimumOutput(totals, minimum);
    }

    function _unsafeSettleAmount(Listing[2] memory listings) internal pure returns (uint256 soldIndex) {
        for (uint256 i; i < listings.length; ++i) {
            if (listings[i].live && !listings[i].settlementReverts) return i;
        }
        return type(uint256).max;
    }

    function _attemptSelected(Listing memory listing) internal pure returns (bool sold) {
        return listing.live && !listing.settlementReverts;
    }
}
