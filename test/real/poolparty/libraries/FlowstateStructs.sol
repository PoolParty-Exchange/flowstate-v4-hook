// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/**
 * @title FlowstateStructs
 * @notice Shared data structures for the Flowstate pass-1 rebuild.
 * @dev Spec: docs/FLOWSTATE_PASS1_IMPLEMENTATION_PLAN_2026-07-16.md (§3.1/§3.2).
 */
library FlowstateStructs {
    /// @notice Partner fee-split registration for a reseller code.
    /// @dev Invariant enforced at every write:
    ///      resellerShareBps + bd1ShareBps + bd2ShareBps == PARTNER_SHARE_BPS (6000).
    ///      All wallets are EOA-only (checked at registration AND on every update —
    ///      smart wallets are not address-portable across chains).
    struct ResellerConfig {
        address payable wallet;        // slot A
        uint16 resellerShareBps;       // slot A
        bool registered;               // slot A
        address payable bd1;           // slot B
        uint16 bd1ShareBps;            // slot B
        address payable bd2;           // slot C — address(0) ⇒ bd2ShareBps must be 0
        uint16 bd2ShareBps;            // slot C
    }

    /// @notice Factory-side registry entry for a deployed pool.
    /// @dev Multi-asset change: a pool is keyed by its inventory token alone; the
    ///      quote asset became a per-trade parameter, so the record no longer
    ///      carries one.
    struct PoolRecord {
        address inventoryToken;        // slot A
        bool exists;                   // slot A
    }

    /// @notice Per-quote-asset anchor state — the pool's own price historian for
    ///         one (inventoryToken, asset) rate. Three slots (slot C is touched only
    ///         while the anchor is stale, never on the trading hot path).
    /// @dev slot A: lastRate (24B) + lastRateTime (8B);
    ///      slot B: emaRate (24B) + lastRateEpoch (4B);
    ///      slot C: pendingRate (24B) + pendingSince (8B) — two-phase revive state.
    ///      lastRate == 0 ⇔ never seeded ⇒ the asset is untradeable in this pool
    ///      until the factory seeds it (createPool or the admin resetAnchor lane).
    ///      A pending entry is only VALID while pendingSince > lastRateTime: any
    ///      accepted anchor write stamps a fresher lastRateTime, which implicitly
    ///      invalidates leftovers from earlier stale episodes without costing the
    ///      hot path a slot-C write.
    /// @dev Slot layout is FROZEN (beacon-cloned pools; see upgrades.test.js). The
    ///      2026-08-11 one-block anchor redesign repurposed two members in place
    ///      rather than reordering: `lastRateBlock` occupies the old `lastRateTime`
    ///      slot and `pendingBlock` the old `pendingSince`. `__reservedEma` is the
    ///      retired EMA slot, kept so the layout is unchanged; it is never written.
    struct Anchor {
        uint192 lastRate;      // last ACCEPTED rate
        uint64 lastRateBlock;  // block of that acceptance (one write per block max)
        uint192 __reservedEma; // retired (was emaRate) — never read, never written
        uint32 lastRateEpoch;
        uint192 pendingRate;   // displaced read awaiting one-block confirmation (0 = none)
        uint64 pendingBlock;   // block the candidate was first seen
    }

    /// @notice Per-fill fee context, computed by the factory and passed to the pool
    ///         in calldata. Never stored.
    struct FeeContext {
        uint16 feeBps;                 // token tier: feeBpsOverride or DEFAULT_FEE_BPS
        address payable resellerWallet;
        uint16 resellerShareBps;
        address payable bd1;
        uint16 bd1ShareBps;
        address payable bd2;
        uint16 bd2ShareBps;
        address buybackReceiver;
        string resellerCode;           // forwarded so trade events emit on the pool address
    }

    /// @notice FIFO ledger node — 2 storage slots (plan R7).
    /// @dev slot A: addr (20B) + next (8B); slot B: amount (16B) + prev (8B).
    ///      Contribution amounts are bounded to uint128 at credit time.
    struct Node {
        address addr;
        uint64 next;
        uint128 amount;
        uint64 prev;
    }

    /// @notice Non-reverting quoter result (§3.1).
    struct Quote {
        bool available;
        uint256 fillableAmount;
        uint256 quoteAmount;
        uint256 feeAmount;
        uint16 feeBps;
        address quoteAsset;
    }
}
