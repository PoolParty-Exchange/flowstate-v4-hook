// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/**
 * @title FlowstateEvents
 * @notice Central event declarations for the Flowstate pass-1 rebuild.
 * @dev Emitted by FlowstateMarket (registry/config events) and FlowstatePool
 *      (trade/ledger events) — the emitting contract's address is the log address.
 *      Topic0 of every event here is pinned by test/unit/flowstate/eventTopics.test.js;
 *      changing a signature requires touching that snapshot (indexer coordination gate).
 */
library FlowstateEvents {
    // ── pools & liquidity ────────────────────────────────────────────────
    /// @dev Multi-asset: one pool per token. Per-asset seed rates are emitted as
    ///      one AnchorReseeded per seeded asset in the same transaction.
    event PoolCreated(
        address indexed token,
        address indexed pool,
        address creator,
        uint256 amount,
        uint16 anchorBandBps
    );
    event TokensContributed(address indexed pool, address indexed owner, uint256 amount);
    event QuoteContributed(
        address indexed pool, address indexed owner, address indexed asset, uint256 amount
    );
    event TokensWithdrawn(address indexed pool, address indexed owner, uint256 amount, bool poolEmpty);
    event QuoteWithdrawn(
        address indexed pool, address indexed owner, address indexed asset, uint256 amount, bool cashSideEmpty
    );

    // ── trading (replaces PoolPurchaseData — plan D5) ────────────────────
    event PoolBuy(
        address indexed pool,
        address indexed buyer,
        address indexed quoteAsset,
        uint256 tokenAmount,
        uint256 quotePaid,
        uint256 rate,
        uint256 feeAmount,
        bool poolEmpty, // token inventory exhausted by this fill
        string resellerCode
    );
    event PoolSell(
        address indexed pool,
        address indexed seller,
        address indexed quoteAsset,
        uint256 tokenAmount,
        uint256 quoteProceeds,
        uint256 rate,
        uint256 feeAmount,
        bool cashSideEmpty, // buy-back funds exhausted by this fill
        string resellerCode
    );
    event ContributorFilled(
        address indexed pool,
        address indexed contributor,
        address indexed asset, // the asset quoteCredited (buy) / tokenAmount's payment (sell) is denominated in
        uint256 tokenAmount,
        uint256 quoteCredited,
        bool recycled
    );
    event FeeDistributed(
        address indexed pool,
        address indexed asset, // fee denomination: the traded quote asset
        string resellerCode,
        uint256 resellerCut,
        uint256 bd1Cut,
        uint256 bd2Cut,
        uint256 buybackCut
    );
    event FeePushFailed(
        address indexed pool, address indexed receiver, address asset, uint256 amount
    );
    /// @dev Recycle routing (R12): distinct from QuoteContributed so each event keeps a
    ///      single meaning — QuoteContributed = explicit deposit, this = fill proceeds
    ///      joining the cash side, ContributorFilled = fill accounting. Recycle only
    ///      fires when the traded asset IS the buy-back asset, so no asset field.
    event ProceedsRecycled(address indexed pool, address indexed contributor, uint256 amount);
    event ProceedsClaimed(address indexed pool, address indexed user, address asset, uint256 amount);

    // ── anchor lifecycle (reseeds observable — plan R3) ──────────────────
    /// @dev Emitted on every band-check-FREE anchor write. Since 2026-08-13 that is
    ///      EXACTLY TWO lanes, both human-attested: createPool seeding and the admin
    ///      resetAnchor lane. The oracle-epoch reseed used to be a third and no
    ///      longer is — a migrated oracle's first read now earns adoption under the
    ///      ordinary band and confirmation rules (see OracleEpochRecorded).
    event AnchorReseeded(address indexed pool, address indexed asset, uint256 newRate, uint32 epoch);
    /// @dev A pool has RECORDED a new oracle epoch. Deliberately not "Adopted":
    ///      no rate is adopted here and none is in effect because of this event.
    ///      It is a marker, so operators and auditors can see which (pool, asset)
    ///      pairs have absorbed a migration without inferring it from the ABSENCE
    ///      of a reseed. The rate that follows earns its way in through the normal
    ///      band/confirmation path like any other read.
    /// @param clearedCandidate the displaced level that was awaiting confirmation
    ///        when the migration landed, discarded because a candidate belongs to
    ///        the oracle that produced it. Zero when there was none. Emitted for
    ///        post-hoc analysis: a non-zero value means someone had a candidate
    ///        open at the moment of a migration, which is worth looking at.
    event OracleEpochRecorded(
        address indexed pool, address indexed asset, uint32 epoch, uint256 clearedCandidate
    );
    /// @dev Emitted by pokeAnchor: a band-CHECKED, trade-less anchor advance (the
    ///      freshness keeper's path). Deliberately distinct from AnchorReseeded so
    ///      monitoring can tell "checked advance" from "unchecked reseed" at topic0.
    event AnchorPoked(address indexed pool, address indexed asset, uint256 newRate, uint256 emaRate);
    /// @dev Two-phase revive of a STALE anchor: a poke opened (or replaced) the
    ///      pending reference now under its public contest window. Any poke reading
    ///      outside one band of `pendingRate` cancels it and becomes the new pending.
    event AnchorRevivePending(address indexed pool, address indexed asset, uint256 pendingRate, uint64 since);
    /// @dev The pending reference survived its full contest window and the anchor
    ///      re-activated at `newRate` (EMA restarts there — the blind period
    ///      invalidates prior history).
    event AnchorRevived(address indexed pool, address indexed asset, uint256 newRate);

    // ── partner registry ─────────────────────────────────────────────────
    event ResellerRegistered(
        string indexed code,
        address wallet,
        uint16 resellerShareBps,
        address bd1,
        uint16 bd1ShareBps,
        address bd2,
        uint16 bd2ShareBps
    );
    event ResellerShareUpdated(string indexed code, uint16 r, uint16 b1, uint16 b2);
    event ResellerWalletUpdated(string indexed code, address oldWallet, address newWallet);
    event BdWalletUpdated(string indexed code, uint8 slot, address oldWallet, address newWallet);

    // ── fees & config ────────────────────────────────────────────────────
    event FeeBpsSet(address indexed token, uint16 feeBps);
    event QuoteAssetSet(address indexed asset, bool approved);
    event AnchorBandUpdated(address indexed pool, uint16 bandBps);
    event PriceSourceUpdated(address indexed pool, uint8 source);
    event BuyBackConfigured(
        address indexed pool,
        address indexed asset, // the ONE asset the cash side runs in (multi-asset scope cut)
        bool enabled,
        uint16 spreadBps,
        uint128 maxQuotePerWindow,
        uint32 windowSeconds
    );
    event RecycleOptInSet(address indexed pool, address indexed user, bool optIn);
    event PoolPausedSet(address indexed pool, bool paused);
    event PoolBeaconUpdated(address beacon);
    event BeaconProxyTemplateUpdated(address template);
    /// @notice A new FlowstatePool implementation went live on the beacon — every
    ///         existing pool clone moves in lock-step on the next call.
    event PoolImplementationUpgraded(address newImplementation);
    /// @notice The 12h EMERGENCY upgrade lane was used instead of the 48h lane.
    ///         ERC-1967 already emits Upgraded; this exists so emergency use is loudly
    ///         distinguishable in the read model and in monitoring, on BOTH the market
    ///         (UUPS) and the pool-implementation (beacon) paths.
    event EmergencyUpgradeAuthorized(address newImplementation, address authorizer);
    event PriceOracleUpdated(address oldOracle, address newOracle, uint32 newEpoch);
    event BuybackReceiverUpdated(address receiver);

    // ── JUP-587: createPool hook auto-registration ───────────────────────
    event TrustedHookUpdated(address oldHook, address newHook);
    event HookPairAutoRegistered(address indexed pool, address indexed token, address indexed asset);
    /// @dev The provisioner's repair signal: a pool was created whose V4 doorway
    ///      could not be opened in-transaction. Creation itself never reverts for this.
    event HookPairAutoRegistrationFailed(address indexed pool, address indexed token, address indexed asset);

    // ── compliance (public-by-design) ────────────────────────────────────
    event AddressFrozen(address indexed account);
    event AddressUnfrozen(address indexed account);
    event FreezeEnabledSet(bool enabled);
}
