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
 * ANCHOR MODEL (REDESIGNED 2026-08-11 — supersedes the EMA walk band, the 24h
 * freshness bound and the two-phase stale revive; see the incident note below).
 * One anchor per quote asset, since token/USDC and token/WETH are different rates.
 * Each anchor stores the last ACCEPTED rate and the BLOCK it was accepted in.
 *
 * TWO RULES, AND ONLY TWO.
 *
 *   1. ONE-BLOCK CONFIRMATION (the anti-flash-loan guard, the only manipulation
 *      defence this contract makes). The anchor advances at most once per block.
 *      A read within anchorBandBps of the anchor is accepted immediately (a move
 *      too small to be worth manipulating). A read OUTSIDE that band is not
 *      believed on sight: it is recorded as a candidate and only becomes the
 *      anchor when the SAME displaced level is still there in a STRICTLY LATER
 *      block. A flash loan borrows, displaces the venue, trades and repays inside
 *      ONE transaction in ONE block, so it can never satisfy that test — the
 *      attacker moves a venue and pays fees for nothing. Anything that survives
 *      into the next block required real capital held across blocks, exposed to
 *      every arbitrageur on the chain; that residual is accepted deliberately
 *      (decision 2026-08-11), because defending it costs availability and the
 *      extraction is capped by pool inventory anyway.
 *
 *      Measured in BLOCKS, not seconds, on purpose: Robinhood Chain produces ~10
 *      blocks per second and stamps all of them with the SAME whole-second
 *      timestamp, so a seconds-based rule cannot resolve a single block there. A
 *      block count is also self-adjusting across chains — no per-chain table.
 *
 *   2. CLAMP, NEVER DECLINE. When the fresh read and the anchor disagree, the
 *      pool prices on whichever of the two is worse for the party trading against
 *      depositors, and quotes anyway: buys take max(anchor, fresh), sells take
 *      min(anchor, fresh). A manipulated-down read therefore cannot buy inventory
 *      cheap (the buy prices off the anchor) and a manipulated-up read cannot sell
 *      into the cash side dear — while an honest counterparty on the other side of
 *      the same move still gets a live, fillable quote. Nothing about ordinary
 *      market conditions can make the buy path revert: no staleness bound, no
 *      out-of-band revert, and an unreadable oracle clamps to the anchor rather
 *      than declining. (The sell/buy-back path still requires a readable oracle,
 *      since it spends pool cash and no router-inclusion argument applies to it.)
 *
 * WHY (incident, 2026-08-09/10). The previous model REVERTED whenever a read fell
 * outside the bands. CASHCAT moved ~10% down then ~26% up against aeWETH with no
 * accepted read in between; the EMA could not advance, so the anchor wedged and the
 * live pool declined every quote and every simulation for the full 24h staleness
 * bound. Router-facing availability across that period measured ~14%. Aggregators
 * health-check sources by simulating them, and a source that reverts is dropped:
 * 0x filled this pool 7 times on 6 Aug, then routed thousands of CASHCAT buys past
 * it while it reverted. Protecting depositors from ordinary volatility was never
 * worth that, and was never the depositors' expectation either — the protocol takes
 * no view on how volatile an inventory token is. The guard now defends the one
 * thing a venue genuinely cannot survive (an atomic, capital-free drain) and gets
 * out of the way of everything else.
 *
 * Seeding is band-check-free BY DEFINITION (there is nothing to check against), so
 * whoever picks the seeding moment picks the price. Therefore seeding is factory-
 * gated only: createPool (the depositor picks the moment) and the admin resetAnchor
 * lane (instant multisig). There is NO permissionless lazy seeding on the trade
 * path. An unseeded asset simply declines.
 *
 * ORACLE MIGRATION (corrected 2026-08-13). An oracle-address migration at the
 * factory bumps its epoch, and a pool seeing a new epoch RECORDS it as a marker
 * only. It does NOT reseed band-check-free. The earlier rationale — that the
 * timelocked announcement was itself the human attestation — was wrong: the
 * announcement attests to the new oracle's IDENTITY, never to a price read at a
 * block a third party chooses, and the party who chooses is whoever trades first
 * after the migration. The migrated oracle's first read therefore earns adoption
 * under the ordinary band and one-block-confirmation rules like any other read.
 */
/// @dev Minimal surface of the ArbSys precompile (address 0x64 on every
///      Arbitrum-family chain, Orbit included).
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

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
    error AnchorNotSeeded();
    error AnchorAlreadySeeded();
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
    uint256 private constant MAX_FILL_NODES = 50; // deterministic partial-fill cap
    uint16 private constant MIN_BAND_BPS = 100;
    uint16 private constant MAX_BAND_BPS = 5000;
    uint16 private constant MAX_SPREAD_BPS = 1000; // buy-side spread ceiling: 10%
    // Anchor: a displaced read must still be there this many blocks later before it
    // is believed. ONE is the whole design — it is exactly the width of a flash loan
    // (single transaction, single block) and nothing more. Raising it would buy
    // protection against capital-committed multi-block manipulation, which we have
    // deliberately chosen not to defend (2026-08-11).
    uint64 private constant CONFIRM_BLOCKS = 1;
    // ── the block counter itself ─────────────────────────────────────────
    // On Arbitrum-family chains the EVM's block.number opcode returns the
    // PARENT chain's height, not the L2's (measured on Robinhood 2026-08-12:
    // opcode 25,737,724 = Ethereum, ~12s blocks, vs true L2 height 34,384,484
    // at ~100ms). Every anchor rule here is denominated in L2 blocks — one
    // block IS the width of a flash loan — so on such chains the counter must
    // come from ArbSys(0x64).arbBlockNumber(). Chosen per chain when the
    // implementation is deployed; beacon clones inherit it from the
    // implementation's code, and _currentBlock() is the ONLY reader either
    // way, so the two clocks can never mix.
    IArbSys private constant ARB_SYS = IArbSys(address(100));
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bool private immutable USE_ARB_SYS;
    // Staleness surcharge (JUP-529). While the oracle CANNOT be read, the buy side
    // clamps to the last accepted anchor — and without this, it would sell at that
    // frozen price forever if the market ran up during the outage. So while (and
    // only while) the read fails, the buy quote worsens by 1bp per this many blocks
    // since the last accepted read: the frozen price decays into an unattractive one
    // instead of a standing offer. Purely a function of _currentBlock() and existing
    // anchor state — no keeper, no admin, no pause, no new storage — and the first
    // successful read makes it vanish. Ramp chosen (not measured): at RH's ~100ms
    // L2 blocks, 100 blocks/bp ≈ 6bp/min ≈ 360bp/h, which outruns the measured
    // CASHCAT drift profile (60s moves: p99 0.93%) within the hour. Slower chains
    // get fewer bp/hour from the same constant — tune per chain AT DEPLOY, never
    // via an admin setter (a per-pool intervention lever is the shape we refuse).
    uint256 private constant STALE_RAMP_BLOCKS_PER_BP = 100;
    // Past +20% the quote is decorative; stop worsening there (matches the oracle's
    // SANITY_BPS scale). The pool stays available the whole time — routers keep
    // simulating a fillable, just increasingly unattractive, quote.
    uint256 private constant STALE_SURCHARGE_CAP_BPS = 2000;

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
    constructor(bool useArbSys_) {
        USE_ARB_SYS = useArbSys_;
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
        _writeAnchor(a, asset, seedRate, seedEpoch);
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
        _writeAnchor(a, asset, uint192(fresh), epoch);
        emit FlowstateEvents.AnchorReseeded(address(this), asset, fresh, epoch);
    }

    /// @notice Trade-less anchor advance, running the IDENTICAL maintenance a trade
    ///         runs (same band, same one-block confirmation), so a poke is exactly
    ///         as constrained as a trade and adds no attack surface. Factory-routed
    ///         so the oracle address and epoch are always the canonical ones
    ///         (permissionless at the market entry point).
    /// @dev No longer load-bearing. Under the pre-2026-08-11 model an unpoked pool
    ///      went stale and stopped trading, so a keeper process was mandatory; the
    ///      anchor now re-converges on its own within one block of the next trade,
    ///      and an idle pool never declines. Kept because a poke lets an idle pool
    ///      pre-converge (a large first trade after a long quiet period prices one
    ///      block sooner) and because it is the cheapest on-chain probe of anchor
    ///      health. Nothing breaks if nobody ever calls it.
    function pokeAnchor(address asset, address oracle, uint32 epoch) external onlyFactory {
        if (poolPaused) revert PoolIsPaused();
        FlowstateStructs.Anchor storage a = anchors[asset];
        if (a.lastRate == 0) revert AnchorNotSeeded();
        // preferHigh is irrelevant here: a poke prices nothing, it only advances the
        // anchor. Report the ACCEPTED anchor, not the clamped trade rate.
        bool freshOk;
        (, freshOk) = _resolveRate(asset, oracle, epoch, true); // maintenance only
        if (!freshOk) revert NoOracleRate();
        emit FlowstateEvents.AnchorPoked(address(this), asset, a.lastRate, a.lastRate);
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

        // buys price on the HIGHER side; _resolveRate also applies the staleness
        // surcharge whenever that price comes from the anchor rather than a live read
        (rate,) = _resolveRate(asset, oracle, epoch, true);

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
    ///      PARTIAL FILL (fill semantics v2, JUP-559): if FIFO capacity cannot cover the
    ///      full inverted amount, fill what capacity allows and price exactly that.
    ///      `fillableAmount` may be < the inverted `desired`, and `quoteCost` is then the
    ///      cost of `fillableAmount`, NOT of `desired`. Only a genuinely empty walk is
    ///      refused, mirroring priceBuy's NoLiquidity.
    ///
    ///      CALLER OBLIGATION: `quoteCost` is the ONLY amount the caller may charge its
    ///      own counterparty for this leg. A caller that charges the full `quoteIn` while
    ///      the factory pulled a short `quoteCost` would silently appropriate the
    ///      difference. The V4 hook discharges this by offsetting the whole specified
    ///      amount (so no residual reaches the core AMM) and returning the remainder to
    ///      the swap caller with PoolManager.settleFor.
    ///
    ///      Semantics v1 was all-or-nothing on the stated grounds that a partial fill
    ///      "would strand the caller's committed quote (V4 swap amounts are fixed once
    ///      specified)". That premise is false: v4-core's swap loop exits at the price
    ///      limit and builds its delta from `amountSpecified - amountSpecifiedRemaining`,
    ///      so input a swap does not consume is never charged. The real hazard was
    ///      different: a PARTIAL BeforeSwapDelta leaves a residual that walks the pool
    ///      price to the router's limit and PARKS it there, and because the hook refuses
    ///      the sell direction nothing can move it back, so one such fill bricks the V4
    ///      pool. Measured, with the fix, in the hook repo:
    ///      test/fork/PartialFillFallthrough.t.sol shows the parking, and
    ///      test/fork/UniversalRouterPartialFill.t.sol shows that under the full-offset
    ///      design the pool price is byte-identical across a short fill.
    ///
    ///      Practical bound mirrors priceBuy's F4 note: quoteIn ×
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

        // buys price on the HIGHER side; _resolveRate also applies the staleness
        // surcharge whenever that price comes from the anchor rather than a live read
        (rate,) = _resolveRate(asset, oracle, epoch, true);

        // invert inside the single read: round DOWN against the buyer
        uint256 desired = (quoteIn * RATE_SCALE) / rate;
        if (desired == 0) revert AmountTooSmall();

        fillableAmount = _fillableBuy(desired);
        if (fillableAmount == 0) revert NoLiquidity();

        // recompute the pull exactly as priceBuy would for this amount (round UP).
        // MUST price fillableAmount, never `desired`: on a short fill the two differ,
        // and pricing `desired` would pull the full ask for a partial delivery.
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

        bool freshOk;
        (rate, freshOk) = _resolveRate(buybackAsset, oracle, epoch, false); // sells price LOWER
        // the buy-back leg spends depositor cash, so unlike the buy path it will not
        // trade on a clamped anchor when the oracle cannot be read at all
        if (!freshOk) revert NoOracleRate();
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

    /// @notice Claim ONE asset's accrued proceeds. The full sweep above is
    ///         all-or-nothing across assets (asset-blind depositors), which
    ///         lets a single refusing asset — a USDC-style blocklist freezing
    ///         the claimant — hold every OTHER asset's proceeds hostage until
    ///         an upgrade. This lane isolates the failure per asset (JUP-543).
    function claimQuoteAsset(address asset) external nonReentrant {
        _claimQuoteAsset(msg.sender, asset);
    }

    /// @notice Per-asset claim pushed to the ENTITLED account, callable by
    ///         anyone. Deliberately permissionless (the pokeAnchor shape):
    ///         funds only ever move to `user`, and a recipient with no claim
    ///         code of its own — the fee-credit fallback can land credits on
    ///         contracts like the buyback — must not need us, or an upgrade,
    ///         to be paid out.
    function claimQuoteAssetFor(address user, address asset) external nonReentrant {
        _claimQuoteAsset(user, asset);
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
            _claimQuoteAsset(user, seededAssetList[i]);
        }
    }

    /// @dev The single-asset unit both claim lanes share. Zero claimable
    ///      (including an asset this pool never seeded) is a quiet no-op, per
    ///      the section header's claimMany contract.
    function _claimQuoteAsset(address user, address asset) private {
        uint256 amount = claimableQuote[asset][user];
        if (amount == 0) return;
        claimableQuote[asset][user] = 0;
        IERC20(asset).safeTransfer(user, amount);
        emit FlowstateEvents.ProceedsClaimed(address(this), user, asset, amount);
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
        (bool rateOk, uint256 rate,,) = _peekRate(asset, oracle, epoch, true);
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
        (bool rateOk, uint256 rate, bool freshOk,) = _peekRate(buybackAsset, oracle, epoch, false);
        if (!rateOk || !freshOk) return (false, 0, 0);
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

    /// @notice Anchor telemetry. `blockNumber` is the block of the last ACCEPTED
    ///         read (the anchor advances at most once per block).
    function anchorOf(address asset)
        external
        view
        returns (uint192 rate, uint64 blockNumber, uint32 epoch)
    {
        FlowstateStructs.Anchor storage a = anchors[asset];
        return (a.lastRate, a.lastRateBlock, a.lastRateEpoch);
    }

    /// @notice Monitoring hook for the clamped pricing model. Under the pre-2026-08-11
    ///         anchor a broken oracle announced itself by halting the pool; clamping
    ///         deliberately removed that, so a dead or wildly displaced feed is now
    ///         SILENT to a trader and has to be watched for explicitly.
    /// @dev Calls the same `_tryReadOracle` the trade path calls, so a monitor cannot
    ///      drift from what the pool actually does.
    /// @return readable false when the oracle reverts, returns zero (every venue
    ///         failed the depth rules) or returns an out-of-range rate. Page on this:
    ///         the pool is quoting `anchorRate` indefinitely and cannot re-converge.
    /// @return freshRate the live read (0 when unreadable).
    /// @return anchorRate the rate the pool is anchored to right now.
    /// @return anchorBlock the block that anchor was accepted in. `freshRate` far from
    ///         `anchorRate` while `anchorBlock` stops advancing means the pool is
    ///         persistently clamping — normal for a block or two, worth an alert if it
    ///         lasts, since quotes are then priced off a price the market has left.
    function oracleHealth(address asset, address oracle)
        external
        view
        returns (bool readable, uint256 freshRate, uint192 anchorRate, uint64 anchorBlock)
    {
        (readable, freshRate) = _tryReadOracle(asset, oracle);
        FlowstateStructs.Anchor storage a = anchors[asset];
        return (readable, freshRate, a.lastRate, a.lastRateBlock);
    }

    /// @notice The buy-side staleness surcharge currently in force, in bps: zero
    ///         whenever the oracle is readable; while it is not, 1bp per
    ///         STALE_RAMP_BLOCKS_PER_BP blocks since the last accepted read, capped
    ///         at STALE_SURCHARGE_CAP_BPS. Monitoring/integrator convenience — the
    ///         pricing paths compute this themselves from the same inputs, so this
    ///         view can never disagree with an execution.
    function staleSurchargeBpsOf(address asset, address oracle, uint32 epoch)
        external
        view
        returns (uint256)
    {
        // deliberately DERIVED from the same _peekRate the quoter runs, rather than
        // re-computed here: a monitor reading a number the pricing path did not
        // actually apply is the drift this contract refuses to allow anywhere else.
        (, , , uint256 bps) = _peekRate(asset, oracle, epoch, true);
        return bps;
    }

    /// @notice The displaced read currently awaiting one-block confirmation, if any.
    ///         `valid` is false when the stored candidate predates the last accepted
    ///         anchor write and is therefore already discarded.
    function pendingAnchorOf(address asset)
        external
        view
        returns (uint192 rate, uint64 blockNumber, bool valid)
    {
        FlowstateStructs.Anchor storage a = anchors[asset];
        return (a.pendingRate, a.pendingBlock, a.pendingRate != 0 && a.pendingBlock > a.lastRateBlock);
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

    /// @dev Rate resolution (2026-08-11 redesign). Two independent jobs, kept
    ///      deliberately separate because they answer different questions:
    ///
    ///      (1) ANCHOR MAINTENANCE — "what do we believe the price is?" The anchor
    ///          advances at most ONCE PER BLOCK. A read inside anchorBandBps of it
    ///          is believed immediately; a read outside is only a CANDIDATE, and
    ///          becomes the anchor solely if the same level is still there
    ///          CONFIRM_BLOCKS later. A flash loan lives inside one transaction in
    ///          one block, so it can never both open and confirm a candidate.
    ///
    ///      (2) PRICING — "what do we charge for THIS trade?" Whenever the fresh
    ///          read and the anchor disagree, price on the side that favours the
    ///          pool's depositors: buys take the HIGHER, sells take the LOWER. A
    ///          manipulated-down read cannot buy inventory cheap, a manipulated-up
    ///          read cannot sell into the cash side dear, and an honest trader on
    ///          the other side of the same move still gets a fillable quote.
    ///
    ///      Market conditions NEVER revert this function. An unreadable oracle
    ///      clamps to the anchor and reports freshOk=false so the caller can decide
    ///      (the buy path quotes anyway; the sell path, which spends pool cash,
    ///      declines). The only revert is an unseeded asset, which is configuration,
    ///      not market state.
    /// @dev The ONE block counter every anchor rule reads (see USE_ARB_SYS above).
    ///      On non-Arbitrum chains this is block.number; on Arbitrum-family chains
    ///      it is the real L2 height from the ArbSys precompile.
    function _currentBlock() private view returns (uint256) {
        return USE_ARB_SYS ? ARB_SYS.arbBlockNumber() : block.number;
    }

    /// @dev The anchor's stored block, normalised. A stored value AHEAD of the
    ///      current block is impossible for this implementation to have written
    ///      (it only ever stores _currentBlock()), so it can only be foreign
    ///      state, and there are exactly two ways to get it:
    ///
    ///        1. an in-place BEACON UPGRADE over a pre-2026-08-11 pool, where this
    ///           slot held `lastRateTime`, a unix timestamp (~1.79e9 versus an L2
    ///           height of ~3.4e7 — measured on the live staging pool);
    ///        2. an implementation deployed with the WRONG USE_ARB_SYS flag on a
    ///           chain whose two clocks differ (RH: ArbSys ~3.4e7 vs block.number
    ///           ~2.6e7, the parent chain's height).
    ///
    ///      Both are migration accidents, not market conditions, and both would
    ///      otherwise be catastrophic in the same two ways: the maintenance gate
    ///      `blk > lastRateBlock` stays false for years, wedging the anchor at a
    ///      price the market has left (the exact failure the redesign exists to
    ///      remove), and the staleness surcharge's block subtraction underflows
    ///      and PANIC-REVERTS the buy path (breaking the never-revert guarantee
    ///      outright). Treating it as "long ago" makes the pool heal itself on the
    ///      very next read under the ordinary band and confirmation rules — no
    ///      admin step, no keeper, no band-check-free reseed, and the stored RATE
    ///      is untouched, so nobody can pick a price by timing the migration.
    function _lastBlock(FlowstateStructs.Anchor storage a, uint256 blk)
        private
        view
        returns (uint256)
    {
        uint256 stored = a.lastRateBlock;
        return stored > blk ? 0 : stored;
    }

    function _resolveRate(address asset, address oracle, uint32 epoch, bool preferHigh)
        private
        returns (uint256 rate, bool freshOk)
    {
        FlowstateStructs.Anchor storage a = anchors[asset];
        if (a.lastRate == 0) revert AnchorNotSeeded();

        uint256 blk = _currentBlock();
        uint256 lastBlk = _lastBlock(a, blk);
        // Same-block cache: the anchor was already accepted from a real read in this
        // block, so every later trade in the block prices off it and skips the oracle
        // call entirely. This is also the tightest possible clamp — an intra-block
        // displacement after an accepted read cannot move the price in EITHER
        // direction — and it is what makes a multi-trade block cheap.
        if (epoch == a.lastRateEpoch && blk == lastBlk) {
            return (a.lastRate, true);
        }

        uint256 fresh;
        (freshOk, fresh) = _tryReadOracle(asset, oracle);
        // clamp: never decline on a dead read. Buys additionally pay the staleness
        // surcharge, because this price is the anchor and the anchor is ageing.
        if (!freshOk) {
            return (preferHigh ? _applyStaleSurcharge(a.lastRate, a) : a.lastRate, false);
        }

        // Oracle migration (adversarial review 2026-08-13). The timelock attests to
        // the IDENTITY of the new oracle contract. It cannot attest to a PRICE READ
        // at a block a third party chooses — and the party who chooses is whoever
        // trades first after the migration, which is anyone. This branch used to
        // write that read straight to the anchor AND return it as the trade rate,
        // above the band check, above confirmation and above the clamp, so the first
        // post-migration trade priced at an unbounded, attacker-timed read.
        //
        // Now the epoch is only a MARKER: record it so this branch cannot re-fire,
        // discard any candidate opened under the previous oracle (a level observed
        // through a different feed must not be confirmed by this one), and let the
        // read earn its way in below under the ordinary rules. A migration that
        // agrees with the standing anchor is still adopted instantly, because an
        // in-band read always is; one that disagrees takes a single confirmation.
        if (epoch != a.lastRateEpoch) {
            uint256 clearedCandidate = a.pendingRate; // 0 when there was none
            a.lastRateEpoch = epoch;
            a.pendingRate = 0;
            a.pendingBlock = 0;
            // The anchor is ONE fact — "this rate was accepted at this block under
            // this epoch" — and _writeAnchor always writes the three together.
            // Recording the epoch alone would split it: an anchor accepted under
            // the PREVIOUS oracle would start carrying the NEW epoch, and if it was
            // written in THIS block it would then satisfy the same-block cache
            // above, so every later trade in the block would be served the old
            // oracle's price relabelled as the new one, without the new oracle ever
            // being read. Push the acceptance back one block so the stale anchor
            // cannot qualify for this epoch's cache, and so maintenance below still
            // runs and band-checks the new oracle's read.
            if (lastBlk == blk && blk > 0) {
                lastBlk = blk - 1;
                a.lastRateBlock = uint64(lastBlk);
            }
            emit FlowstateEvents.OracleEpochRecorded(address(this), asset, epoch, clearedCandidate);
        }

        // (1) maintenance — one write per block, so a single block can never walk
        //     the anchor twice (which would defeat the confirmation via a staircase).
        if (blk > lastBlk) {
            if (_withinBand(fresh, a.lastRate)) {
                _writeAnchor(a, asset, uint192(fresh), epoch);
            } else if (
                a.pendingRate != 0
                // a candidate from an earlier accepted state, not a leftover: any
                // anchor write sets lastRateBlock = the current block, which
                // invalidates every pending recorded at or before it
                && a.pendingBlock > lastBlk
                // and it has survived the confirmation gap
                && blk >= uint256(a.pendingBlock) + CONFIRM_BLOCKS
                // still the same displaced level, not a fresh excursion
                && _withinBand(fresh, a.pendingRate)
            ) {
                _writeAnchor(a, asset, uint192(fresh), epoch);
            } else {
                // open (or replace) the candidate. Replacement matters: an attacker
                // who moves the venue somewhere NEW restarts their own clock.
                a.pendingRate = uint192(fresh);
                a.pendingBlock = uint64(blk);
            }
        }

        // (2) pricing — conservative side of any disagreement.
        //
        //     On the BUY side the surcharge follows the SOURCE of the price, not
        //     the readability of the oracle (JUP-529 revision, 2026-08-12). If the
        //     fresh read is at least the anchor we price at it: that is live
        //     market data (and covers the ordinary case where an in-band read has
        //     just been absorbed INTO the anchor, leaving the two equal), so
        //     marking it up would quote above a market we can actually see. If
        //     the ANCHOR is strictly higher we are pricing off stale
        //     information, and the markup applies exactly as it does for a dead
        //     oracle — including when the fresh read is readable but sits far
        //     BELOW the anchor. Gating the surcharge on `!freshOk` alone let a
        //     single readable low read strip it for that transaction, so anyone
        //     who could push one thin venue past the depth floor could buy at the
        //     bare stale anchor during an outage. Note the ramp is measured from
        //     the last ACCEPTED write, so in ordinary operation an in-band read
        //     has just re-stamped the anchor and the surcharge is exactly zero.
        uint256 anchored = a.lastRate;
        if (preferHigh) {
            return fresh >= anchored ? (fresh, true) : (_applyStaleSurcharge(anchored, a), true);
        }
        return (fresh < anchored ? fresh : anchored, true);
    }

    /// @dev Staleness surcharge (JUP-529), shared verbatim by priceBuy,
    ///      priceBuyExactQuote and previewBuy so the quoter and the fill can never
    ///      drift. Only ever called when the oracle read FAILED, so `lastRateBlock`
    ///      is by construction the last block a read was accepted in. Monotone in
    ///      _currentBlock() and self-cancelling: the first successful read either
    ///      prices fresh (surcharge path not taken) or re-anchors.
    ///
    ///      The subtraction is taken against the NORMALISED block (`_lastBlock`),
    ///      never the raw slot. A raw slot ahead of the current block is a
    ///      migration artifact rather than market state (a pre-2026-08-11 unix
    ///      timestamp, or a wrong USE_ARB_SYS flag), and subtracting it directly
    ///      would underflow and Panic-revert the buy path — the one thing this
    ///      contract promises can never happen. Normalised, such an anchor is
    ///      treated as if it were set at block zero: on any chain with a
    ///      meaningful height that saturates the cap, which is the depositor-safe
    ///      direction (a price of unknown age gets the full defensive markup
    ///      while the oracle is down), and the anchor heals itself on the first
    ///      good read regardless.
    function _staleSurchargeBps(FlowstateStructs.Anchor storage a) private view returns (uint256 bps) {
        uint256 blk = _currentBlock();
        bps = (blk - _lastBlock(a, blk)) / STALE_RAMP_BLOCKS_PER_BP;
        if (bps > STALE_SURCHARGE_CAP_BPS) bps = STALE_SURCHARGE_CAP_BPS;
    }

    /// @dev Buy-side application: a WORSE buy quote is a HIGHER rate (the buyer pays
    ///      more per token), so the markup runs against the clamp's frozen price.
    ///      Sell side deliberately does not mirror this — it declines outright on an
    ///      unreadable oracle (NoOracleRate), because it spends depositor cash.
    function _applyStaleSurcharge(uint256 rate, FlowstateStructs.Anchor storage a)
        private
        view
        returns (uint256)
    {
        return (rate * (BPS + _staleSurchargeBps(a))) / BPS;
    }

    /// @dev Band predicate shared by execution and preview so the quoter and the
    ///      fill can never drift. No time widening: with one-block confirmation the
    ///      band is a "small enough not to bother confirming" threshold, not a
    ///      speed limit, so letting it grow while idle would only weaken it.
    function _withinBand(uint256 fresh, uint256 anchorRef) private view returns (bool) {
        uint256 diff = fresh > anchorRef ? fresh - anchorRef : anchorRef - fresh;
        return diff * BPS <= anchorRef * uint256(anchorBandBps);
    }

    /// @dev Single writer for anchor state so no path can update it half-way.
    ///      Setting lastRateBlock also invalidates any outstanding candidate (see
    ///      the pendingBlock > lastRateBlock test). Values are pre-validated by
    ///      callers (≤ uint192.max via the oracle read bounds or seed checks).
    function _writeAnchor(
        FlowstateStructs.Anchor storage a,
        address, /* asset — kept for call-site readability */
        uint192 rate,
        uint32 epoch
    ) private {
        a.lastRate = rate;
        a.lastRateBlock = uint64(_currentBlock());
        a.lastRateEpoch = epoch;
    }

    /// @dev Non-reverting oracle read. ok=false covers a reverting oracle, a zero
    ///      rate (every venue failed the slim oracle's depth rules) and an
    ///      out-of-range rate.
    function _tryReadOracle(address asset, address oracle)
        private
        view
        returns (bool ok, uint256 rate)
    {
        try IOracle(oracle).getRate(IERC20(inventoryToken), IERC20(asset), false) returns (uint256 r) {
            if (r == 0 || r > type(uint192).max) return (false, 0);
            return (true, r);
        } catch {
            return (false, 0);
        }
    }

    /// @dev View twin of _resolveRate: identical resolution, no state writes. `ok`
    ///      reports only whether the asset is seeded — market conditions never make
    ///      a quote unavailable here. `freshOk` mirrors the execution path's oracle
    ///      read so the sell preview can decline exactly where priceSell would.
    function _peekRate(address asset, address oracle, uint32 epoch, bool preferHigh)
        private
        view
        returns (bool ok, uint256 rate, bool freshOk, uint256 surchargeBps)
    {
        FlowstateStructs.Anchor storage a = anchors[asset];
        if (a.lastRate == 0) return (false, 0, false, 0);

        uint256 fresh;
        (freshOk, fresh) = _tryReadOracle(asset, oracle);
        // mirrors _resolveRate: a dead read clamps to the anchor, and the buy side
        // pays the staleness surcharge on it
        if (!freshOk) {
            uint256 bps = preferHigh ? _staleSurchargeBps(a) : 0;
            return (true, (a.lastRate * (BPS + bps)) / BPS, false, bps);
        }
        // NOTE: no epoch special-case here on purpose (mirrors _resolveRate since
        // 2026-08-13). A migrated oracle's read is priced by the ordinary rules
        // below. The ONE place the epoch still matters to this view is the
        // candidate-confirmation test further down, which must not ratify a
        // candidate belonging to the previous oracle — see the gate there.

        uint256 blk = _currentBlock();
        uint256 lastBlk = _lastBlock(a, blk);
        // Mirror the migration rollback that _resolveRate performs. On an epoch
        // change, execution pushes an anchor accepted in THIS block back one, so
        // its maintenance runs and can accept the migrated read. Without the same
        // adjustment here the view's maintenance was skipped (blk > lastBlk being
        // false) and it kept quoting the OLD anchor while execution charged the
        // new in-band rate — a wei-level quoter/execution divergence in exactly
        // the window the rollback was added for.
        if (epoch != a.lastRateEpoch && lastBlk == blk && blk > 0) {
            lastBlk = blk - 1;
        }
        // mirror the maintenance step: if execution would accept this read, the
        // anchor it prices against is the fresh value
        if (epoch == a.lastRateEpoch && blk == lastBlk) {
            return (true, a.lastRate, true, 0); // same-block cache (mirrors execution)
        }
        uint256 anchored = a.lastRate;
        if (blk > lastBlk) {
            if (
                _withinBand(fresh, a.lastRate)
                    || (
                        // A candidate belongs to the oracle that produced it. Execution
                        // discards it on the epoch bump; this view CANNOT (it writes no
                        // state), so without this gate the quoter could confirm a stale
                        // candidate against the NEW oracle's read and quote a price
                        // execution would never charge. Treat it as already cleared,
                        // which is exactly what the next state-writing call does.
                        epoch == a.lastRateEpoch
                            && a.pendingRate != 0 && a.pendingBlock > lastBlk
                            && blk >= uint256(a.pendingBlock) + CONFIRM_BLOCKS
                            && _withinBand(fresh, a.pendingRate)
                    )
            ) {
                anchored = fresh;
            }
        }
        // mirrors _resolveRate's pricing exactly, surcharge included: a buy that
        // falls back to the anchor pays the staleness markup, a buy that prices
        // at a higher fresh read does not.
        if (preferHigh) {
            if (fresh >= anchored) {
                rate = fresh;
            } else {
                surchargeBps = _staleSurchargeBps(a);
                rate = (anchored * (BPS + surchargeBps)) / BPS;
            }
        } else {
            rate = fresh < anchored ? fresh : anchored;
        }
        ok = true;
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
