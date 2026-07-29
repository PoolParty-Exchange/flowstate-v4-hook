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
    event PoolCreated(
        address indexed token,
        address indexed quoteAsset,
        address indexed pool,
        address creator,
        uint256 amount,
        uint16 anchorBandBps,
        uint192 seedRate
    );
    event TokensContributed(address indexed pool, address indexed owner, uint256 amount);
    event QuoteContributed(address indexed pool, address indexed owner, uint256 amount);
    event TokensWithdrawn(address indexed pool, address indexed owner, uint256 amount, bool poolEmpty);
    event QuoteWithdrawn(address indexed pool, address indexed owner, uint256 amount, bool cashSideEmpty);

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
        uint256 tokenAmount,
        uint256 quoteCredited,
        bool recycled
    );
    event FeeDistributed(
        address indexed pool,
        string resellerCode,
        uint256 resellerCut,
        uint256 bd1Cut,
        uint256 bd2Cut,
        uint256 buybackCut
    );
    event FeePushFailed(address indexed pool, address indexed receiver, uint256 amount);
    /// @dev Recycle routing (R12): distinct from QuoteContributed so each event keeps a
    ///      single meaning — QuoteContributed = explicit deposit, this = fill proceeds
    ///      joining the cash side, ContributorFilled = fill accounting.
    event ProceedsRecycled(address indexed pool, address indexed contributor, uint256 amount);
    event ProceedsClaimed(address indexed pool, address indexed user, address asset, uint256 amount);

    // ── anchor lifecycle (reseeds observable — plan R3) ──────────────────
    event AnchorReseeded(address indexed pool, uint256 newRate, uint32 epoch);

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

    // ── compliance (public-by-design) ────────────────────────────────────
    event AddressFrozen(address indexed account);
    event AddressUnfrozen(address indexed account);
    event FreezeEnabledSet(bool enabled);
}
