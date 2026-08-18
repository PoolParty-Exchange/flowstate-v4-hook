// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlowstateMarketMinimal} from "./interfaces/IFlowstateMarketMinimal.sol";
import {IFlowstateBuyFunder} from "./interfaces/IFlowstateBuyFunder.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

/// @title FlowstateC1Hook
/// @notice Uniswap V4 custom-curve hook adapting routed BUY flow onto Flowstate C1 pool
///         inventory via the pull-exact FlowstateMarket. The hook fully overrides the
///         concentrated-liquidity curve (BEFORE_SWAP_RETURNS_DELTA consuming the entire
///         specified amount), so pools carry no tradeable V4 liquidity and the market
///         does 100% of the pricing. The single permitted exception is the visibility
///         beacon: one liquidityDelta == 1 dust add per pool (see beforeAddLiquidity),
///         which exists to emit the ModifyLiquidity event some routing indexers key on
///         and can never participate in pricing.
///
/// @dev BUY-ONLY (scope §4, correction C1): a buy is quote-asset in, inventory token out.
///      Both sell-direction paths revert with SellDirectionNotSupported, identically in
///      the V4Quoter simulation and the real swap. Sellers exit through the existing C1
///      deposit-and-claim path, off-hook.
///
///      Custody: the hook holds no user funds. Between unlocks its ONLY balances are
///      accrued spread margin + inversion dust awaiting the owner sweep (scope §8);
///      everything else exists only transiently inside a single PoolManager unlock
///      (take input -> market pulls exactly the cost -> settle output). No pause, no
///      sender gates, hookData never read (scope rules 1-3).
///
///      Address flags must be 0x28cc: BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY |
///      BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA.
contract FlowstateC1Hook is IHooks, IFlowstateBuyFunder, Ownable2Step {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using TransientStateLibrary for IPoolManager;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotPoolManager();
    error NotMarket();
    error HookNotImplemented();
    error ZeroAddress();
    error PairNotRegistered();
    error LpFeeMustBeZero();
    error LiquidityNotAllowed();
    error SellDirectionNotSupported();
    error NativeQuoteUnsupported(); // registerPair with a native quote on a chain with no weth9 configured
    error UnexpectedNativeSender(address sender);
    error ManagerReservesExceeded(Currency currency, uint256 requested, uint256 available);
    error SpreadOutOfRange(uint16 bps, uint16 floorBps, uint16 maxBps);
    error TradeTooSmallForSpread(uint256 quoteIn, uint256 spreadBps);
    error PartialFillUnsupportedForNativeQuote(); // refunding native needs an unwrap path this hook lacks
    error RungScheduleInvalid();
    error SweepDestinationNotSet();
    error EthSweepFailed();

    // -------------------------------------------------------------------------
    // Immutable wiring
    // -------------------------------------------------------------------------

    /// @notice The canonical PoolManager on this chain.
    IPoolManager public immutable poolManager;

    /// @notice The FlowstateMarket router (final Phase 1 pull-exact surface: the
    ///         exact-quote entry-point pair incl. the fundBuy funding callback; the
    ///         Phase 0 mock implements the identical interface for fork tests).
    IFlowstateMarketMinimal public immutable market;

    /// @notice Wrapped-native (aeWETH on RH). Native-quoted V4 pools are served by
    ///         wrapping the taken native into this asset before the market call, so
    ///         ONE wrapped-quote C1 pool serves BOTH V4 currency representations.
    ///         address(0) disables native-quote support on chains without a wrapper.
    IWETH9 public immutable weth9;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard cap on baseSpreadBps and on any single rung's extraBps (10%).
    ///         Structural ceiling on the total spread is therefore 2 * MAX_SPREAD_BPS.
    uint16 public constant MAX_SPREAD_BPS = 1_000;

    // -------------------------------------------------------------------------
    // Admin-controlled state
    // -------------------------------------------------------------------------

    struct PairConfig {
        address marketPool;
        bool quoteIsCurrency0;
        bool registered;
        uint16 baseSpreadBps; // packed into the same slot: zero hot-path cost
        // The ERC-20 the market is actually called with: the quote currency itself,
        // or weth9 when the V4 quote currency is native (the hook wraps in between).
        address marketAsset;
    }

    /// @notice One size-adjustment rung (scope §5): trades whose quote notional is
    ///         <= notionalCeiling pay extraBps on top of the pair's baseSpreadBps.
    struct SpreadRung {
        uint128 notionalCeiling; // in raw quote-asset units
        uint16 extraBps;
    }

    /// @dev One-frame flag armed by _buyExactOutput for native-quoted pairs and read
    ///      by fundBuy inside the same swap; always cleared before the frame returns.
    bool private _takeNativeInCallback;

    /// @notice Pair registry gating pool initialization and resolving swap-time config.
    ///         Keyed by keccak256(currency0, currency1) in V4 sorted order.
    mapping(bytes32 pairKey => PairConfig config) public pairs;

    /// @notice Visibility beacon: whether a pool has consumed its single permitted
    ///         liquidityDelta == 1 dust add (JUP-516). Measured 2026-08-08: GMGN's
    ///         routing index admits pools by ModifyLiquidity history, so one dust add
    ///         is the difference between invisible and routable there. Permissionless
    ///         by design: any caller may fire it, the 1-wei cap means no real capital
    ///         can ever be parked, and the dust never trades (beforeSwap consumes the
    ///         entire specified amount, so the core curve always runs on zero).
    mapping(PoolId poolId => bool seeded) public beaconSeeded;

    /// @notice Size-adjustment schedule PER MARKET ASSET: notional is measured in raw
    ///         units of the asset the market is called with, so a schedule cannot be
    ///         shared across assets with different decimals/value. For native-quoted
    ///         V4 pools the market asset is the WRAPPER, so native and wrapped pools
    ///         share ONE schedule (their units are identical by construction) — keyed
    ///         under the wrapper's address. Rungs are stored strictly ascending by
    ///         ceiling with non-decreasing extraBps (unordered input is REJECTED, not
    ///         normalized — RungScheduleInvalid). Evaluation: the first rung whose
    ///         ceiling >= notional applies; above the top ceiling the TOP rung's
    ///         extraBps applies (open-ended, so a huge trade never pays fewer bps
    ///         than a mid-size one). Empty schedule = baseSpread only (ship default).
    mapping(Currency quote => SpreadRung[] rungs) internal _sizeRungs;

    /// @notice Config-time floor on baseSpreadBps (the per-chain oracle-drift floor,
    ///         scope §5: 10 bps BSC / 16 bps RH / 23 bps Base — set operationally at
    ///         deploy). Checked in registerPair/setBaseSpread only, NEVER on the hot
    ///         path; raising it does not retro-check already-registered pairs (the
    ///         runbook re-sets spreads after raising the floor).
    uint16 public baseSpreadFloorBps;

    /// @notice Reseller code passed to the market on each buy ("" = none).
    string public resellerCode;

    // -------------------------------------------------------------------------
    // Margin accrual + sweep state
    // -------------------------------------------------------------------------

    /// @notice Spread margin accrued per quote asset: exactly
    ///         ceil(recomputedOracleCost * spreadBps / 10_000) summed per fill.
    mapping(Currency asset => uint256 amount) public accruedSpreadMargin;

    /// @notice Inversion/carve dust accrued per quote asset on exactInput fills:
    ///         quoteIn - quotePaid - spread. Tracked DISTINCTLY from spread margin so
    ///         sweep reconciliation stays clean; both sit as hook balance awaiting
    ///         the same sweep.
    mapping(Currency asset => uint256 amount) public accruedDust;

    /// @notice Owner-settable sweep destination (scope §5: the same wallet the
    ///         UniswapX executor margins sweep to today).
    address public sweepDestination;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PairRegistered(
        Currency indexed currency0, Currency indexed currency1, address indexed marketPool, bool quoteIsCurrency0
    );
    event PairUnregistered(Currency indexed currency0, Currency indexed currency1);
    event ResellerCodeUpdated(string previous, string current);
    /// @dev quoteIn is the buyer's gross payment (market cost + spread + dust). The
    ///      accrual components are emitted per fill so the O1 attribution indexer can
    ///      reconcile per-router margin against sweeps without tracing.
    event BuyExecuted(
        PoolId indexed poolId,
        Currency quote,
        Currency token,
        uint256 quoteIn,
        uint256 tokensOut,
        bool exactInput,
        uint256 spreadAccrued,
        uint256 dustAccrued
    );
    event BeaconSeeded(PoolId indexed poolId, address indexed sender);
    event BaseSpreadUpdated(Currency indexed currency0, Currency indexed currency1, uint16 baseSpreadBps);
    event BaseSpreadFloorUpdated(uint16 previous, uint16 current);
    event SizeRungsUpdated(Currency indexed quote, SpreadRung[] rungs);
    event SweepDestinationUpdated(address previous, address current);
    event MarginSwept(
        Currency indexed asset, address indexed to, uint256 spreadPortion, uint256 dustPortion, uint256 swept
    );
    event ETHSwept(address indexed to, uint256 amount);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _poolManager canonical PoolManager for this chain.
    /// @param _market      FlowstateMarket (must be non-zero and code-bearing).
    /// @param _owner       admin for the pair registry and reseller code.
    constructor(address _poolManager, address _market, address _owner, address _weth9)
        Ownable(_owner)
    {
        if (_poolManager == address(0) || _market == address(0)) revert ZeroAddress();
        if (_market.code.length == 0) revert ZeroAddress();

        poolManager = IPoolManager(_poolManager);
        market = IFlowstateMarketMinimal(_market);
        weth9 = IWETH9(_weth9); // address(0) = native quotes disabled on this chain

        Hooks.validateHookPermissions(
            this,
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /// @notice Register a (quote, token) pair, wiring it to its FlowstateMarket pool.
    ///         Grants the market a standing quote-asset allowance so the pull-exact
    ///         transferFrom never pays approval gas on the hot path. baseSpreadBps is
    ///         floor- and cap-checked here (config time), never on the hot path.
    function registerPair(Currency quote, Currency token, address marketPool, uint16 baseSpreadBps)
        external
        onlyOwner
    {
        if (marketPool == address(0)) revert ZeroAddress();
        _checkBaseSpread(baseSpreadBps);
        // native quote (v1 decision, 2026-07-30): served by wrapping into weth9, so
        // the market-side asset for a native pair IS the wrapper
        address marketAsset;
        if (quote.isAddressZero()) {
            if (address(weth9) == address(0)) revert NativeQuoteUnsupported();
            marketAsset = address(weth9);
        } else {
            marketAsset = Currency.unwrap(quote);
        }
        (Currency c0, Currency c1) = _sort(quote, token);
        bool quoteIsCurrency0 = Currency.unwrap(quote) == Currency.unwrap(c0);
        pairs[_pairKey(c0, c1)] = PairConfig({
            marketPool: marketPool,
            quoteIsCurrency0: quoteIsCurrency0,
            registered: true,
            baseSpreadBps: baseSpreadBps,
            marketAsset: marketAsset
        });
        IERC20(marketAsset).forceApprove(address(market), type(uint256).max);
        emit PairRegistered(c0, c1, marketPool, quoteIsCurrency0);
        emit BaseSpreadUpdated(c0, c1, baseSpreadBps);
    }

    function unregisterPair(Currency currencyA, Currency currencyB) external onlyOwner {
        (Currency c0, Currency c1) = _sort(currencyA, currencyB);
        delete pairs[_pairKey(c0, c1)];
        emit PairUnregistered(c0, c1);
    }

    /// @notice Retune a registered pair's base spread. Floor/cap enforced here only.
    function setBaseSpread(Currency quote, Currency token, uint16 baseSpreadBps) external onlyOwner {
        (Currency c0, Currency c1) = _sort(quote, token);
        bytes32 key = _pairKey(c0, c1);
        if (!pairs[key].registered) revert PairNotRegistered();
        _checkBaseSpread(baseSpreadBps);
        pairs[key].baseSpreadBps = baseSpreadBps;
        emit BaseSpreadUpdated(c0, c1, baseSpreadBps);
    }

    /// @notice Set the per-chain oracle-drift floor for baseSpreadBps (config-time
    ///         check only; does not retro-check registered pairs).
    function setBaseSpreadFloor(uint16 floorBps) external onlyOwner {
        if (floorBps > MAX_SPREAD_BPS) revert SpreadOutOfRange(floorBps, 0, MAX_SPREAD_BPS);
        emit BaseSpreadFloorUpdated(baseSpreadFloorBps, floorBps);
        baseSpreadFloorBps = floorBps;
    }

    /// @notice Replace the size-adjustment schedule for a quote asset. Input must be
    ///         strictly ascending by notionalCeiling with non-decreasing extraBps and
    ///         every extraBps <= MAX_SPREAD_BPS; anything else is REJECTED with
    ///         RungScheduleInvalid (no normalization). An empty array clears the
    ///         schedule (baseSpread-only behavior, the conservative ship default).
    function setSizeRungs(Currency quote, SpreadRung[] calldata rungs) external onlyOwner {
        uint128 prevCeiling = 0;
        uint16 prevExtra = 0;
        for (uint256 i = 0; i < rungs.length; i++) {
            if (
                rungs[i].notionalCeiling <= prevCeiling || rungs[i].extraBps < prevExtra
                    || rungs[i].extraBps > MAX_SPREAD_BPS
            ) revert RungScheduleInvalid();
            prevCeiling = rungs[i].notionalCeiling;
            prevExtra = rungs[i].extraBps;
        }
        delete _sizeRungs[quote];
        for (uint256 i = 0; i < rungs.length; i++) {
            _sizeRungs[quote].push(rungs[i]);
        }
        emit SizeRungsUpdated(quote, rungs);
    }

    function setResellerCode(string calldata code) external onlyOwner {
        emit ResellerCodeUpdated(resellerCode, code);
        resellerCode = code;
    }

    function setSweepDestination(address destination) external onlyOwner {
        if (destination == address(0)) revert ZeroAddress();
        emit SweepDestinationUpdated(sweepDestination, destination);
        sweepDestination = destination;
    }

    // -------------------------------------------------------------------------
    // Sweep (mirrors the UniswapX executor's sweepTokens/sweepETH collection path)
    // -------------------------------------------------------------------------

    /// @notice Collect accrued margin for one quote asset. Sweeps the hook's FULL
    ///         balance — which is exactly accruedSpreadMargin + accruedDust by
    ///         construction (the hook holds nothing else between unlocks), plus any
    ///         force-sent donation dust (recovered here, mirroring the executor's
    ///         stuck-dust recovery). Both accrual counters reset; the event carries
    ///         the split so off-chain reconciliation (O1 monthly pass) can check
    ///         spreadPortion + dustPortion == swept absent donations.
    function sweepMargin(Currency asset) external onlyOwner returns (uint256 swept) {
        address to = sweepDestination;
        if (to == address(0)) revert SweepDestinationNotSet();
        uint256 spreadPortion = accruedSpreadMargin[asset];
        uint256 dustPortion = accruedDust[asset];
        accruedSpreadMargin[asset] = 0;
        accruedDust[asset] = 0;
        swept = IERC20(Currency.unwrap(asset)).balanceOf(address(this));
        if (swept != 0) IERC20(Currency.unwrap(asset)).safeTransfer(to, swept);
        emit MarginSwept(asset, to, spreadPortion, dustPortion, swept);
    }

    /// @notice Recover ETH (none accrues in v1: the hook is all-ERC20 and has no
    ///         receive function; only force-sent ETH can land here).
    function sweepETH() external onlyOwner returns (uint256 swept) {
        address to = sweepDestination;
        if (to == address(0)) revert SweepDestinationNotSet();
        swept = address(this).balance;
        (bool ok,) = payable(to).call{value: swept}("");
        if (!ok) revert EthSweepFailed();
        emit ETHSwept(to, swept);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function isPairRegistered(Currency currencyA, Currency currencyB) external view returns (bool) {
        (Currency c0, Currency c1) = _sort(currencyA, currencyB);
        return pairs[_pairKey(c0, c1)].registered;
    }

    /// @notice The stored rung schedule for a quote asset.
    function sizeRungs(Currency quote) external view returns (SpreadRung[] memory) {
        return _sizeRungs[quote];
    }

    /// @notice Total spread (base + size adjustment) a trade of quoteNotional would
    ///         pay on this pair. Off-chain tooling / test helper; the hot path
    ///         computes the same thing inline.
    function spreadBpsFor(Currency quote, Currency token, uint256 quoteNotional) external view returns (uint256) {
        (Currency c0, Currency c1) = _sort(quote, token);
        PairConfig memory cfg = pairs[_pairKey(c0, c1)];
        if (!cfg.registered) revert PairNotRegistered();
        return _spreadBps(cfg.baseSpreadBps, Currency.wrap(cfg.marketAsset), quoteNotional);
    }

    // -------------------------------------------------------------------------
    // Hook callbacks — implemented
    // -------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (key.fee != 0) revert LpFeeMustBeZero();
        if (!pairs[_pairKey(key.currency0, key.currency1)].registered) revert PairNotRegistered();
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Visibility beacon gate (JUP-516): admits exactly ONE liquidityDelta == 1
    ///         add per pool, from any caller, then closes that pool forever. The
    ///         ModifyLiquidity event this permits is the measured key into GMGN's
    ///         routing index. Everything else about the original stray-LP protection
    ///         survives: no position of real size can ever be created (delta capped at
    ///         1), the dust never participates in pricing (the custom curve consumes
    ///         the entire specified amount before the core swap runs), and removals
    ///         remain unflagged because the only position that can exist is 1 wei.
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        if (beaconSeeded[id] || params.liquidityDelta != 1) revert LiquidityNotAllowed();
        beaconSeeded[id] = true;
        emit BeaconSeeded(id, sender);
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev The custom curve. Consumes the entire specified amount (specifiedDelta =
    ///      -amountSpecified) so the concentrated-liquidity swap runs on zero and the
    ///      hook does 100% of the pricing. hookData is never read (rule 1). Spread
    ///      determination (scope §5): spreadBps = baseSpread[pair] + sizeRung(quote
    ///      notional); the buyer pays market cost * (1 + spreadBps/10_000); the
    ///      spread accrues as margin per quote asset awaiting sweep. Inputs are pool
    ///      identity and trade size ONLY (§5b: no per-caller logic).
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PairConfig memory cfg = pairs[_pairKey(key.currency0, key.currency1)];
        if (!cfg.registered) revert PairNotRegistered();

        (Currency input, Currency output) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        Currency quote = cfg.quoteIsCurrency0 ? key.currency0 : key.currency1;
        if (Currency.unwrap(input) != Currency.unwrap(quote)) revert SellDirectionNotSupported();

        bool exactInput = params.amountSpecified < 0;
        (uint256 quoteIn, uint256 tokensOut, uint256 spreadAccrued, uint256 dustAccrued, BeforeSwapDelta hookDelta) =
        exactInput
            ? _buyExactInput(cfg, input, output, params.amountSpecified, sender)
            : _buyExactOutput(cfg, input, output, params.amountSpecified);

        if (spreadAccrued != 0) accruedSpreadMargin[input] += spreadAccrued;
        if (dustAccrued != 0) accruedDust[input] += dustAccrued;

        emit BuyExecuted(key.toId(), quote, output, quoteIn, tokensOut, exactInput, spreadAccrued, dustAccrued);
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    /// @dev exactInput spread carve: the swapper's specified quoteIn is taken and
    ///      charged in full; the market is committed netQuote = floor(quoteIn *
    ///      10_000 / (10_000 + spreadBps)) — floored so the carve can never eat into
    ///      what the spread is owed — and prices tokens on that remainder. The spread
    ///      then accrues on the RECOMPUTED oracle cost the market actually pulled
    ///      (quotePaid <= netQuote), as ceil(quotePaid * spreadBps / 10_000): never
    ///      undercollects, exceeds the exact bps product by < 1 wei. Whatever is left
    ///      of quoteIn (carve residue + the market's floor/ceil inversion dust) is
    ///      accounted separately as dust, never folded into spread margin.
    ///      Rung lookup uses quoteIn (the committed notional — the only quote-side
    ///      size known before the market call).
    function _buyExactInput(
        PairConfig memory cfg,
        Currency input,
        Currency output,
        int256 amountSpecified,
        address sender
    )
        internal
        returns (uint256 quoteIn, uint256 tokensOut, uint256 spreadAccrued, uint256 dustAccrued, BeforeSwapDelta hookDelta)
    {
        quoteIn = uint256(-amountSpecified);
        uint256 spreadBps = _spreadBps(cfg.baseSpreadBps, Currency.wrap(cfg.marketAsset), quoteIn);
        uint256 netQuote = spreadBps == 0 ? quoteIn : quoteIn * BPS_DENOMINATOR / (BPS_DENOMINATOR + spreadBps);
        // Sub-dust ticket: the carve leaves the market nothing to price. Raise the
        // explicit typed error rather than letting FlowstatePool's InvalidAmount
        // surface for a hook-caused condition (same posture as ManagerReservesExceeded,
        // §2.1).
        if (netQuote == 0) revert TradeTooSmallForSpread(quoteIn, spreadBps);
        _takeChecked(input, quoteIn);
        // native quote: wrap the WHOLE take (cost + spread + dust) so accrued margin
        // is held uniformly in the wrapper and the sweep path stays ERC-20-only
        if (input.isAddressZero()) weth9.deposit{value: quoteIn}();
        uint256 quotePaid;
        (tokensOut, quotePaid) =
            market.buyFromPoolExactQuote(cfg.marketPool, cfg.marketAsset, netQuote, resellerCode, address(this));
        _settle(output, tokensOut);
        spreadAccrued = _ceilBps(quotePaid, spreadBps);

        // JUP-559 partial fill. The pool may now fill SHORT of netQuote when inventory
        // runs out, so `leftover` is either the ordinary carve residue (a wei or two) or
        // the unfilled remainder of a short fill. Either way the swapper is charged only
        // quotePaid + spread, and the rest is handed back through PoolManager accounting
        // via settleFor(sender): that shrinks the ROUTER's open debt, and v4-periphery's
        // SETTLE_ALL pays `_getFullDebt` (the live delta) rather than the amount it
        // originally specified, so the swapper simply pays less.
        //
        // The specified delta below still offsets the FULL amountSpecified, so
        // amountToSwap == 0 and Pool.swap takes its zero-amount early return. NO residual
        // reaches the core AMM. That is what keeps the price from being walked to the
        // router's limit and parked there, which (measured, see
        // test/fork/PartialFillFallthrough.t.sol) would otherwise brick the pool
        // permanently because this hook refuses the sell direction that could undo it.
        // Discriminating an ordinary fill from a short one WITHOUT a second oracle read:
        // on a full fill the market pulls netQuote less at most the floor/ceil inversion
        // residue, so `leftover` can never exceed the spread carve. Anything larger is
        // inventory running out. Ordinary fills therefore keep byte-identical accounting
        // to before this change, and only genuine short fills take the refund path.
        // The bound has TWO parts. The spread carve is one. The other is the market's
        // floor inversion, which discards up to one token-wei of demand; when the rate
        // exceeds RATE_SCALE a single token-wei costs many quote-wei, so that residue can
        // legitimately exceed the carve on a perfectly ordinary full fill. Cost per
        // token-wei is recovered from the returned pair rather than re-read.
        uint256 leftover = quoteIn - quotePaid - spreadAccrued;
        uint256 inversionBound = tokensOut == 0 ? 0 : (quotePaid + tokensOut - 1) / tokensOut;
        if (leftover > quoteIn - netQuote + inversionBound) {
            // Native refunds would need an unwrap path this hook does not have
            // (weth9.deposit is one-way), so native-quote pairs stay all-or-nothing.
            if (input.isAddressZero()) revert PartialFillUnsupportedForNativeQuote();
            poolManager.sync(input);
            IERC20(Currency.unwrap(input)).safeTransfer(address(poolManager), leftover);
            poolManager.settleFor(sender);
        } else {
            dustAccrued = leftover;
        }
        hookDelta = toBeforeSwapDelta((-amountSpecified).toInt128(), -tokensOut.toInt128());
    }

    /// @dev Single market call, single oracle read: buyFromPoolExactOut computes the
    ///      cost inside priceBuy's one read, then calls fundBuy (below) so this hook
    ///      can take exactly that cost from the PoolManager BEFORE the market's
    ///      pull-exact transferFrom — the Phase 0 funding-order fix. All-or-nothing
    ///      is enforced market-side (FillShortfall), so tokensFilled == tokensOut
    ///      whenever this returns. Spread is added ON TOP of the recomputed cost:
    ///      spread = ceil(cost * spreadBps / 10_000), buyer pays cost + spread, and
    ///      the hook takes whatever fundBuy did not already take (the market skips
    ///      the callback when accrued margin sitting on the hook covers the cost; the
    ///      flash-accounting ledger is the ground truth for what was taken, so both
    ///      callback shapes net identically). Rung lookup uses cost (the quote
    ///      notional of an exact-output trade).
    function _buyExactOutput(PairConfig memory cfg, Currency input, Currency output, int256 amountSpecified)
        internal
        returns (uint256 quoteIn, uint256 tokensOut, uint256 spreadAccrued, uint256 dustAccrued, BeforeSwapDelta hookDelta)
    {
        tokensOut = uint256(amountSpecified);
        bool nativeIn = input.isAddressZero();
        // fundBuy receives the MARKET asset (the wrapper, for a native pair); this
        // one-frame flag tells it to take native from the manager and wrap instead
        if (nativeIn) _takeNativeInCallback = true;
        (, uint256 cost) =
            market.buyFromPoolExactOut(cfg.marketPool, cfg.marketAsset, tokensOut, resellerCode, address(this));
        if (nativeIn) _takeNativeInCallback = false;
        uint256 spreadBps = _spreadBps(cfg.baseSpreadBps, Currency.wrap(cfg.marketAsset), cost);
        spreadAccrued = _ceilBps(cost, spreadBps);
        dustAccrued = 0; // exact-output has no carve: cost is exact, spread is exact
        quoteIn = cost + spreadAccrued;
        int256 delta = poolManager.currencyDelta(address(this), input);
        uint256 takenInCallback = delta < 0 ? uint256(-delta) : 0; // cost if fundBuy ran, else 0
        if (quoteIn > takenInCallback) {
            _takeChecked(input, quoteIn - takenInCallback);
            // spread margin (and, when the callback was skipped, the cost too until
            // it was pulled above) is wrapped so margin custody is wrapper-uniform
            if (nativeIn) weth9.deposit{value: quoteIn - takenInCallback}();
        }
        _settle(output, tokensOut);
        hookDelta = toBeforeSwapDelta((-amountSpecified).toInt128(), quoteIn.toInt128());
    }

    // -------------------------------------------------------------------------
    // Funding callback (IFlowstateBuyFunder)
    // -------------------------------------------------------------------------

    /// @notice Funding callback from FlowstateMarket.buyFromPoolExactOut: the market
    ///         has computed the exact band-checked cost inside its single oracle read
    ///         and is about to pull it; take exactly that amount from the PoolManager.
    /// @dev Only the market may call. Safe by construction outside this hook's own
    ///      beforeSwap frame: manager.take reverts outside an unlock, and inside any
    ///      unrelated unlock it creates PoolManager debt on this hook that nothing
    ///      settles, so the transaction reverts — funds cannot be extracted. The
    ///      explicit ManagerReservesExceeded check (scope §2.1) is preserved inside
    ///      the callback via _takeChecked.
    function fundBuy(address quoteAsset, uint256 cost) external {
        if (msg.sender != address(market)) revert NotMarket();
        if (_takeNativeInCallback) {
            // native-quoted pair: the manager owes NATIVE; take it and wrap so the
            // market's pull-exact transferFrom of the wrapper succeeds
            _takeChecked(Currency.wrap(address(0)), cost);
            weth9.deposit{value: cost}();
        } else {
            _takeChecked(Currency.wrap(quoteAsset), cost);
        }
    }

    /// @dev Native arrives from exactly two counterparties: the PoolManager (take)
    ///      and nobody else — weth9.deposit never sends native back. Reject strays
    ///      so accounting never has to explain an unexplained balance.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert UnexpectedNativeSender(msg.sender);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    // -------------------------------------------------------------------------
    // Hook callbacks — not flagged, never called
    // -------------------------------------------------------------------------

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev manager.take needs the PoolManager to physically hold the ERC20 at call
    ///      time; raise the explicit typed revert decided in scope §2.1 so aggregators
    ///      see a clean error at simulation time instead of take()'s implicit one.
    function _takeChecked(Currency currency, uint256 amount) internal {
        uint256 available = currency.balanceOf(address(poolManager));
        if (amount > available) revert ManagerReservesExceeded(currency, amount, available);
        poolManager.take(currency, address(this), amount);
    }

    function _settle(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    /// @dev Config-time only (scope §5): baseSpread must clear the per-chain
    ///      oracle-drift floor and sit under the hard cap. Deliberately NOT checked
    ///      on the hot path — a swap never re-validates config.
    function _checkBaseSpread(uint16 bps) internal view {
        if (bps < baseSpreadFloorBps || bps > MAX_SPREAD_BPS) {
            revert SpreadOutOfRange(bps, baseSpreadFloorBps, MAX_SPREAD_BPS);
        }
    }

    /// @dev Total spread bps: base + size-adjustment rung. First rung whose ceiling
    ///      >= notional applies; above the top ceiling the top rung applies; empty
    ///      schedule contributes zero. Bounded by 2 * MAX_SPREAD_BPS at config time.
    function _spreadBps(uint16 baseBps, Currency quote, uint256 quoteNotional) internal view returns (uint256) {
        SpreadRung[] storage rungs = _sizeRungs[quote];
        uint256 n = rungs.length;
        if (n == 0) return baseBps;
        for (uint256 i = 0; i < n; i++) {
            SpreadRung storage rung = rungs[i];
            if (quoteNotional <= rung.notionalCeiling) return uint256(baseBps) + rung.extraBps;
        }
        return uint256(baseBps) + rungs[n - 1].extraBps;
    }

    /// @dev ceil(amount * bps / 10_000): the spread never undercollects and exceeds
    ///      the exact product by strictly less than one wei.
    function _ceilBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (bps == 0) return 0;
        return (amount * bps + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
    }

    function _sort(Currency a, Currency b) internal pure returns (Currency, Currency) {
        return Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
    }

    function _pairKey(Currency c0, Currency c1) internal pure returns (bytes32) {
        return keccak256(abi.encode(c0, c1));
    }
}
