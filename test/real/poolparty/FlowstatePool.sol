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
 * @notice Fair-price pool for one (inventoryToken, quoteAsset) pair. Beacon-proxy
 *         implementation cloned per pool. Pass-1 rebuild of publicPool.sol.
 *
 * @dev Spec: docs/FLOWSTATE_PASS1_IMPLEMENTATION_PLAN_2026-07-16.md §3.2.
 *
 * Fee incidence (single model, both legs): the fee is always levied on the
 * pool-payout leg, denominated in the quote asset. On a BUY the token-side
 * contributors (sellers) pay it — they are credited quotePaid − fee. On a SELL
 * (M2) the seller receives quoteGross − fee. Buyers never pay the fee.
 *
 * Anchor band: the pool is its own one-slot price historian (the 1inch oracle is
 * spot-only). A fresh oracle read must sit within anchorBandBps × widen of the
 * stored anchor, where widen = 1 + elapsedSeconds/60 capped at 4 — an atomic
 * flash-crash reverts against the pre-attack anchor, while natural drift on an
 * idle pool heals within minutes instead of bricking the pool. The anchor is
 * SEEDED at pool creation from the factory's listability read, so no unchecked
 * first trade exists. An oracle-address migration at the factory bumps its epoch;
 * a pool seeing a new epoch reseeds band-check-free on its next trade — safe
 * because setPriceOracle is timelocked (announced), never attacker-triggerable.
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
    error NotAContributor();
    error InsufficientPosition();
    error InvalidBand();
    error BuyBackDisabled();
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

    // ── storage (fresh layout; OZ bases are ERC-7201 namespaced) ─────────
    // slot 0 — identity + flags + epoch (single warm slot on the hot path)
    address public inventoryToken;
    uint16 public anchorBandBps;
    uint8 public priceSource;      // RESERVED (parked) — always 0 = AGGREGATOR in pass 1
    bool public buyBackEnabled;    // ships OFF; sell path lands in M2
    bool public poolPaused;
    bool public isHidden;
    uint32 public lastRateEpoch;
    // slot 1
    address public quoteAsset;
    uint16 public buySpreadBps;
    // slot 2
    address public factory;
    // slot 3 — oracle anchor + same-timestamp cache
    uint192 private lastRate;
    uint64 private lastRateTime;
    // slots 4/5 — inventory accounting
    uint256 public tokenBalance;
    uint256 public quoteBalance;
    // slots 6/7 — buy-back window cap (used from M2)
    uint128 public maxQuotePerWindow;
    uint128 public quoteSpentInWindow;
    uint64 public windowStart;
    uint32 public windowSeconds;
    // token-side FIFO ledger (index 0 = sentinel)
    FlowstateStructs.Node[] private tokenNodes;
    uint64 private tokenHead;
    uint64 private tokenTail;
    // cash-side FIFO ledger (used from M2)
    FlowstateStructs.Node[] private cashNodes;
    uint64 private cashHead;
    uint64 private cashTail;
    mapping(address => uint256) private tokenIndex;
    mapping(address => uint256) private cashIndex;
    // pool-local claim ledgers (plan D2)
    mapping(address => uint256) public claimableQuote;
    mapping(address => uint256) public claimableTokens;
    mapping(address => bool) public recycleOptIn;
    uint256[24] private __gap;

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param seedRate  the factory's listability getRate read at createPool — the anchor
    ///                  is live from creation, so no unchecked first trade exists (R13).
    ///                  Seeding from the creation-time read trades "creator front-runs the
    ///                  first trade" for "creation is the first checked observation".
    function initialize(
        address token,
        address quoteAsset_,
        address factory_,
        uint16 bandBps,
        uint192 seedRate,
        uint32 seedEpoch
    ) external initializer {
        if (token == address(0) || quoteAsset_ == address(0) || factory_ == address(0) || seedRate == 0) {
            revert InvalidInitParams();
        }
        if (bandBps < MIN_BAND_BPS || bandBps > MAX_BAND_BPS) revert InvalidBand();
        __ReentrancyGuard_init();

        inventoryToken = token;
        quoteAsset = quoteAsset_;
        factory = factory_;
        anchorBandBps = bandBps;
        buySpreadBps = 50; // default 0.5%; adjustable via setBuyBack (M2)
        lastRate = seedRate;
        lastRateTime = uint64(block.timestamp);
        lastRateEpoch = seedEpoch;

        // sentinel node at index 0 for both FIFO lists
        tokenNodes.push(FlowstateStructs.Node(address(0), 0, 0, 0));
        cashNodes.push(FlowstateStructs.Node(address(0), 0, 0, 0));
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

    /// @notice Step 1: band-checked oracle read + FIFO-capped fillable amount + exact cost.
    /// @dev Cost is computed on the FILLABLE amount before anything is pulled, so an
    ///      over-pull/refund path never exists (deletes the stranded-payment bug class).
    ///      Practical bound (review F4): fillableAmount × rate must fit uint256; with
    ///      amounts ≤ 50 × uint128.max and real 1inch rates (≤ ~1e30) the product tops
    ///      out ~1e70 « 2^256. A pathological max-supply × max-rate pair Panic-reverts,
    ///      which is a liveness refusal, not an exploit.
    function priceBuy(uint256 requestedAmount, address oracle, uint32 epoch)
        external
        onlyFactory
        returns (uint256 fillableAmount, uint256 quoteCost, uint256 rate)
    {
        if (poolPaused) revert PoolIsPaused();
        if (tokenBalance == 0) revert NoLiquidity();
        if (requestedAmount == 0) revert InvalidAmount();

        rate = _resolveRate(oracle, epoch);

        fillableAmount = _fillableBuy(requestedAmount);
        if (fillableAmount == 0) revert NoLiquidity();

        // round UP against the buyer
        quoteCost = (fillableAmount * rate + RATE_SCALE - 1) / RATE_SCALE;
        if (quoteCost == 0) revert AmountTooSmall();
    }

    /// @notice Exact-quote twin of priceBuy (V4 hook build scope §2.2, additive): the
    ///         caller names the quote spend; the pool inverts to a token amount inside
    ///         the SAME single band-checked oracle read — the view quote path is never
    ///         involved, so no second cold read can exist in the transaction.
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
    function priceBuyExactQuote(uint256 quoteIn, address oracle, uint32 epoch)
        external
        onlyFactory
        returns (uint256 fillableAmount, uint256 quoteCost, uint256 rate)
    {
        if (poolPaused) revert PoolIsPaused();
        if (tokenBalance == 0) revert NoLiquidity();
        if (quoteIn == 0) revert InvalidAmount();

        rate = _resolveRate(oracle, epoch);

        // invert inside the single read: round DOWN against the buyer
        uint256 desired = (quoteIn * RATE_SCALE) / rate;
        if (desired == 0) revert AmountTooSmall();

        fillableAmount = _fillableBuy(desired);
        if (fillableAmount < desired) revert FillShortfall();

        // recompute the pull exactly as priceBuy would for this amount (round UP)
        quoteCost = (desired * rate + RATE_SCALE - 1) / RATE_SCALE;
    }

    /// @notice Step 2: factory has pulled `quotePaid` to this pool; settle ledgers,
    ///         distribute fees, transfer tokens to the buyer.
    /// @dev Fee-on-transfer inventory tokens under-deliver on buys (review F-M2-2): the
    ///      buyer pays oracle price for fillAmount but receives fillAmount minus the
    ///      token's own fee. Pool accounting stays consistent; the shortfall is the
    ///      buyer's. FoT tokens are unsupported as inventory — caller/lister beware
    ///      (the sell path rejects them outright via TransferAmountMismatch).
    function settleBuy(
        address buyer,
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
            // and only if the credit fits the uint128 node bound (else fall back).
            bool recycled = recycleOptIn[contributor] && buyBackEnabled && credit <= type(uint128).max;
            if (recycled && credit != 0) {
                _addToList(cashNodes, cashIndex, contributor, uint128(credit), true);
                quoteBalance += credit;
                emit FlowstateEvents.ProceedsRecycled(address(this), contributor, credit);
            } else {
                recycled = false;
                claimableQuote[contributor] += credit;
            }
            emit FlowstateEvents.ContributorFilled(address(this), contributor, take, credit, recycled);

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

        // fee split: fractions of the fee (3000/3000/4000 model); buyback takes the
        // remainder, which also absorbs rounding dust — never less than its 4000
        uint256 resellerCut = (fee * ctx.resellerShareBps) / BPS;
        uint256 bd1Cut = (fee * ctx.bd1ShareBps) / BPS;
        uint256 bd2Cut = (fee * ctx.bd2ShareBps) / BPS;
        uint256 buybackCut = fee - resellerCut - bd1Cut - bd2Cut;

        _pushQuote(ctx.resellerWallet, resellerCut);
        _pushQuote(ctx.bd1, bd1Cut);
        _pushQuote(ctx.bd2, bd2Cut);
        _pushQuote(ctx.buybackReceiver, buybackCut);
        emit FlowstateEvents.FeeDistributed(
            address(this), ctx.resellerCode, resellerCut, bd1Cut, bd2Cut, buybackCut
        );

        emit FlowstateEvents.PoolBuy(
            address(this), buyer, quoteAsset, fillAmount, quotePaid, rate, fee,
            tokenBalance == 0, ctx.resellerCode
        );

        IERC20(inventoryToken).safeTransfer(buyer, fillAmount);
    }

    // ────────────────────────────────────────────────────────────────────
    // Cash-side liquidity + sell path (buy-back mode — ships OFF, per-pool enable)
    // ────────────────────────────────────────────────────────────────────

    /// @dev Same pause policy as creditTokenContribution (D-M2-1): deposits blocked,
    ///      withdrawals never.
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
        IERC20(quoteAsset).safeTransfer(owner, withdrawn);
    }

    /// @notice Sell-path step 1: band-checked rate, buy-side spread, window cap, and
    ///         cash-FIFO capacity → fillable token amount + gross quote payout.
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

        rate = _resolveRate(oracle, epoch);
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
    ///         cash depositors, take the fee on the pool-payout leg, pay the seller.
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
            emit FlowstateEvents.ContributorFilled(address(this), owner, tokensCredit, take, false);

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

        uint256 resellerCut = (fee * ctx.resellerShareBps) / BPS;
        uint256 bd1Cut = (fee * ctx.bd1ShareBps) / BPS;
        uint256 bd2Cut = (fee * ctx.bd2ShareBps) / BPS;
        uint256 buybackCut = fee - resellerCut - bd1Cut - bd2Cut;
        _pushQuote(ctx.resellerWallet, resellerCut);
        _pushQuote(ctx.bd1, bd1Cut);
        _pushQuote(ctx.bd2, bd2Cut);
        _pushQuote(ctx.buybackReceiver, buybackCut);
        emit FlowstateEvents.FeeDistributed(
            address(this), ctx.resellerCode, resellerCut, bd1Cut, bd2Cut, buybackCut
        );

        emit FlowstateEvents.PoolSell(
            address(this), seller, quoteAsset, fillAmount, quoteGross, rate, fee,
            quoteBalance == 0, ctx.resellerCode
        );

        // seller payout is a hard transfer (no fallback credit): the seller is trading
        // for payment, not receiving a fee — a refusing/blocklisted seller should
        // revert the trade rather than strand value in a ledger they can't claim from
        IERC20(quoteAsset).safeTransfer(seller, sellerNet);
    }

    // ────────────────────────────────────────────────────────────────────
    // Claims (pool-local ledgers — plan D2). Silent no-op on zero so the
    // factory's claimMany can iterate without reverting on empty pools.
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

    function _claimQuote(address user) private {
        uint256 amount = claimableQuote[user];
        if (amount == 0) return;
        claimableQuote[user] = 0;
        IERC20(quoteAsset).safeTransfer(user, amount);
        emit FlowstateEvents.ProceedsClaimed(address(this), user, quoteAsset, amount);
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
    function setBuyBack(bool enabled, uint16 spreadBps, uint128 maxPerWindow, uint32 windowSecs)
        external
        onlyFactory
    {
        if (spreadBps > MAX_SPREAD_BPS) revert SpreadTooHigh();
        if ((maxPerWindow == 0) != (windowSecs == 0)) revert InvalidWindowConfig();
        buyBackEnabled = enabled;
        buySpreadBps = spreadBps;
        maxQuotePerWindow = maxPerWindow;
        windowSeconds = windowSecs;
        if (maxPerWindow != 0) {
            windowStart = uint64(block.timestamp);
            quoteSpentInWindow = 0;
        }
    }

    /// @notice Liveness escape hatch (D3): unconditionally re-anchors to a fresh read.
    function resetAnchor(address oracle, uint32 epoch) external onlyFactory {
        uint256 fresh = IOracle(oracle).getRate(IERC20(inventoryToken), IERC20(quoteAsset), false);
        if (fresh == 0 || fresh > type(uint192).max) revert NoOracleRate();
        lastRate = uint192(fresh);
        lastRateTime = uint64(block.timestamp);
        lastRateEpoch = epoch;
        emit FlowstateEvents.AnchorReseeded(address(this), fresh, epoch);
    }

    // ────────────────────────────────────────────────────────────────────
    // Views
    // ────────────────────────────────────────────────────────────────────

    /// @notice View twin of priceBuy — the quoter backend (§3.1). Never reverts.
    /// @dev Consistency invariant: same block + same args ⇒ (fillable, cost) here
    ///      equals what buyFromPool executes, because rate resolution, the FIFO walk,
    ///      and the rounding are the same shared code paths.
    function previewBuy(uint256 amount, address oracle, uint32 epoch)
        external
        view
        returns (bool ok, uint256 fillable, uint256 cost)
    {
        if (poolPaused || tokenBalance == 0 || amount == 0) return (false, 0, 0);
        (bool rateOk, uint256 rate) = _peekRate(oracle, epoch);
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
        (bool rateOk, uint256 rate) = _peekRate(oracle, epoch);
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

    function anchor() external view returns (uint192 rate, uint64 time, uint32 epoch) {
        return (lastRate, lastRateTime, lastRateEpoch);
    }

    function positions(address user)
        external
        view
        returns (uint256 tokenPosition, uint256 cashPosition, uint256 claimQ, uint256 claimT)
    {
        uint256 tIdx = tokenIndex[user];
        if (tIdx != 0) tokenPosition = tokenNodes[tIdx].amount;
        uint256 cIdx = cashIndex[user];
        if (cIdx != 0) cashPosition = cashNodes[cIdx].amount;
        claimQ = claimableQuote[user];
        claimT = claimableTokens[user];
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

    /// @dev Rate resolution — normative logic from plan §3.2:
    ///      1. new factory epoch → reseed band-check-free (timelock-announced event);
    ///      2. same timestamp → cached rate, no oracle call;
    ///      3. otherwise → fresh read, band check widened by elapsed time, then update.
    function _resolveRate(address oracle, uint32 epoch) private returns (uint256) {
        if (epoch != lastRateEpoch) {
            uint256 reseeded = _readOracle(oracle);
            lastRate = uint192(reseeded);
            lastRateTime = uint64(block.timestamp);
            lastRateEpoch = epoch;
            emit FlowstateEvents.AnchorReseeded(address(this), reseeded, epoch);
            return reseeded;
        }

        if (block.timestamp == lastRateTime) {
            return lastRate; // same-timestamp cache: no oracle call, no new information
        }

        uint256 fresh = _readOracle(oracle);
        if (!_withinBand(fresh, lastRate, block.timestamp - lastRateTime)) revert RateOutOfBand();

        lastRate = uint192(fresh);
        lastRateTime = uint64(block.timestamp);
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

    /// @dev View twin of _resolveRate: identical rate resolution, no state writes, no
    ///      reverts (oracle failures return ok=false).
    function _peekRate(address oracle, uint32 epoch) private view returns (bool ok, uint256 rate) {
        if (epoch == lastRateEpoch && block.timestamp == lastRateTime) {
            return (true, lastRate); // cache hit — execution would not call the oracle either
        }
        uint256 fresh;
        try IOracle(oracle).getRate(IERC20(inventoryToken), IERC20(quoteAsset), false) returns (uint256 r) {
            fresh = r;
        } catch {
            return (false, 0);
        }
        if (fresh == 0 || fresh > type(uint192).max) return (false, 0);
        if (epoch != lastRateEpoch) return (true, fresh); // execution would reseed band-check-free
        if (!_withinBand(fresh, lastRate, block.timestamp - lastRateTime)) return (false, 0);
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

    function _readOracle(address oracle) private view returns (uint256 rate) {
        rate = IOracle(oracle).getRate(IERC20(inventoryToken), IERC20(quoteAsset), false);
        if (rate == 0 || rate > type(uint192).max) revert NoOracleRate();
    }

    /// @dev Fee push with fallback credit: a receiver the quote asset refuses (e.g. a
    ///      USDC-blocklisted wallet) is credited on the pool ledger instead of
    ///      reverting the trade (audit "reverting fee receiver" fix, ERC20 edition).
    ///      The return-data check is STRICT (empty or exactly 32 bytes decoding true) —
    ///      any odd-shaped return counts as failure and takes the credit fallback,
    ///      never a revert (review F1: abi.decode on 1–31 bytes would panic and turn
    ///      the fallback into a trade-reverting griefing surface).
    function _pushQuote(address receiver, uint256 amount) private {
        if (amount == 0 || receiver == address(0)) return;
        (bool ok, bytes memory ret) =
            quoteAsset.call(abi.encodeCall(IERC20.transfer, (receiver, amount)));
        if (ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))))) return;
        claimableQuote[receiver] += amount;
        emit FlowstateEvents.FeePushFailed(address(this), receiver, amount);
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
