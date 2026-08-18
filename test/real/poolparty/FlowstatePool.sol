// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interface/IOracle.sol";
import "./libraries/FlowstateStructs.sol";
import "./libraries/FlowstateEvents.sol";

/**
 * @title FlowstatePool
 * @notice Fair-price pool for ONE inventory token, tradeable against EVERY approved
 *         quote asset (multi-asset change, stage one). Beacon-proxy implementation
 *         cloned per pool. Pass-1 rebuild of publicPool.sol.
 *
 * @dev Spec: docs/FLOWSTATE_PASS1_IMPLEMENTATION_PLAN_2026-07-16.md §3.2, as amended
 *      by the multi-asset + anchor-hardening pass (roadmap items 1 and 2, 2026-07-30).
 *
 * MULTI-ASSET MODEL. The pool's identity is the inventory token alone. Buyers name
 * the quote asset per trade; token-side depositors never choose one — their fill
 * proceeds are credited in whatever asset each buy arrived in, so claimableQuote is
 * per (asset, user) and a depositor may claim a mix (explained in depositor-facing
 * material). The cash side (buy-back, ships OFF) deliberately runs in ONE designated
 * asset per pool (`buybackAsset`): a per-asset cash FIFO would multiply the sell
 * path's complexity for a feature not yet enabled anywhere. Sellers are paid in that
 * designated asset.
 *
 * Fee incidence (single model, both legs): the fee is always levied on the
 * pool-payout leg, denominated in the TRADED quote asset. On a BUY the token-side
 * contributors (sellers) pay it — they are credited quotePaid − fee. On a SELL
 * (M2) the seller receives quoteGross − fee. Buyers never pay the fee.
 *
 * ANCHOR MODEL (hardened — bopAMM review §3.4 items 1/3/4; items 2 and 5 were
 * considered and rejected). One anchor per quote asset, since token/USDC and
 * token/WETH are different rates. Each anchor stores the last ACCEPTED rate, its
 * timestamp, and an EMA of accepted rates (tau = ANCHOR_TAU). A fresh oracle read
 * must pass BOTH checks:
 *   step band — within anchorBandBps × widen of the last accepted rate, where
 *               widen = 1 + elapsed/60 capped at 4 (max 20% at the 5% default).
 *               Bounds any single jump; an atomic flash-crash reverts against the
 *               pre-attack anchor.
 *   walk band — within anchorBandBps × WALK_BAND_MULT of the EMA (10% at the 5%
 *               default). Bounds CUMULATIVE travel: a patient attacker nudging the
 *               venue price block after block (each step inside the band)
 *               previously walked the anchor arbitrarily far; now the EMA trails
 *               accepted rates with a 1h time constant, so walking at full speed
 *               multiplies price by only e^(walkBand × T / tau) — doubling takes
 *               ~7h of SUSTAINED venue manipulation at defaults, paying venue costs
 *               the whole way. Genuine vertical pumps decline fills until the EMA
 *               catches up — the correct side of the trade-off, because vertical
 *               moves are when oracle-priced depositors get picked off. Pools that
 *               need more room get a wider per-pool band (≤ 50%); the admin
 *               resetAnchor lane is the liveness escape hatch (D3).
 *   freshness — an anchor older than MAX_ANCHOR_AGE declines to trade instead of
 *               silently accepting anything inside the fully-widened band. The
 *               permissionless factory-routed pokeAnchor advances an anchor through
 *               the identical checked path with no trade attached (keeper duty), so
 *               an honest idle pool never goes stale. A pool that DOES go stale
 *               revives through the two-phase public contest documented at
 *               pokeAnchor, or through admin resetAnchor.
 *   monotonic — the anchor timestamp never moves backwards (structural guard).
 * Seeding is band-check-free BY DEFINITION (there is nothing to check against), so
 * whoever picks the seeding moment picks the price. Therefore seeding is factory-
 * gated only: createPool (the depositor picks the moment) and the admin resetAnchor
 * lane (instant multisig). There is NO permissionless lazy seeding on the trade
 * path. An unseeded asset simply declines. An oracle-address migration at the
 * factory bumps its epoch; a pool seeing a new epoch reseeds band-check-free on its
 * next trade per asset — safe because setPriceOracle is timelocked (announced),
 * never attacker-triggerable.
 */
contract FlowstatePool is Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    error OnlyFactory();
    error InvalidInitParams();
    error PoolIsPaused();
    error NoLiquidity();
    error InvalidAmount();
    error AmountTooLarge();
    error AmountTooSmall();
    error NoOracleRate();
    error RateOutOfBand();
    error AnchorWalkExceeded();
    error AnchorNotSeeded();
    error AnchorAlreadySeeded();
    error StaleAnchor();
    error NotAContributor();
    error InsufficientPosition();
    error InvalidBand();
    error BuyBackDisabled();
    error BuybackAssetUnset();
    error CashSideNotEmpty();
    error SpreadTooHigh();
    error InvalidWindowConfig();
    error InvalidPriceSource();
    error FillShortfall();

    // ── constants ────────────────────────────────────────────────────────
    uint256 private constant BPS = 10_000;
    uint256 private constant RATE_SCALE = 1e18; // quoteCost = amount × rate / 1e18
    uint256 private constant WIDEN_PERIOD = 60; // seconds per +1 band multiple (R1)
    uint256 private constant MAX_WIDEN = 4;     // max band multiple (40% at 10% band)
    uint256 private constant MAX_FILL_NODES = 50; // deterministic partial-fill cap
    uint16 private constant MIN_BAND_BPS = 100;
    uint16 private constant MAX_BAND_BPS = 5000;
    uint16 private constant MAX_SPREAD_BPS = 1000; // buy-side spread ceiling: 10%
    // anchor hardening (items 1/3/4 of the approved §3.4 bundle)
    uint256 private constant ANCHOR_TAU = 1 hours;      // EMA time constant
    uint256 private constant MAX_ANCHOR_AGE = 24 hours; // freshness bound (item 1)
    uint256 private constant WALK_BAND_MULT = 2;        // walk band = 2 × anchorBandBps
    uint256 private constant REVIVE_WINDOW = 30 minutes; // two-phase revive contest window

    // ── storage (fresh layout; OZ bases are ERC-7201 namespaced) ─────────
    // slot 0 — identity + flags (single warm slot on the hot path)
    address public inventoryToken;
    uint16 public anchorBandBps;
    uint8 public priceSource;      // RESERVED (parked) — always 0 = AGGREGATOR in pass 1
    bool public buyBackEnabled;    // ships OFF; sell path lands in M2
    bool public poolPaused;
    bool public isHidden;
    // slot 1 — the ONE asset the cash side / sell path runs in (multi-asset scope cut)
    address public buybackAsset;
    uint16 public buySpreadBps;
    // slot 2
    address public factory;
    // per-asset anchors (2 slots each — see FlowstateStructs.Anchor)
    mapping(address => FlowstateStructs.Anchor) private anchors;
    // seeded-asset enumeration: claim loops and views iterate this, bounded by the
    // chain's approved-asset set (small by policy)
    address[] private seededAssetList;
    // inventory accounting. quoteBalance is denominated in buybackAsset.
    uint256 public tokenBalance;
    uint256 public quoteBalance;
    // buy-back window cap (used from M2), denominated in buybackAsset
    uint128 public maxQuotePerWindow;
    uint128 public quoteSpentInWindow;
    uint64 public windowStart;
    uint32 public windowSeconds;
    // token-side FIFO ledger (index 0 = sentinel)
    FlowstateStructs.Node[] private tokenNodes;
    uint64 private tokenHead;
    uint64 private tokenTail;
    // cash-side FIFO ledger (used from M2; buybackAsset-denominated)
    FlowstateStructs.Node[] private cashNodes;
    uint64 private cashHead;
    uint64 private cashTail;
    mapping(address => uint256) private tokenIndex;
    mapping(address => uint256) private cashIndex;
    // pool-local claim ledgers (plan D2). claimableQuote is per (asset, user):
    // buy proceeds arrive in whatever asset the buyer paid with.
    mapping(address => mapping(address => uint256)) public claimableQuote;
    mapping(address => uint256) public claimableTokens;
    mapping(address => bool) public recycleOptIn;
    uint256[22] private __gap;

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Anchors are NOT seeded here — the factory seeds each priceable approved
    ///      asset via seedAnchor immediately after, in the same createPool transaction
    ///      (the depositor still picks the seeding moment; R13's "no unchecked first
    ///      trade" holds per asset).
    function initialize(address token, address factory_, uint16 bandBps) external initializer {
        if (token == address(0) || factory_ == address(0)) revert InvalidInitParams();
        if (bandBps < MIN_BAND_BPS || bandBps > MAX_BAND_BPS) revert InvalidBand();
        __ReentrancyGuard_init();

        inventoryToken = token;
        factory = factory_;
        anchorBandBps = bandBps;
        buySpreadBps = 50; // default 0.5%; adjustable via setBuyBack (M2)

        // sentinel node at index 0 for both FIFO lists
        tokenNodes.push(FlowstateStructs.Node(address(0), 0, 0, 0));
        cashNodes.push(FlowstateStructs.Node(address(0), 0, 0, 0));
    }

    // ────────────────────────────────────────────────────────────────────
    // Anchor lifecycle (factory-only writes; §3.4 hardening)
    // ────────────────────────────────────────────────────────────────────

    /// @notice First observation for an asset — createPool's per-asset seeding.
    ///         Band-check-free by definition; refuses to overwrite a live anchor
    ///         (that is resetAnchor's job, behind the admin lane).
    function seedAnchor(address asset, uint192 seedRate, uint32 seedEpoch) external onlyFactory {
        if (asset == address(0) || seedRate == 0) revert InvalidInitParams();
        FlowstateStructs.Anchor storage a = anchors[asset];
        if (a.lastRate != 0) revert AnchorAlreadySeeded();
        _writeAnchor(a, asset, seedRate, seedRate, seedEpoch);
        seededAssetList.push(asset);
        emit FlowstateEvents.AnchorReseeded(address(this), asset, seedRate, seedEpoch);
    }

    /// @notice Liveness escape hatch (D3): unconditionally re-anchors ONE asset to a
    ///         fresh read. Also the late-seeding lane for assets approved after this
    ///         pool was created. Admin-gated at the factory.
    function resetAnchor(address asset, address oracle, uint32 epoch) external onlyFactory {
        uint256 fresh = _readOracle(asset, oracle);
        FlowstateStructs.Anchor storage a = anchors[asset];
        if (a.lastRate == 0) seededAssetList.push(asset);
        _writeAnchor(a, asset, uint192(fresh), uint192(fresh), epoch);
        emit FlowstateEvents.AnchorReseeded(address(this), asset, fresh, epoch);
    }

    /// @notice Freshness keeper (§3.4 item 1): a band-CHECKED, trade-less anchor
    ///         advance. On a LIVE anchor it runs the identical _resolveRate path a
    ///         trade runs — same step band, walk band and monotonic checks — so a
    ///         poke is exactly as constrained as a trade and adds no attack surface.
    ///         On a STALE anchor it drives the two-phase revive below. Factory-
    ///         routed so the oracle address and epoch are always the canonical ones
    ///         (permissionless at the market entry point).
    ///
    /// TWO-PHASE REVIVE (decided 2026-07-30). A single observation must never revive
    /// a stale anchor: after a blind day the stored reference is unfit to judge one
    /// reading, and a momentary venue push could otherwise "return" the price to a
    /// day-old level and buy inventory at it (the manufactured-reversion attack).
    /// Instead the first poke records a PENDING reference and starts a public
    /// contest window. During the window, any poke reading OUTSIDE one (unwidened)
    /// band of the pending cancels it and becomes the new pending — so keeping a
    /// fake pending alive requires holding the venue at the fake price for the
    /// ENTIRE window against every observer in the world, not touching it for one
    /// block. A poke after the window that still reads within band of the pending
    /// activates the anchor at the FRESH reading, with the EMA restarted there
    /// (the blind period invalidates prior history). Trading stays declined
    /// throughout the contest. Admin resetAnchor remains the human override.
    /// Residual accepted: on a venue with zero organic flow, holding a price is
    /// free — but such a pool holds near-worthless inventory, and the slim oracle's
    /// minimum-depth rule (Phase 3) closes that corner at the source.
    function pokeAnchor(address asset, address oracle, uint32 epoch) external onlyFactory {
        if (poolPaused) revert PoolIsPaused();
        FlowstateStructs.Anchor storage a = anchors[asset];
        if (a.lastRate == 0) revert AnchorNotSeeded();

        // stale + same epoch ⇒ the revive path. (An epoch bump — timelocked oracle
        // migration — reseeds unconditionally in _resolveRate, staleness included:
        // the announced migration IS the human attestation.)
        if (
            epoch == a.lastRateEpoch && block.timestamp >= a.lastRateTime
                && block.timestamp - a.lastRateTime > MAX_ANCHOR_AGE
        ) {
            _reviveStep(a, asset, oracle);
            return;
        }

        uint256 rate = _resolveRate(asset, oracle, epoch);
        emit FlowstateEvents.AnchorPoked(address(this), asset, rate, a.emaRate);
    }

    /// @dev One step of the two-phase revive. Pending validity: pendingSince must
    ///      postdate lastRateTime — any accepted anchor write implicitly invalidates
    ///      leftovers from earlier stale episodes (see FlowstateStructs.Anchor).
    function _reviveStep(FlowstateStructs.Anchor storage a, address asset, address oracle) private {
        uint256 fresh = _readOracle(asset, oracle);

        bool pendingValid = a.pendingRate != 0 && a.pendingSince > a.lastRateTime;
        if (!pendingValid || !_withinBand(fresh, a.pendingRate, 0)) {
            // open a new contest (or cancel-and-replace a contradicted one)
            a.pendingRate = uint192(fresh);
            a.pendingSince = uint64(block.timestamp);
            emit FlowstateEvents.AnchorRevivePending(
                address(this), asset, fresh, uint64(block.timestamp)
            );
            return;
        }

        if (block.timestamp - a.pendingSince >= REVIVE_WINDOW) {
            // survived the full public contest — activate at the fresh reading
            _writeAnchor(a, asset, uint192(fresh), uint192(fresh), a.lastRateEpoch);
            emit FlowstateEvents.AnchorRevived(address(this), asset, fresh);
        }
        // in-window confirmation: deliberately a silent no-op — the pending
        // reference stays FIXED so it cannot be slow-walked during its own contest
    }

    // ────────────────────────────────────────────────────────────────────
    // Liquidity (factory has already moved the assets in)
    // ────────────────────────────────────────────────────────────────────

    /// @dev Pause policy (D-M2-1): a paused pool blocks trading AND new deposits (users
    ///      must not add value to a pool under incident investigation) but NEVER blocks
    ///      withdrawals — exits are pure position accounting, no pricing involved.
    function creditTokenContribution(address owner, uint256 actualAmount) external onlyFactory {
        if (poolPaused) revert PoolIsPaused();
        if (actualAmount == 0) revert InvalidAmount();
        if (actualAmount > type(uint128).max) revert AmountTooLarge();
        _addToList(tokenNodes, tokenIndex, owner, uint128(actualAmount), false);
        tokenBalance += actualAmount;
        isHidden = false;
    }

    /// @param amount pass 0 to withdraw the full position.
    /// @dev Deliberately callable while paused — never trap exits (D-M2-1).
    function withdrawTokensFor(address owner, uint256 amount)
        external
        onlyFactory
        returns (uint256 withdrawn, bool nowEmpty)
    {
        uint256 idx = tokenIndex[owner];
        if (idx == 0) revert NotAContributor();
        FlowstateStructs.Node storage node = tokenNodes[idx];
        uint256 position = node.amount;
        withdrawn = amount == 0 ? position : amount;
        if (withdrawn > position) revert InsufficientPosition();

        if (withdrawn == position) {
            _removeFromList(tokenNodes, tokenIndex, owner, false);
        } else {
            node.amount = uint128(position - withdrawn);
        }
        tokenBalance -= withdrawn;
        nowEmpty = tokenBalance == 0;
        if (nowEmpty) isHidden = true;
        IERC20(inventoryToken).safeTransfer(owner, withdrawn);
    }

    // ────────────────────────────────────────────────────────────────────
    // Trading — buy path (pull-exact, two onlyFactory steps in one tx)
    // ────────────────────────────────────────────────────────────────────

    /// @notice Step 1: band-checked oracle read for the NAMED asset + FIFO-capped
    ///         fillable amount + exact cost in that asset.
    /// @dev Cost is computed on the FILLABLE amount before anything is pulled, so an
    ///      over-pull/refund path never exists (deletes the stranded-payment bug class).
    ///      Practical bound (review F4): fillableAmount × rate must fit uint256; with
    ///      amounts ≤ 50 × uint128.max and real 1inch rates (≤ ~1e30) the product tops
    ///      out ~1e70 « 2^256. A pathological max-supply × max-rate pair Panic-reverts,
    ///      which is a liveness refusal, not an exploit.
    function priceBuy(address asset, uint256 requestedAmount, address oracle, uint32 epoch)
        external
        onlyFactory
        returns (uint256 fillableAmount, uint256 quoteCost, uint256 rate)
    {
        if (poolPaused) revert PoolIsPaused();
        if (tokenBalance == 0) revert NoLiquidity();
        if (requestedAmount == 0) revert InvalidAmount();

        rate = _resolveRate(asset, oracle, epoch);

        fillableAmount = _fillableBuy(requestedAmount);
        if (fillableAmount == 0) revert NoLiquidity();

        // round UP against the buyer
        quoteCost = (fillableAmount * rate + RATE_SCALE - 1) / RATE_SCALE;
        if (quoteCost == 0) revert AmountTooSmall();
    }

    /// @notice Exact-quote twin of priceBuy (V4 hook build scope §2.2, additive): the
    ///         caller names the quote spend in the NAMED asset; the pool inverts to a
    ///         token amount inside the SAME single band-checked oracle read — the view
    ///         quote path is never involved, so no second cold read can exist in the
    ///         transaction.
    /// @dev The inversion rounds DOWN against the buyer (mirror of priceBuy's round-up),
    ///      then quoteCost is recomputed exactly as priceBuy would price that token
    ///      amount, so settlement accounting is wei-identical to a buyFromPool of
    ///      fillableAmount. quoteCost ≤ quoteIn always (floor then ceil cannot
    ///      overshoot the integer input); any difference stays with the caller — the
    ///      factory never pulls more than the oracle cost of the tokens delivered.
    ///      All-or-nothing (scope decision, fill semantics v1): if FIFO capacity cannot
    ///      cover the full inverted amount, revert FillShortfall — a partial fill would
    ///      strand the caller's committed quote (V4 swap amounts are fixed once
    ///      specified). Practical bound mirrors priceBuy's F4 note: quoteIn ×
    ///      RATE_SCALE must fit uint256; a pathological quoteIn Panic-reverts, which is
    ///      a liveness refusal, not an exploit.
    function priceBuyExactQuote(address asset, uint256 quoteIn, address oracle, uint32 epoch)
        external
        onlyFactory
        returns (uint256 fillableAmount, uint256 quoteCost, uint256 rate)
    {
        if (poolPaused) revert PoolIsPaused();
        if (tokenBalance == 0) revert NoLiquidity();
        if (quoteIn == 0) revert InvalidAmount();

        rate = _resolveRate(asset, oracle, epoch);

        // invert inside the single read: round DOWN against the buyer
        uint256 desired = (quoteIn * RATE_SCALE) / rate;
        if (desired == 0) revert AmountTooSmall();

        fillableAmount = _fillableBuy(desired);
        if (fillableAmount == 0) revert NoLiquidity();

        // recompute the pull exactly as priceBuy would for this amount (round UP).
        // MUST price fillableAmount, never `desired` (JUP-559, mirrors contracts PR #31).
        quoteCost = (fillableAmount * rate + RATE_SCALE - 1) / RATE_SCALE;
    }

    /// @notice Step 2: factory has pulled `quotePaid` of `asset` to this pool; settle
    ///         ledgers, distribute fees, transfer tokens to the buyer. Contributor
    ///         credits and the fee split are denominated in `asset`.
    /// @dev Fee-on-transfer inventory tokens under-deliver on buys (review F-M2-2): the
    ///      buyer pays oracle price for fillAmount but receives fillAmount minus the
    ///      token's own fee. Pool accounting stays consistent; the shortfall is the
    ///      buyer's. FoT tokens are unsupported as inventory — caller/lister beware
    ///      (the sell path rejects them outright via TransferAmountMismatch).
    function settleBuy(
        address buyer,
        address asset,
        uint256 fillAmount,
        uint256 quotePaid,
        uint256 rate,
        FlowstateStructs.FeeContext calldata ctx
    ) external onlyFactory {
        uint256 fee = (quotePaid * ctx.feeBps) / BPS;
        uint256 quoteNet = quotePaid - fee;

        // consume FIFO nodes; contributors are credited pro-rata, the last-filled
        // node absorbs the rounding remainder so Σcredits == quoteNet exactly
        uint256 remaining = fillAmount;
        uint256 distributed;
        uint256 idx = tokenHead;
        while (remaining != 0) {
            FlowstateStructs.Node storage node = tokenNodes[idx];
            address contributor = node.addr;
            uint256 nodeAmount = node.amount;
            uint256 take = nodeAmount < remaining ? nodeAmount : remaining;
            remaining -= take;

            uint256 credit = remaining == 0 ? quoteNet - distributed : (quoteNet * take) / fillAmount;
            distributed += credit;
            // recycle (R12): an opted-in contributor's proceeds join the cash-side FIFO
            // as a contribution instead of claimableQuote — only while buy-back is live,
            // only when the traded asset IS the buy-back asset (the cash side is
            // single-asset), and only if the credit fits the uint128 node bound.
            bool recycled = recycleOptIn[contributor] && buyBackEnabled && asset == buybackAsset
                && credit <= type(uint128).max;
            if (recycled && credit != 0) {
                _addToList(cashNodes, cashIndex, contributor, uint128(credit), true);
                quoteBalance += credit;
                emit FlowstateEvents.ProceedsRecycled(address(this), contributor, credit);
            } else {
                recycled = false;
                claimableQuote[asset][contributor] += credit;
            }
            emit FlowstateEvents.ContributorFilled(
                address(this), contributor, asset, take, credit, recycled
            );

            if (take == nodeAmount) {
                uint256 nextIdx = node.next;
                _removeFromList(tokenNodes, tokenIndex, contributor, false);
                idx = nextIdx;
            } else {
                node.amount = uint128(nodeAmount - take);
            }
        }
        tokenBalance -= fillAmount;
        if (tokenBalance == 0) isHidden = true;

        _distributeFee(asset, fee, ctx);

        emit FlowstateEvents.PoolBuy(
            address(this), buyer, asset, fillAmount, quotePaid, rate, fee,
            tokenBalance == 0, ctx.resellerCode
        );

        IERC20(inventoryToken).safeTransfer(buyer, fillAmount);
    }

    // ────────────────────────────────────────────────────────────────────
    // Cash-side liquidity + sell path (buy-back mode — ships OFF, per-pool enable,
    // single designated asset)
    // ────────────────────────────────────────────────────────────────────

    /// @dev Same pause policy as creditTokenContribution (D-M2-1): deposits blocked,
    ///      withdrawals never. Denominated in buybackAsset (the factory pulled that).
    function creditQuoteContribution(address owner, uint256 actualAmount) external onlyFactory {
        if (poolPaused) revert PoolIsPaused();
        if (!buyBackEnabled) revert BuyBackDisabled();
        if (actualAmount == 0) revert InvalidAmount();
        if (actualAmount > type(uint128).max) revert AmountTooLarge();
        _addToList(cashNodes, cashIndex, owner, uint128(actualAmount), true);
        quoteBalance += actualAmount;
    }

    /// @param amount pass 0 to withdraw the full position.
    /// @dev Deliberately callable while paused — never trap exits (D-M2-1).
    function withdrawQuoteFor(address owner, uint256 amount)
        external
        onlyFactory
        returns (uint256 withdrawn, bool cashSideEmpty)
    {
        uint256 idx = cashIndex[owner];
        if (idx == 0) revert NotAContributor();
        FlowstateStructs.Node storage node = cashNodes[idx];
        uint256 position = node.amount;
        withdrawn = amount == 0 ? position : amount;
        if (withdrawn > position) revert InsufficientPosition();

        if (withdrawn == position) {
            _removeFromList(cashNodes, cashIndex, owner, true);
        } else {
            node.amount = uint128(position - withdrawn);
        }
        quoteBalance -= withdrawn;
        cashSideEmpty = quoteBalance == 0;
        // NOTE: isHidden deliberately untouched — it means "no token inventory for
        // buyers"; cash-side emptiness has its own signals (this flag + quoteBalance).
        IERC20(buybackAsset).safeTransfer(owner, withdrawn);
    }

    /// @notice Sell-path step 1: band-checked rate FOR THE BUY-BACK ASSET, buy-side
    ///         spread, window cap, and cash-FIFO capacity → fillable token amount +
    ///         gross quote payout in buybackAsset.
    /// @dev The pool buys at oracle − spread; quoteGross rounds DOWN against the
    ///      seller (mirror of priceBuy's round-up against the buyer).
    function priceSell(uint256 requestedAmount, address oracle, uint32 epoch)
        external
        onlyFactory
        returns (uint256 fillableAmount, uint256 quoteGross, uint256 rate)
    {
        if (poolPaused) revert PoolIsPaused();
        if (!buyBackEnabled) revert BuyBackDisabled();
        if (requestedAmount == 0) revert InvalidAmount();
        if (quoteBalance == 0) revert NoLiquidity();

        rate = _resolveRate(buybackAsset, oracle, epoch);
        uint256 rateNet = (rate * (BPS - buySpreadBps)) / BPS;
        if (rateNet == 0) revert AmountTooSmall();

        // roll the window over BEFORE reading capacity, so _capacitySell's as-if-rolled
        // view matches post-rollover state exactly (shared with previewSell)
        if (maxQuotePerWindow != 0 && block.timestamp >= uint256(windowStart) + windowSeconds) {
            windowStart = uint64(block.timestamp);
            quoteSpentInWindow = 0;
        }
        uint256 capacity = _capacitySell();
        if (capacity == 0) revert NoLiquidity();

        uint256 maxTokens = (capacity * RATE_SCALE) / rateNet;
        fillableAmount = requestedAmount < maxTokens ? requestedAmount : maxTokens;
        if (fillableAmount == 0) revert AmountTooSmall();
        quoteGross = (fillableAmount * rateNet) / RATE_SCALE;
        if (quoteGross == 0) revert AmountTooSmall();
    }

    /// @notice Sell-path step 2: factory has pulled exactly `fillAmount` inventory
    ///         tokens into the pool; consume cash FIFO, credit bought tokens to the
    ///         cash depositors, take the fee on the pool-payout leg, pay the seller
    ///         in buybackAsset.
    /// @return sellerNet quote paid to the seller (gross − fee).
    function settleSell(
        address seller,
        uint256 fillAmount,
        uint256 quoteGross,
        uint256 rate,
        FlowstateStructs.FeeContext calldata ctx
    ) external onlyFactory returns (uint256 sellerNet) {
        uint256 fee = (quoteGross * ctx.feeBps) / BPS;
        sellerNet = quoteGross - fee;
        address asset = buybackAsset;

        // consume cash FIFO by quote spent; credit tokens pro-rata, last node absorbs
        // the rounding remainder so Σcredits == fillAmount exactly
        uint256 remainingQuote = quoteGross;
        uint256 tokensDistributed;
        uint256 idx = cashHead;
        while (remainingQuote != 0) {
            FlowstateStructs.Node storage node = cashNodes[idx];
            address owner = node.addr;
            uint256 nodeAmount = node.amount;
            uint256 take = nodeAmount < remainingQuote ? nodeAmount : remainingQuote;
            remainingQuote -= take;

            uint256 tokensCredit =
                remainingQuote == 0 ? fillAmount - tokensDistributed : (fillAmount * take) / quoteGross;
            tokensDistributed += tokensCredit;
            claimableTokens[owner] += tokensCredit;
            emit FlowstateEvents.ContributorFilled(
                address(this), owner, asset, tokensCredit, take, false
            );

            if (take == nodeAmount) {
                uint256 nextIdx = node.next;
                _removeFromList(cashNodes, cashIndex, owner, true);
                idx = nextIdx;
            } else {
                node.amount = uint128(nodeAmount - take);
            }
        }
        quoteBalance -= quoteGross;
        if (maxQuotePerWindow != 0) {
            // structural guard (review F-M2-1): the capacity math in priceSell bounds
            // quoteGross ≤ maxQuotePerWindow ≤ uint128.max, but enforce it at the cast
            // so a future refactor of that math cannot silently truncate window spend
            if (quoteGross > type(uint128).max) revert AmountTooLarge();
            quoteSpentInWindow += uint128(quoteGross);
        }

        _distributeFee(asset, fee, ctx);

        emit FlowstateEvents.PoolSell(
            address(this), seller, asset, fillAmount, quoteGross, rate, fee,
            quoteBalance == 0, ctx.resellerCode
        );

        // seller payout is a hard transfer (no fallback credit): the seller is trading
        // for payment, not receiving a fee — a refusing/blocklisted seller should
        // revert the trade rather than strand value in a ledger they can't claim from
        IERC20(asset).safeTransfer(seller, sellerNet);
    }

    // ────────────────────────────────────────────────────────────────────
    // Claims (pool-local ledgers — plan D2). Silent no-op on zero so the
    // factory's claimMany can iterate without reverting on empty pools.
    // claimQuote sweeps EVERY seeded asset — depositors are asset-blind, so
    // they must never need to know which assets their fills arrived in.
    // ────────────────────────────────────────────────────────────────────

    function claimQuote() external nonReentrant {
        _claimQuote(msg.sender);
    }

    function claimQuoteFor(address user) external onlyFactory {
        _claimQuote(user);
    }

    function claimTokens() external nonReentrant {
        _claimTokens(msg.sender);
    }

    function claimTokensFor(address user) external onlyFactory {
        _claimTokens(user);
    }

    /// @notice Opt this depositor's future buy-fill proceeds into the cash side (R12).
    function setRecycleOptIn(bool optIn) external {
        recycleOptIn[msg.sender] = optIn;
        emit FlowstateEvents.RecycleOptInSet(address(this), msg.sender, optIn);
    }

    /// @dev Loop bound: seededAssetList only grows via factory seeding, and the
    ///      approved-asset set is small by policy (2-4 per chain), so this sweep is
    ///      a handful of iterations, most of them zero-balance skips.
    function _claimQuote(address user) private {
        uint256 length = seededAssetList.length;
        for (uint256 i = 0; i < length; ++i) {
            address asset = seededAssetList[i];
            uint256 amount = claimableQuote[asset][user];
            if (amount == 0) continue;
            claimableQuote[asset][user] = 0;
            IERC20(asset).safeTransfer(user, amount);
            emit FlowstateEvents.ProceedsClaimed(address(this), user, asset, amount);
        }
    }

    function _claimTokens(address user) private {
        uint256 amount = claimableTokens[user];
        if (amount == 0) return;
        claimableTokens[user] = 0;
        IERC20(inventoryToken).safeTransfer(user, amount);
        emit FlowstateEvents.ProceedsClaimed(address(this), user, inventoryToken, amount);
    }

    // ────────────────────────────────────────────────────────────────────
    // Config (factory-only; role/timelock gating lives in the factory — §3.7)
    // ────────────────────────────────────────────────────────────────────

    function setAnchorBand(uint16 bandBps) external onlyFactory {
        if (bandBps < MIN_BAND_BPS || bandBps > MAX_BAND_BPS) revert InvalidBand();
        anchorBandBps = bandBps;
    }

    function setPaused(bool paused) external onlyFactory {
        poolPaused = paused;
    }

    /// @notice PARKED (plan §2 fix 2): the per-pool price source is a reserved slot; in
    ///         pass 1 only 0 (AGGREGATOR) is valid. Unparking = beacon upgrade + this
    ///         setter accepting new values — no storage migration.
    function setPriceSource(uint8 source) external onlyFactory {
        if (source != 0) revert InvalidPriceSource();
        priceSource = source;
    }

    /// @dev Window semantics: cap and window are configured together (both zero =
    ///      uncapped, both nonzero = capped); the window counter resets on config.
    ///      Multi-asset rules: enabling requires a SEEDED asset (sells price off its
    ///      anchor); changing the asset while the cash side holds funds is refused —
    ///      quoteBalance and the cash FIFO are denominated in the old asset, so a
    ///      silent switch would misdenominate every position.
    function setBuyBack(
        address asset,
        bool enabled,
        uint16 spreadBps,
        uint128 maxPerWindow,
        uint32 windowSecs
    ) external onlyFactory {
        if (spreadBps > MAX_SPREAD_BPS) revert SpreadTooHigh();
        if ((maxPerWindow == 0) != (windowSecs == 0)) revert InvalidWindowConfig();
        if (enabled) {
            if (asset == address(0)) revert BuybackAssetUnset();
            if (anchors[asset].lastRate == 0) revert AnchorNotSeeded();
        }
        if (asset != buybackAsset && quoteBalance != 0) revert CashSideNotEmpty();
        buybackAsset = asset;
        buyBackEnabled = enabled;
        buySpreadBps = spreadBps;
        maxQuotePerWindow = maxPerWindow;
        windowSeconds = windowSecs;
        if (maxPerWindow != 0) {
            windowStart = uint64(block.timestamp);
            quoteSpentInWindow = 0;
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // Views
    // ────────────────────────────────────────────────────────────────────

    /// @notice View twin of priceBuy — the quoter backend (§3.1). Never reverts.
    /// @dev Consistency invariant: same block + same args ⇒ (fillable, cost) here
    ///      equals what buyFromPool executes, because rate resolution, the FIFO walk,
    ///      and the rounding are the same shared code paths.
    function previewBuy(address asset, uint256 amount, address oracle, uint32 epoch)
        external
        view
        returns (bool ok, uint256 fillable, uint256 cost)
    {
        if (poolPaused || tokenBalance == 0 || amount == 0) return (false, 0, 0);
        (bool rateOk, uint256 rate) = _peekRate(asset, oracle, epoch);
        if (!rateOk) return (false, 0, 0);
        fillable = _fillableBuy(amount);
        if (fillable == 0) return (false, 0, 0);
        cost = (fillable * rate + RATE_SCALE - 1) / RATE_SCALE;
        if (cost == 0) return (false, 0, 0);
        ok = true;
    }

    /// @notice View twin of priceSell. Never reverts. Returns GROSS proceeds (the
    ///        factory-level quoter subtracts the fee for the seller-visible number).
    function previewSell(uint256 amount, address oracle, uint32 epoch)
        external
        view
        returns (bool ok, uint256 fillable, uint256 grossProceeds)
    {
        if (poolPaused || !buyBackEnabled || quoteBalance == 0 || amount == 0) return (false, 0, 0);
        (bool rateOk, uint256 rate) = _peekRate(buybackAsset, oracle, epoch);
        if (!rateOk) return (false, 0, 0);
        uint256 rateNet = (rate * (BPS - buySpreadBps)) / BPS;
        if (rateNet == 0) return (false, 0, 0);
        uint256 capacity = _capacitySell();
        if (capacity == 0) return (false, 0, 0);
        uint256 maxTokens = (capacity * RATE_SCALE) / rateNet;
        fillable = amount < maxTokens ? amount : maxTokens;
        if (fillable == 0) return (false, 0, 0);
        grossProceeds = (fillable * rateNet) / RATE_SCALE;
        if (grossProceeds == 0) return (false, 0, 0);
        ok = true;
    }

    function anchorOf(address asset)
        external
        view
        returns (uint192 rate, uint64 time, uint192 ema, uint32 epoch)
    {
        FlowstateStructs.Anchor storage a = anchors[asset];
        return (a.lastRate, a.lastRateTime, a.emaRate, a.lastRateEpoch);
    }

    /// @notice Two-phase revive state for a stale anchor (keeper telemetry).
    ///         `valid` is false when the stored pending is a leftover from an
    ///         earlier stale episode.
    function pendingReviveOf(address asset)
        external
        view
        returns (uint192 rate, uint64 since, bool valid)
    {
        FlowstateStructs.Anchor storage a = anchors[asset];
        return (a.pendingRate, a.pendingSince, a.pendingRate != 0 && a.pendingSince > a.lastRateTime);
    }

    function seededAssets() external view returns (address[] memory) {
        return seededAssetList;
    }

    function positions(address user)
        external
        view
        returns (uint256 tokenPosition, uint256 cashPosition, uint256 claimT)
    {
        uint256 tIdx = tokenIndex[user];
        if (tIdx != 0) tokenPosition = tokenNodes[tIdx].amount;
        uint256 cIdx = cashIndex[user];
        if (cIdx != 0) cashPosition = cashNodes[cIdx].amount;
        claimT = claimableTokens[user];
    }

    /// @notice Per-asset claimable quote for a user, aligned arrays. The depositor-
    ///         facing "what will claimQuote() send me" view.
    function claimableQuoteOf(address user)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        uint256 length = seededAssetList.length;
        assets = new address[](length);
        amounts = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            assets[i] = seededAssetList[i];
            amounts[i] = claimableQuote[assets[i]][user];
        }
    }

    function getPlaceInLine(address user, bool cashSide) external view returns (uint256) {
        FlowstateStructs.Node[] storage nodes = cashSide ? cashNodes : tokenNodes;
        mapping(address => uint256) storage index = cashSide ? cashIndex : tokenIndex;
        uint64 head = cashSide ? cashHead : tokenHead;
        if (index[user] == 0) revert NotAContributor();
        uint256 pos;
        uint256 idx = head;
        while (idx != 0) {
            if (nodes[idx].addr == user) return pos;
            idx = nodes[idx].next;
            unchecked {
                ++pos;
            }
        }
        return type(uint256).max; // unreachable: index[user] != 0 implies membership
    }

    // ────────────────────────────────────────────────────────────────────
    // Internals
    // ────────────────────────────────────────────────────────────────────

    /// @dev Rate resolution — normative logic from plan §3.2 plus the §3.4 hardening:
    ///      1. unseeded asset → decline (seeding is factory-gated, never lazy);
    ///      2. new factory epoch → reseed band-check-free (timelock-announced event);
    ///      3. monotonic guard (item 3) — the anchor timestamp never moves backwards;
    ///      4. same timestamp → cached rate, no oracle call;
    ///      5. freshness bound (item 1) — an anchor older than MAX_ANCHOR_AGE
    ///         declines instead of trusting the fully-widened band;
    ///      6. fresh read → step band vs last accepted rate (widened by elapsed)
    ///         AND walk band vs the EMA (item 4), then update both.
    function _resolveRate(address asset, address oracle, uint32 epoch) private returns (uint256) {
        FlowstateStructs.Anchor storage a = anchors[asset];
        if (a.lastRate == 0) revert AnchorNotSeeded();

        if (epoch != a.lastRateEpoch) {
            uint256 reseeded = _readOracle(asset, oracle);
            _writeAnchor(a, asset, uint192(reseeded), uint192(reseeded), epoch);
            emit FlowstateEvents.AnchorReseeded(address(this), asset, reseeded, epoch);
            return reseeded;
        }

        if (block.timestamp < a.lastRateTime) revert StaleAnchor(); // monotonic (item 3)

        if (block.timestamp == a.lastRateTime) {
            return a.lastRate; // same-timestamp cache: no oracle call, no new information
        }

        uint256 elapsed = block.timestamp - a.lastRateTime;
        if (elapsed > MAX_ANCHOR_AGE) revert StaleAnchor(); // freshness bound (item 1)

        uint256 fresh = _readOracle(asset, oracle);
        if (!_withinBand(fresh, a.lastRate, elapsed)) revert RateOutOfBand();

        uint256 newEma = _advanceEma(a.emaRate, a.lastRate, elapsed);
        if (!_withinWalkBand(fresh, newEma)) revert AnchorWalkExceeded();

        _writeAnchor(a, asset, uint192(fresh), uint192(newEma), epoch);
        return fresh;
    }

    /// @dev Band predicate shared by _resolveRate (execution) and _peekRate (preview) —
    ///      single source of truth so quoter and execution cannot drift.
    function _withinBand(uint256 fresh, uint256 anchorRef, uint256 elapsed) private view returns (bool) {
        uint256 widen = 1 + elapsed / WIDEN_PERIOD;
        if (widen > MAX_WIDEN) widen = MAX_WIDEN;
        uint256 allowedBps = uint256(anchorBandBps) * widen;
        uint256 diff = fresh > anchorRef ? fresh - anchorRef : anchorRef - fresh;
        return diff * BPS <= anchorRef * allowedBps;
    }

    /// @dev Walk band (item 4): the fresh rate must sit near the SLOW anchor. No time
    ///      widening here — widening the walk band with idle time would hand back
    ///      exactly the cumulative headroom the EMA exists to remove.
    function _withinWalkBand(uint256 fresh, uint256 ema) private view returns (bool) {
        uint256 allowedBps = uint256(anchorBandBps) * WALK_BAND_MULT;
        uint256 diff = fresh > ema ? fresh - ema : ema - fresh;
        return diff * BPS <= ema * allowedBps;
    }

    /// @dev Linear-in-elapsed EMA step toward the last ACCEPTED rate (not toward the
    ///      incoming read — the EMA only ever ingests observations that passed the
    ///      bands, so a rejected read never drags the reference). elapsed ≥ tau ⇒ the
    ///      EMA lands exactly on the last accepted rate.
    function _advanceEma(uint256 ema, uint256 lastAccepted, uint256 elapsed)
        private
        pure
        returns (uint256)
    {
        uint256 step = elapsed >= ANCHOR_TAU ? ANCHOR_TAU : elapsed;
        if (lastAccepted >= ema) {
            return ema + ((lastAccepted - ema) * step) / ANCHOR_TAU;
        }
        return ema - ((ema - lastAccepted) * step) / ANCHOR_TAU;
    }

    /// @dev Single writer for anchor state so no code path can update the pair
    ///      half-way. Values are pre-validated by callers (≤ uint192.max via
    ///      _readOracle bounds or seed checks).
    function _writeAnchor(
        FlowstateStructs.Anchor storage a,
        address, /* asset — kept for call-site readability */
        uint192 rate,
        uint192 ema,
        uint32 epoch
    ) private {
        a.lastRate = rate;
        a.lastRateTime = uint64(block.timestamp);
        a.emaRate = ema;
        a.lastRateEpoch = epoch;
    }

    /// @dev View twin of _resolveRate: identical rate resolution, no state writes, no
    ///      reverts (oracle failures return ok=false).
    function _peekRate(address asset, address oracle, uint32 epoch)
        private
        view
        returns (bool ok, uint256 rate)
    {
        FlowstateStructs.Anchor storage a = anchors[asset];
        if (a.lastRate == 0) return (false, 0);

        if (epoch == a.lastRateEpoch && block.timestamp == a.lastRateTime) {
            return (true, a.lastRate); // cache hit — execution would not call the oracle either
        }
        uint256 fresh;
        try IOracle(oracle).getRate(IERC20(inventoryToken), IERC20(asset), false) returns (uint256 r) {
            fresh = r;
        } catch {
            return (false, 0);
        }
        if (fresh == 0 || fresh > type(uint192).max) return (false, 0);
        if (epoch != a.lastRateEpoch) return (true, fresh); // execution would reseed band-check-free

        if (block.timestamp < a.lastRateTime) return (false, 0); // monotonic (item 3)
        uint256 elapsed = block.timestamp - a.lastRateTime;
        if (elapsed > MAX_ANCHOR_AGE) return (false, 0); // freshness bound (item 1)
        if (!_withinBand(fresh, a.lastRate, elapsed)) return (false, 0);
        if (!_withinWalkBand(fresh, _advanceEma(a.emaRate, a.lastRate, elapsed))) return (false, 0);
        return (true, fresh);
    }

    /// @dev FIFO fillable walk shared by priceBuy and previewBuy.
    function _fillableBuy(uint256 requested) private view returns (uint256 fillable) {
        uint256 remaining = requested;
        uint256 idx = tokenHead;
        uint256 visited;
        while (idx != 0 && remaining != 0 && visited < MAX_FILL_NODES) {
            uint256 nodeAmount = tokenNodes[idx].amount;
            uint256 take = nodeAmount < remaining ? nodeAmount : remaining;
            fillable += take;
            remaining -= take;
            idx = tokenNodes[idx].next;
            unchecked {
                ++visited;
            }
        }
    }

    /// @dev Sell capacity in quote units: pool funds ∩ window remaining (as-if-rolled)
    ///      ∩ first MAX_FILL_NODES cash nodes. Shared by priceSell (which performs the
    ///      actual rollover first) and previewSell.
    function _capacitySell() private view returns (uint256 capacity) {
        capacity = quoteBalance;
        if (maxQuotePerWindow != 0) {
            uint256 spent =
                block.timestamp >= uint256(windowStart) + windowSeconds ? 0 : quoteSpentInWindow;
            uint256 windowRemaining = uint256(maxQuotePerWindow) - spent;
            if (windowRemaining < capacity) capacity = windowRemaining;
        }
        uint256 nodeCapacity;
        uint256 idx = cashHead;
        uint256 visited;
        while (idx != 0 && visited < MAX_FILL_NODES && nodeCapacity < capacity) {
            nodeCapacity += cashNodes[idx].amount;
            idx = cashNodes[idx].next;
            unchecked {
                ++visited;
            }
        }
        if (nodeCapacity < capacity) capacity = nodeCapacity;
    }

    function _readOracle(address asset, address oracle) private view returns (uint256 rate) {
        rate = IOracle(oracle).getRate(IERC20(inventoryToken), IERC20(asset), false);
        if (rate == 0 || rate > type(uint192).max) revert NoOracleRate();
    }

    /// @dev Fee split shared by settleBuy and settleSell, denominated in the traded
    ///      asset: fractions of the fee (3000/3000/4000 model); buyback takes the
    ///      remainder, which also absorbs rounding dust — never less than its 4000.
    function _distributeFee(address asset, uint256 fee, FlowstateStructs.FeeContext calldata ctx)
        private
    {
        uint256 resellerCut = (fee * ctx.resellerShareBps) / BPS;
        uint256 bd1Cut = (fee * ctx.bd1ShareBps) / BPS;
        uint256 bd2Cut = (fee * ctx.bd2ShareBps) / BPS;
        uint256 buybackCut = fee - resellerCut - bd1Cut - bd2Cut;

        _pushQuote(asset, ctx.resellerWallet, resellerCut);
        _pushQuote(asset, ctx.bd1, bd1Cut);
        _pushQuote(asset, ctx.bd2, bd2Cut);
        _pushQuote(asset, ctx.buybackReceiver, buybackCut);
        emit FlowstateEvents.FeeDistributed(
            address(this), asset, ctx.resellerCode, resellerCut, bd1Cut, bd2Cut, buybackCut
        );
    }

    /// @dev Fee push with fallback credit: a receiver the quote asset refuses (e.g. a
    ///      USDC-blocklisted wallet) is credited on the pool ledger instead of
    ///      reverting the trade (audit "reverting fee receiver" fix, ERC20 edition).
    ///      The return-data check is STRICT (empty or exactly 32 bytes decoding true) —
    ///      any odd-shaped return counts as failure and takes the credit fallback,
    ///      never a revert (review F1: abi.decode on 1–31 bytes would panic and turn
    ///      the fallback into a trade-reverting griefing surface). The fallback credit
    ///      lands on the SAME asset's claim ledger the push attempted.
    function _pushQuote(address asset, address receiver, uint256 amount) private {
        if (amount == 0 || receiver == address(0)) return;
        (bool ok, bytes memory ret) = asset.call(abi.encodeCall(IERC20.transfer, (receiver, amount)));
        if (ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))))) return;
        claimableQuote[asset][receiver] += amount;
        emit FlowstateEvents.FeePushFailed(address(this), receiver, asset, amount);
    }

    function _addToList(
        FlowstateStructs.Node[] storage nodes,
        mapping(address => uint256) storage index,
        address owner,
        uint128 amount,
        bool cashSide
    ) private {
        uint256 existing = index[owner];
        if (existing != 0) {
            uint256 newAmount = uint256(nodes[existing].amount) + amount;
            if (newAmount > type(uint128).max) revert AmountTooLarge();
            nodes[existing].amount = uint128(newAmount);
            return;
        }
        uint64 tail = cashSide ? cashTail : tokenTail;
        nodes.push(FlowstateStructs.Node(owner, 0, amount, tail));
        uint64 newIndex = uint64(nodes.length - 1);
        nodes[tail].next = newIndex;
        index[owner] = newIndex;
        if (cashSide) {
            cashTail = newIndex;
            if (cashHead == 0) cashHead = newIndex;
        } else {
            tokenTail = newIndex;
            if (tokenHead == 0) tokenHead = newIndex;
        }
    }

    function _removeFromList(
        FlowstateStructs.Node[] storage nodes,
        mapping(address => uint256) storage index,
        address owner,
        bool cashSide
    ) private {
        uint256 idx = index[owner];
        if (idx == 0) return;
        uint64 prevIdx = nodes[idx].prev;
        uint64 nextIdx = nodes[idx].next;
        nodes[prevIdx].next = nextIdx;
        if (nextIdx != 0) nodes[nextIdx].prev = prevIdx;
        if (cashSide) {
            if (idx == cashHead) cashHead = nextIdx;
            if (idx == cashTail) cashTail = prevIdx;
        } else {
            if (idx == tokenHead) tokenHead = nextIdx;
            if (idx == tokenTail) tokenTail = prevIdx;
        }
        delete index[owner];
        delete nodes[idx];
    }
}
