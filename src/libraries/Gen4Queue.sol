// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @notice Internal-only planning primitives for the gen-4 mixed inventory lane.
/// @dev This is deliberately not an interface to the listings contracts. Adapters must
///      translate the final JUP-697/JUP-696 surfaces into a resolved, globally comparable
///      key before this library will choose between pool and listing inventory.
library Gen4Queue {
    enum Source {
        None,
        Pool,
        Listing
    }

    struct OrderKey {
        // The shared chain counter. A zero sentinel is unresolved unless the adapter has
        // additional metadata that safely normalizes it into a real total-order key.
        uint64 createdBlock;
        // Cross-source ordering within one counter value. Its meaning is intentionally
        // left to the final protocol contract; a source-local id is not sufficient.
        uint64 tieBreaker;
        bool resolved;
    }

    struct Candidate {
        Source source;
        uint256 available;
        OrderKey order;
        // False when the source cannot distinguish a truly empty queue from bounded
        // traversal/cleaning exhaustion. Unknown is never treated as absent.
        bool definitive;
    }

    /// @notice Select the older available source, or report that ordering is blocked.
    /// @dev An unresolved candidate is usable when it has no competitor: its own source
    ///      already preserves local FIFO. It is never compared across sources.
    function select(Candidate memory pool, Candidate memory listing)
        internal
        pure
        returns (Source source, bool blocked)
    {
        if (!pool.definitive || !listing.definitive) return (Source.None, true);
        bool hasPool = pool.available != 0;
        bool hasListing = listing.available != 0;
        if (!hasPool) return hasListing ? (Source.Listing, false) : (Source.None, false);
        if (!hasListing) return (Source.Pool, false);

        // Zero is the overloaded unstamped sentinel. It is never a valid cross-source
        // order value, even if a future adapter accidentally marks the key resolved.
        // A genuinely normalized global key must be represented with a non-zero major.
        if (pool.order.createdBlock == 0 || listing.order.createdBlock == 0) return (Source.None, true);
        if (!pool.order.resolved || !listing.order.resolved) return (Source.None, true);
        if (pool.order.createdBlock < listing.order.createdBlock) return (Source.Pool, false);
        if (listing.order.createdBlock < pool.order.createdBlock) return (Source.Listing, false);
        if (pool.order.tieBreaker < listing.order.tieBreaker) return (Source.Pool, false);
        if (listing.order.tieBreaker < pool.order.tieBreaker) return (Source.Listing, false);

        // Equal keys are not silently resolved with a source preference. The final
        // protocol must supply either unique metadata or an explicit tie rule.
        return (Source.None, true);
    }
}
