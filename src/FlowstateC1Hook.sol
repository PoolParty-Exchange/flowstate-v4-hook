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
import {IGen4ListingRegistry, IGen4ListingSettlement, IGen4Pool} from "./interfaces/IGen4Inventory.sol";
import {Gen4Queue} from "./libraries/Gen4Queue.sol";
import {Gen4Accounting} from "./libraries/Gen4Accounting.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    error MarketStateUnverifiable();
    error MarketPoolNotRecognized(address marketPool);
    error MarketInventoryMismatch(address marketPool, address expectedInventory, address actualInventory);
    error MarketQuoteAssetNotApproved(address marketPool, address quoteAsset);
    error UnexpectedNativeSender(address sender);
    error ManagerReservesExceeded(Currency currency, uint256 requested, uint256 available);
    error SpreadOutOfRange(uint16 bps, uint16 floorBps, uint16 maxBps);
    error TradeTooSmallForSpread(uint256 quoteIn, uint256 spreadBps);
    /// @dev JUP-621: cannot happen while the spread setters enforce spread >= jarFeeBps;
    ///      kept as a hard stop so the fee can never be skipped or paid from inventory.
    error JarFeeExceedsSpread(uint256 jarFee, uint256 spreadAccrued);
    error PartialFillUnsupportedForNativeQuote(); // refunding native needs an unwrap path this hook lacks
    error RungScheduleInvalid();
    error SweepDestinationNotSet();
    error EthSweepFailed();
    error ListingWiringMismatch(address registry, address settlement);
    error ListingMarketMismatch(address expected, address registryMarket, address settlementMarket);
    error CandidateInspectionFailed(uint8 source);
    error UnexpectedListingOutcome(uint8 outcome);
    error Gen4FillShortfall(uint256 filled, uint256 requested);
    error Gen4AttemptCapExceeded(uint256 attempts);
    error Gen4InsufficientGas(uint256 remaining, uint256 required);
    /// @notice Exact input stopped (gas, a failed read, a failed leg) before anything filled.
    error Gen4NothingFilled(uint8 reason);

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

    /// @notice JUP-621: Uniswap's TokenJar on this chain. Every fill pays
    ///         `jarFeeBps` of the recomputed oracle cost to it, in the same
    ///         transaction, out of the buyer's spread. Immutable: no setter, no owner
    ///         path, no fill path that skips it. This is the protocol-fee-equivalent
    ///         Uniswap Labs requires of a custom-accounting hook for routing
    ///         allowlisting (the pool manager's own protocol fee never accrues here
    ///         because the hook settles the whole swap).
    address public immutable tokenJar;
    /// @notice Basis points of the recomputed cost paid to `tokenJar` on every fill.
    ///         Every spread this hook can charge is at least this much (see
    ///         _checkBaseSpread, setBaseSpreadFloor, setMarketRegistrationSpread), so
    ///         the fee is always carved from the spread and never changes the price
    ///         the buyer pays.
    uint16 public immutable jarFeeBps;

    /// @notice JUP-697 one-candidate listing endpoints. Both are zero for a
    ///         Gen-3-only deployment; otherwise both are code-bearing and the
    ///         settlement's immutable registry must match.
    IGen4ListingRegistry public immutable listingRegistry;
    IGen4ListingSettlement public immutable listingSettlement;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint256 public constant GEN4_MAX_ATTEMPTS = 16;
    uint256 public constant GEN4_MAX_POOL_NODES = 50;
    /// @notice Kept back for finalisation after the walk (accounting, jar fee, settle, refund).
    uint256 public constant GEN4_FINALIZATION_GAS_RESERVE = 400_000;
    /// @notice Below reserve + this before an attempt, the walk stops: exact input refunds the
    ///         unspent input, exact output reverts. A courtesy stop sized from measurement, not a
    ///         guarantee: on the pinned stack the per-attempt reads (peek, tokenQueueEnds, queue,
    ///         maxBuy; the price is read once per swap) cost ~0.32M cold with one deposit
    ///         (test/stack/read-gas-probe.test.cjs), a smallest pool leg ~0.32M. An under-gassed swap
    ///         may still revert in a read; with nothing filled it reverts anyway (Gen4NothingFilled).
    uint256 public constant GEN4_MIN_ATTEMPT_GAS = 800_000;
    /// @notice Pool leg planning, from EXECUTION gas (eth_estimateGas, before end-of-transaction
    ///         refunds) of the market's bounded buy on the pinned stack
    ///         (test/stack/exec-gas-probe.test.cjs): 326k base + 55.7k per node plain; 414k base +
    ///         109k per node when proceeds recycle into the buy-back (buy-back on in the traded
    ///         asset, owner opted in). Paying a sell-side partner (market supplier registry set,
    ///         JUP-695) adds up to ~134k per node. The hook reads both settings once per swap and
    ///         plans with the matching figure (+~15%), assuming the worst when a read fails. The
    ///         base is the larger of this floor and what the market's own maxBuy cost in this
    ///         swap, since the buy re-runs that venue evaluation. A fully pinned node is only
    ///         stepped over. A leg that still runs out of gas is caught (see _buyGen4ExactInput).
    uint256 public constant GEN4_POOL_LEG_BASE_GAS = 450_000;
    uint256 public constant GEN4_POOL_NODE_GAS = 65_000;
    uint256 public constant GEN4_POOL_NODE_GAS_RECYCLED = 125_000;
    uint256 public constant GEN4_POOL_NODE_GAS_ATTRIBUTED = 220_000;
    uint256 public constant GEN4_POOL_NODE_GAS_ATTRIBUTED_RECYCLED = 280_000;
    uint256 public constant GEN4_POOL_SKIP_GAS = 15_000;
    /// @notice A listing sale measured 0.9M to 1.2M with partner cuts (JUP-697 fork acceptance).
    uint256 public constant GEN4_LISTING_LEG_MIN_GAS = 1_400_000;
    /// @notice Upper bound on the gas forwarded to one leg.
    uint256 public constant GEN4_MAX_LEG_GAS = 10_000_000;
    /// @dev What this frame keeps for itself after a leg returns, beyond the finalisation reserve.
    uint256 internal constant GEN4_LEG_RETURN_GAS = 60_000;
    /// @dev Caps on the queue and listing reads, whose cost is bounded by the 50-node window and
    ///      the registry's own walk bounds (measured cold: peek 90k, tokenQueueEnds 16k, queue 477k).
    ///      maxBuy and price are not held to this cap: they run the venue evaluation, whose cost grows
    ///      with the venue's initialized ticks (review F2: ~19k per tick, 1.57M at 72 ticks), so they
    ///      get the gas that is left (at most GEN4_MAX_LEG_GAS), as the legs do.
    uint256 internal constant GEN4_READ_GAS_LIMIT = 1_000_000;
    uint256 internal constant GEN4_REGISTRY_READ_GAS = 50_000;
    uint8 internal constant STOP_GAS = 1;
    uint8 internal constant STOP_READ = 2;
    uint8 internal constant STOP_POOL_LEG = 3;
    uint8 internal constant STOP_LISTING_LEG = 4;
    uint256 internal constant GEN4_QUEUE_READ_GAS_LIMIT = 1_000_000;

    uint8 internal constant LISTING_EMPTY = 0;
    uint8 internal constant LISTING_AVAILABLE = 1;
    uint8 internal constant LISTING_DEAD = 2;
    uint8 internal constant LISTING_SOLD = 0;
    uint8 internal constant LISTING_SKIPPED = 2;
    uint8 internal constant LISTING_STALE = 3;
    uint8 internal constant LISTING_CLOSED = 4;

    /// @notice Hard cap on baseSpreadBps and on any single rung's extraBps (10%).
    ///         Structural ceiling on the total spread is therefore 2 * MAX_SPREAD_BPS.
    uint16 public constant MAX_SPREAD_BPS = 1_000;

    // -------------------------------------------------------------------------
    // Admin-controlled state
    // -------------------------------------------------------------------------

    /// @dev One fill's accounting, returned by the two fill helpers as a memory struct
    ///      (JUP-621 added a sixth value and the tuple form overflowed the EVM stack).
    struct Fill {
        uint256 quoteIn;
        uint256 tokensOut;
        uint256 spreadAccrued;
        uint256 dustAccrued;
        uint256 costBase;
        BeforeSwapDelta hookDelta;
    }

    struct ListingCandidate {
        uint8 state;
        uint64 id;
        uint256 available;
        uint32 version;
        uint64 poolTail;
    }

    struct PoolCandidate {
        uint64 firstIndex;
        uint256 boundedAvailable;
        uint256 totalAvailable;
        uint256 executable;
        uint64 boundary;
        IGen4Pool.QueueNode[] nodes;
        uint256 legBase;
        bool readFailed;
    }

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

    /// @notice Current floor on baseSpreadBps (the per-chain oracle-drift floor,
    ///         scope §5: 10 bps BSC / 16 bps RH / 23 bps Base — set operationally at
    ///         deploy). Checked when configuring and when testing readiness/executing,
    ///         so raising it lazily disables older below-floor pairs until retuned.
    uint16 public baseSpreadFloorBps;

    /// @notice Spread applied to pairs the trusted Market auto-registers inside
    ///         createPool (JUP-587). 16 bps = launch parity with the manually
    ///         registered CASHCAT/HOODRAT pairs. If the floor is later raised above
    ///         this value the market path self-heals by charging the floor instead
    ///         of reverting inside createPool.
    uint16 public marketRegistrationSpreadBps = 16;

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
    /// @dev quoteIn is the buyer's requested/committed input. On an exact-input short
    ///      fill it is NOT the realised payment: the unspent remainder is returned via
    ///      PoolManager accounting. Join this event to the market's PoolBuy by
    ///      transaction hash; actual charge is quotePaid + spreadAccrued + dustAccrued.
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
    event MarketRegistrationSpreadUpdated(uint16 previous, uint16 current);
    event SizeRungsUpdated(Currency indexed quote, SpreadRung[] rungs);
    event SweepDestinationUpdated(address previous, address current);
    event MarginSwept(
        Currency indexed asset, address indexed to, uint256 spreadPortion, uint256 dustPortion, uint256 swept
    );
    event ETHSwept(address indexed to, uint256 amount);
    /// @notice JUP-621: the TokenJar fee paid on one fill, in the quote asset the
    ///         buyer paid (the wrapper for a native quote).
    event ProtocolFeePaid(PoolId indexed poolId, Currency indexed asset, uint256 amount);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _poolManager canonical PoolManager for this chain.
    /// @param _market      FlowstateMarket (must be non-zero and code-bearing).
    /// @param _owner       admin for the pair registry and reseller code.
    constructor(
        address _poolManager,
        address _market,
        address _owner,
        address _weth9,
        address _tokenJar,
        uint16 _jarFeeBps,
        address _listingRegistry,
        address _listingSettlement
    ) Ownable(_owner) {
        if (_poolManager == address(0) || _market == address(0) || _tokenJar == address(0)) revert ZeroAddress();
        if (_market.code.length == 0) revert ZeroAddress();
        // The jar fee must fit under every spread the hook can charge, and the
        // registration default (16 bps at construction) must clear it too.
        if (_jarFeeBps > MAX_SPREAD_BPS) revert SpreadOutOfRange(_jarFeeBps, 0, MAX_SPREAD_BPS);
        if (marketRegistrationSpreadBps < _jarFeeBps) revert SpreadOutOfRange(marketRegistrationSpreadBps, _jarFeeBps, MAX_SPREAD_BPS);

        poolManager = IPoolManager(_poolManager);
        market = IFlowstateMarketMinimal(_market);
        weth9 = IWETH9(_weth9); // address(0) = native quotes disabled on this chain
        tokenJar = _tokenJar;
        jarFeeBps = _jarFeeBps;
        if ((_listingRegistry == address(0)) != (_listingSettlement == address(0))) {
            revert ListingWiringMismatch(_listingRegistry, _listingSettlement);
        }
        if (_listingRegistry != address(0)) {
            if (_listingRegistry.code.length == 0 || _listingSettlement.code.length == 0) {
                revert ListingWiringMismatch(_listingRegistry, _listingSettlement);
            }
            if (IGen4ListingSettlement(_listingSettlement).registry() != _listingRegistry) {
                revert ListingWiringMismatch(_listingRegistry, _listingSettlement);
            }
            // both directions: the settlement this hook approves must be the one the registry is bound to
            if (IGen4ListingRegistry(_listingRegistry).settlement() != _listingSettlement) {
                revert ListingWiringMismatch(_listingRegistry, _listingSettlement);
            }
            address registryMarket = IGen4ListingRegistry(_listingRegistry).market();
            address settlementMarket = IGen4ListingSettlement(_listingSettlement).market();
            if (registryMarket != _market || settlementMarket != _market) {
                revert ListingMarketMismatch(_market, registryMarket, settlementMarket);
            }
        }
        listingRegistry = IGen4ListingRegistry(_listingRegistry);
        listingSettlement = IGen4ListingSettlement(_listingSettlement);

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
    ///         The Market registry must recognize marketPool, bind it to token, and
    ///         currently approve the resolved ERC-20 quote asset.
    ///         Grants the market a standing quote-asset allowance so the pull-exact
    ///         transferFrom never pays approval gas on the hot path. baseSpreadBps is
    ///         floor- and cap-checked both here and by the shared readiness gate.
    function registerPair(Currency quote, Currency token, address marketPool, uint16 baseSpreadBps)
        external
        onlyOwner
    {
        if (marketPool == address(0)) revert ZeroAddress();
        _checkBaseSpread(baseSpreadBps);
        _registerPair(quote, token, marketPool, baseSpreadBps);
    }

    /// @notice Market-trusted auto-registration fired inside createPool (JUP-587;
    ///         Wilko GO 24 Aug: deliberately narrow — no venue discovery, no oracle
    ///         feed work, ERC-20 quotes only). IDEMPOTENT: an already-registered
    ///         pair is left untouched, however it is tuned, so a market call can
    ///         never clobber owner configuration. Spread = the configured market
    ///         registration spread, floored at baseSpreadFloorBps so a later floor
    ///         raise degrades to a wider spread instead of a createPool-time revert.
    function registerPairFromMarket(Currency quote, Currency token, address marketPool) external {
        if (msg.sender != address(market)) revert NotMarket();
        if (quote.isAddressZero()) revert NativeQuoteUnsupported();
        if (marketPool == address(0)) revert ZeroAddress();
        (Currency s0, Currency s1) = _sort(quote, token);
        if (pairs[_pairKey(s0, s1)].registered) return;
        uint16 spread = marketRegistrationSpreadBps;
        uint16 floor = baseSpreadFloorBps;
        if (spread < floor) spread = floor;
        _registerPair(quote, token, marketPool, spread);
    }

    function _registerPair(Currency quote, Currency token, address marketPool, uint16 baseSpreadBps) internal {
        // native quote (v1 decision, 2026-07-30): served by wrapping into weth9, so
        // the market-side asset for a native pair IS the wrapper
        address marketAsset;
        if (quote.isAddressZero()) {
            if (address(weth9) == address(0)) revert NativeQuoteUnsupported();
            marketAsset = address(weth9);
        } else {
            marketAsset = Currency.unwrap(quote);
        }
        _validateMarketWiring(marketPool, Currency.unwrap(token), marketAsset);
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
        if (address(listingSettlement) != address(0)) {
            IERC20(marketAsset).forceApprove(address(listingSettlement), type(uint256).max);
        }
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

    /// @notice Set the per-chain oracle-drift floor for baseSpreadBps. Existing pairs
    ///         below a raised floor retain their configured spread but become non-ready
    ///         and non-executable until the owner retunes them.
    function setBaseSpreadFloor(uint16 floorBps) external onlyOwner {
        if (floorBps > MAX_SPREAD_BPS) revert SpreadOutOfRange(floorBps, 0, MAX_SPREAD_BPS);
        // JUP-621: the floor is only a floor on top of the jar fee; a lower floor would
        // let setBaseSpread admit a spread that cannot carry the fee.
        if (floorBps < jarFeeBps) revert SpreadOutOfRange(floorBps, jarFeeBps, MAX_SPREAD_BPS);
        emit BaseSpreadFloorUpdated(baseSpreadFloorBps, floorBps);
        baseSpreadFloorBps = floorBps;
    }

    /// @notice Retune the spread used by market auto-registration (JUP-587).
    ///         Already-registered pairs are untouched (retune those per-pair via
    ///         setBaseSpread). Bounded by the hard cap only; the floor is applied
    ///         lazily at registration time so this can never make createPool revert.
    function setMarketRegistrationSpread(uint16 bps) external onlyOwner {
        if (bps > MAX_SPREAD_BPS) revert SpreadOutOfRange(bps, 0, MAX_SPREAD_BPS);
        if (bps < jarFeeBps) revert SpreadOutOfRange(bps, jarFeeBps, MAX_SPREAD_BPS); // JUP-621
        emit MarketRegistrationSpreadUpdated(marketRegistrationSpreadBps, bps);
        marketRegistrationSpreadBps = bps;
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
        Currency held = asset.isAddressZero() ? Currency.wrap(address(weth9)) : asset;
        uint256 spreadPortion = accruedSpreadMargin[held];
        uint256 dustPortion = accruedDust[held];
        accruedSpreadMargin[held] = 0;
        accruedDust[held] = 0;
        swept = IERC20(Currency.unwrap(held)).balanceOf(address(this));
        if (swept != 0) IERC20(Currency.unwrap(held)).safeTransfer(to, swept);
        emit MarginSwept(held, to, spreadPortion, dustPortion, swept);
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

    /// @notice Whether the pair is registered, at or above the current spread floor,
    ///         and still coherently wired to the Market's canonical pool registry and
    ///         current quote-asset approval state. Returns false if Market reads fail.
    function isPairReady(Currency currencyA, Currency currencyB) external view returns (bool) {
        (Currency c0, Currency c1) = _sort(currencyA, currencyB);
        PairConfig memory cfg = pairs[_pairKey(c0, c1)];
        if (!cfg.registered || cfg.baseSpreadBps < baseSpreadFloorBps || cfg.baseSpreadBps > MAX_SPREAD_BPS) {
            return false;
        }
        Currency inventory = cfg.quoteIsCurrency0 ? c1 : c0;
        (MarketWiringStatus status,) = _marketWiringStatus(cfg.marketPool, Currency.unwrap(inventory), cfg.marketAsset);
        return status == MarketWiringStatus.Valid;
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
        _requirePairReady(cfg, c0, c1);
        return _spreadBps(cfg.baseSpreadBps, Currency.wrap(cfg.marketAsset), quoteNotional);
    }

    // -------------------------------------------------------------------------
    // Hook callbacks — implemented
    // -------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (key.fee != 0) revert LpFeeMustBeZero();
        _requirePairReady(pairs[_pairKey(key.currency0, key.currency1)], key.currency0, key.currency1);
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
        _requirePairReady(cfg, key.currency0, key.currency1);

        (Currency input, Currency output) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        Currency quote = cfg.quoteIsCurrency0 ? key.currency0 : key.currency1;
        if (Currency.unwrap(input) != Currency.unwrap(quote)) revert SellDirectionNotSupported();

        bool exactInput = params.amountSpecified < 0;
        Fill memory f;
        if (address(listingSettlement) == address(0)) {
            f = exactInput
                ? _buyExactInput(cfg, input, output, params.amountSpecified, sender)
                : _buyExactOutput(cfg, input, output, params.amountSpecified);
        } else {
            f = exactInput
                ? _buyGen4ExactInput(cfg, input, output, params.amountSpecified, sender)
                : _buyGen4ExactOutput(cfg, input, output, params.amountSpecified);
        }

        // JUP-621: pay Uniswap's TokenJar its fee on this fill, out of the spread. The
        // fee base is the recomputed oracle cost the market actually charged
        // (quotePaid / cost), the same base the spread is computed on, so
        // jarFee <= spreadAccrued always holds (spreadBps >= jarFeeBps is enforced by
        // every spread setter). Paid before the margin is booked, in the asset the hook
        // is holding (the wrapper for a native quote), inside the swap itself.
        f.spreadAccrued = _payJar(key.toId(), input, f.costBase, f.spreadAccrued);
        Currency heldInput = input.isAddressZero() ? Currency.wrap(address(weth9)) : input;
        if (f.spreadAccrued != 0) accruedSpreadMargin[heldInput] += f.spreadAccrued;
        if (f.dustAccrued != 0) accruedDust[heldInput] += f.dustAccrued;

        emit BuyExecuted(key.toId(), quote, output, f.quoteIn, f.tokensOut, exactInput, f.spreadAccrued, f.dustAccrued);
        return (IHooks.beforeSwap.selector, f.hookDelta, 0);
    }

    /// @dev JUP-621: pay the TokenJar its fee for this fill and return the spread the
    ///      hook keeps. Paid in the asset the hook holds (the wrapper for a native quote).
    function _payJar(PoolId poolId, Currency input, uint256 costBase, uint256 spreadAccrued)
        internal
        returns (uint256 spreadLeft)
    {
        uint256 jarFee = _ceilBps(costBase, jarFeeBps);
        if (jarFee == 0) return spreadAccrued;
        if (jarFee > spreadAccrued) revert JarFeeExceedsSpread(jarFee, spreadAccrued);
        Currency held = input.isAddressZero() ? Currency.wrap(address(weth9)) : input;
        IERC20(Currency.unwrap(held)).safeTransfer(tokenJar, jarFee);
        emit ProtocolFeePaid(poolId, held, jarFee);
        return spreadAccrued - jarFee;
    }

    /// @dev exactInput spread carve: the swapper's specified quoteIn is taken into
    ///      the hook, while the market is committed netQuote = floor(quoteIn *
    ///      10_000 / (10_000 + spreadBps)) — floored so the carve can never eat into
    ///      what the spread is owed — and prices tokens on that remainder. The spread
    ///      then accrues on the RECOMPUTED oracle cost the market actually pulled
    ///      (quotePaid <= netQuote), as ceil(quotePaid * spreadBps / 10_000): never
    ///      undercollects, exceeds the exact bps product by < 1 wei. Whatever is left
    ///      of quoteIn on an ordinary full fill (carve residue + the market's
    ///      floor/ceil inversion dust) is accounted separately as dust, never folded
    ///      into spread margin. A short fill returns its unspent remainder below.
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
        returns (Fill memory f)
    {
        f.quoteIn = uint256(-amountSpecified);
        uint256 spreadBps = _spreadBps(cfg.baseSpreadBps, Currency.wrap(cfg.marketAsset), f.quoteIn);
        uint256 netQuote = spreadBps == 0 ? f.quoteIn : f.quoteIn * BPS_DENOMINATOR / (BPS_DENOMINATOR + spreadBps);
        // Sub-dust ticket: the carve leaves the market nothing to price. Raise the
        // explicit typed error rather than letting FlowstatePool's InvalidAmount
        // surface for a hook-caused condition (same posture as ManagerReservesExceeded,
        // §2.1).
        if (netQuote == 0) revert TradeTooSmallForSpread(f.quoteIn, spreadBps);
        _takeChecked(input, f.quoteIn);
        // native quote: wrap the WHOLE take (cost + spread + dust) so accrued margin
        // is held uniformly in the wrapper and the sweep path stays ERC-20-only
        if (input.isAddressZero()) weth9.deposit{value: f.quoteIn}();
        uint256 quotePaid;
        (f.tokensOut, quotePaid) =
            market.buyFromPoolExactQuote(cfg.marketPool, cfg.marketAsset, netQuote, resellerCode, address(this));
        _settle(output, f.tokensOut);
        f.spreadAccrued = _ceilBps(quotePaid, spreadBps);
        f.costBase = quotePaid; // JUP-621: the jar fee is computed on the same base as the spread

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
        // Discriminating an ordinary fill from a short one WITHOUT a second oracle read.
        //
        // Compare against netQuote, which is what the market was actually asked to price.
        // On a full fill the market inverts netQuote DOWN to whole token-wei and charges
        // the exact cost of those, so the unspent remainder is strictly less than the cost
        // of one token-wei. Anything at or above that is inventory running out.
        //
        //   full fill:  f.tokensOut = floor(netQuote / p),  quotePaid = ceil(f.tokensOut * p)
        //               => netQuote - quotePaid < p <= ceil(quotePaid / f.tokensOut)
        //
        // The per-token-wei cost is recovered from the returned pair rather than re-read,
        // so this tracks the rate the market ACTUALLY used, including the anchor and the
        // staleness surcharge, neither of which this hook can see directly.
        //
        // Do NOT widen this by f.spreadAccrued. An earlier revision compared `leftover`
        // against `f.quoteIn - netQuote + inversionBound`, which cancels to
        // `netQuote - quotePaid > f.spreadAccrued + inversionBound` and therefore treated a
        // genuine shortfall of up to the whole spread as ordinary dust, silently keeping
        // it. Regression pinned in test/fork/UniversalRouterPartialFill.t.sol.
        uint256 leftover = f.quoteIn - quotePaid - f.spreadAccrued;
        uint256 inversionBound = f.tokensOut == 0 ? 0 : (quotePaid + f.tokensOut - 1) / f.tokensOut;
        if (netQuote - quotePaid > inversionBound) {
            // Native refunds would need an unwrap path this hook does not have
            // (weth9.deposit is one-way), so native-quote pairs stay all-or-nothing.
            if (input.isAddressZero()) revert PartialFillUnsupportedForNativeQuote();
            poolManager.sync(input);
            IERC20(Currency.unwrap(input)).safeTransfer(address(poolManager), leftover);
            poolManager.settleFor(sender);
        } else {
            f.dustAccrued = leftover;
        }
        f.hookDelta = toBeforeSwapDelta((-amountSpecified).toInt128(), -f.tokensOut.toInt128());
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
        returns (Fill memory f)
    {
        f.tokensOut = uint256(amountSpecified);
        bool nativeIn = input.isAddressZero();
        // fundBuy receives the MARKET asset (the wrapper, for a native pair); this
        // one-frame flag tells it to take native from the manager and wrap instead
        if (nativeIn) _takeNativeInCallback = true;
        (, uint256 cost) =
            market.buyFromPoolExactOut(cfg.marketPool, cfg.marketAsset, f.tokensOut, resellerCode, address(this));
        if (nativeIn) _takeNativeInCallback = false;
        uint256 spreadBps = _spreadBps(cfg.baseSpreadBps, Currency.wrap(cfg.marketAsset), cost);
        f.spreadAccrued = _ceilBps(cost, spreadBps);
        f.dustAccrued = 0; // exact-output has no carve: cost is exact, spread is exact
        f.costBase = cost; // JUP-621
        f.quoteIn = cost + f.spreadAccrued;
        int256 delta = poolManager.currencyDelta(address(this), input);
        uint256 takenInCallback = delta < 0 ? uint256(-delta) : 0; // cost if fundBuy ran, else 0
        if (f.quoteIn > takenInCallback) {
            _takeChecked(input, f.quoteIn - takenInCallback);
            // spread margin (and, when the callback was skipped, the cost too until
            // it was pulled above) is wrapped so margin custody is wrapper-uniform
            if (nativeIn) weth9.deposit{value: f.quoteIn - takenInCallback}();
        }
        _settle(output, f.tokensOut);
        f.hookDelta = toBeforeSwapDelta((-amountSpecified).toInt128(), f.quoteIn.toInt128());
    }

    // -------------------------------------------------------------------------
    // Gen-4 mixed pool/listing lane (JUP-698)
    // -------------------------------------------------------------------------

    /// @dev Exact input takes the committed amount once, then spends only the
    ///      spread-adjusted budget across globally ordered legs. Every successful
    ///      source records its returned amounts; an unsuccessful listing records
    ///      no cost. Exhaustion/cap/gas reserve returns all unspent input, while a
    ///      sub-token remainder after otherwise executable inventory remains Gen-3
    ///      inversion dust.
    function _buyGen4ExactInput(
        PairConfig memory cfg,
        Currency input,
        Currency output,
        int256 amountSpecified,
        address sender
    ) internal returns (Fill memory f) {
        f.quoteIn = uint256(-amountSpecified);
        uint256 spreadBps = _spreadBps(cfg.baseSpreadBps, Currency.wrap(cfg.marketAsset), f.quoteIn);
        uint256 budget = spreadBps == 0
            ? f.quoteIn
            : f.quoteIn * BPS_DENOMINATOR / (BPS_DENOMINATOR + spreadBps);
        if (budget == 0) revert TradeTooSmallForSpread(f.quoteIn, spreadBps);

        _takeChecked(input, f.quoteIn);
        if (input.isAddressZero()) weth9.deposit{value: f.quoteIn}();

        Gen4Accounting.Totals memory totals;
        uint256 attempts;
        bool refundUnused;
        bool done;
        address token = Currency.unwrap(output);
        uint256 nodeGas = _poolNodeGas(cfg);
        (bool priceRead, uint8 priceWhy, uint256 priceRate) = _readPrice(token, cfg.marketAsset);
        if (!priceRead) _softStop(totals, STOP_READ); // nothing has filled yet: reverts
        // a closed swap route sells nothing from either source (the settlement would answer CLOSED)
        if (priceWhy != 0) {
            refundUnused = true;
            done = true;
        }

        while (!done && attempts < GEN4_MAX_ATTEMPTS) {
            if (gasleft() < GEN4_FINALIZATION_GAS_RESERVE + GEN4_MIN_ATTEMPT_GAS) {
                _softStop(totals, STOP_GAS);
                refundUnused = true;
                break;
            }
            ListingCandidate memory listing = _inspectListing(token);
            PoolCandidate memory pool = _inspectPool(cfg, listing);
            if (pool.readFailed) {
                _softStop(totals, STOP_READ);
                refundUnused = true;
                break;
            }
            bool hasListing = listing.state != LISTING_EMPTY;
            uint256 poolCap = hasListing ? pool.boundedAvailable : pool.totalAvailable;
            if (poolCap > pool.executable) poolCap = pool.executable;
            Gen4Queue.Source source = Gen4Queue.select(poolCap != 0, pool.firstIndex, hasListing, listing.poolTail);
            if (source == Gen4Queue.Source.None) {
                refundUnused = true;
                break;
            }

            ++attempts;
            uint256 remainingBudget = budget - (totals.poolQuote + totals.listingQuote);
            uint256 legGas = _legGas();
            if (source == Gen4Queue.Source.Pool) {
                // never more nodes than the gas this leg can be given will walk
                uint256 sized = _poolLegSize(pool, legGas, nodeGas);
                if (sized == 0) {
                    _softStop(totals, STOP_GAS);
                    refundUnused = true;
                    break;
                }
                if (sized < poolCap) poolCap = sized;
                uint256 amount = _affordable(poolCap, remainingBudget, priceRate);
                if (amount == 0) break;
                // A leg that reverts or runs out of gas is rolled back inside the market. After a
                // partial fill the walk stops and refunds the rest; with nothing filled the swap
                // reverts (_softStop). Gas is re-read at the call (Robin pass 57).
                try market.buyFromPoolBounded{gas: _legGas()}(
                    cfg.marketPool,
                    cfg.marketAsset,
                    amount,
                    resellerCode,
                    address(this),
                    remainingBudget,
                    0,
                    0
                ) returns (uint256 poolTokens, uint256 poolQuote) {
                    if (poolTokens == 0) {
                        refundUnused = true;
                        break;
                    }
                    Gen4Accounting.recordPool(totals, poolTokens, poolQuote);
                } catch {
                    _softStop(totals, STOP_POOL_LEG);
                    refundUnused = true;
                    break;
                }
                continue;
            }

            if (legGas < GEN4_LISTING_LEG_MIN_GAS) {
                _softStop(totals, STOP_GAS);
                refundUnused = true;
                break;
            }
            uint256 maxAmount = listing.state == LISTING_DEAD
                ? 1
                : _affordable(listing.available, remainingBudget, priceRate);
            if (maxAmount == 0) break;
            uint256 maxQuote = listing.state == LISTING_DEAD ? 0 : _quoteFor(maxAmount, priceRate);
            try listingSettlement.settleHead{gas: _legGas()}(
                token,
                listing.id,
                listing.version,
                maxAmount,
                cfg.marketAsset,
                maxQuote,
                address(this),
                resellerCode,
                0
            ) returns (uint8 outcome, uint64 actualId, uint256 listingTokens, uint256 listingQuote) {
                if (outcome == LISTING_SOLD) {
                    if (actualId != listing.id || listingTokens == 0 || listingQuote > maxQuote) {
                        revert UnexpectedListingOutcome(outcome);
                    }
                    Gen4Accounting.recordListingAttempt(totals, GEN4_MAX_ATTEMPTS, true, listingTokens, listingQuote);
                } else if (outcome == LISTING_SKIPPED || outcome == LISTING_STALE) {
                    Gen4Accounting.recordListingAttempt(totals, GEN4_MAX_ATTEMPTS, false, 0, 0);
                } else if (outcome == LISTING_CLOSED) {
                    Gen4Accounting.recordListingAttempt(totals, GEN4_MAX_ATTEMPTS, false, 0, 0);
                    refundUnused = true;
                    done = true;
                } else {
                    revert UnexpectedListingOutcome(outcome);
                }
            } catch {
                // a listing sale that reverts is rolled back by the settlement: as a failed pool leg
                _softStop(totals, STOP_LISTING_LEG);
                refundUnused = true;
                break;
            }
        }

        if (!done && attempts == GEN4_MAX_ATTEMPTS) refundUnused = true;
        uint256 cost = totals.poolQuote + totals.listingQuote;
        uint256 spread = _ceilBps(cost, spreadBps);
        uint256 refund = refundUnused ? f.quoteIn - cost - spread : 0;
        Gen4Accounting.Final memory result =
            Gen4Accounting.exactInput(totals, f.quoteIn, spreadBps, jarFeeBps, refund);
        if (result.refund != 0) _refundInput(input, sender, result.refund);
        if (result.tokensOut != 0) _settle(output, result.tokensOut);

        f.tokensOut = result.tokensOut;
        f.spreadAccrued = result.spread;
        f.dustAccrued = result.dust;
        f.costBase = result.cost;
        f.hookDelta = toBeforeSwapDelta((-amountSpecified).toInt128(), -f.tokensOut.toInt128());
    }

    /// @dev Exact output caps every leg by the remaining target. Pool and listing
    ///      calls are pre-funded at the same previewed rate used by JUP-697; any
    ///      typed unsuccessful listing outcome refunds that pre-funding before both
    ///      sources are inspected again. Failure to reach the target reverts the
    ///      whole unlock, so no partial exact-output debt can survive.
    function _buyGen4ExactOutput(
        PairConfig memory cfg,
        Currency input,
        Currency output,
        int256 amountSpecified
    ) internal returns (Fill memory f) {
        uint256 target = uint256(amountSpecified);
        Gen4Accounting.Totals memory totals;
        uint256 attempts;
        address token = Currency.unwrap(output);
        uint256 nodeGas = _poolNodeGas(cfg);
        (bool priceRead, uint8 priceWhy, uint256 priceRate) = _readPrice(token, cfg.marketAsset);
        if (!priceRead) revert CandidateInspectionFailed(uint8(Gen4Queue.Source.Pool));

        // a closed swap route (priceWhy != 0) sells nothing: the shortfall check below reverts
        while (priceWhy == 0 && Gen4Accounting.remainingOutput(totals, target) != 0 && attempts < GEN4_MAX_ATTEMPTS) {
            uint256 requiredGas = GEN4_FINALIZATION_GAS_RESERVE + GEN4_MIN_ATTEMPT_GAS;
            if (gasleft() < requiredGas) revert Gen4InsufficientGas(gasleft(), requiredGas);
            ListingCandidate memory listing = _inspectListing(token);
            PoolCandidate memory pool = _inspectPool(cfg, listing);
            if (pool.readFailed) revert CandidateInspectionFailed(uint8(Gen4Queue.Source.Pool));
            bool hasListing = listing.state != LISTING_EMPTY;
            uint256 poolCap = hasListing ? pool.boundedAvailable : pool.totalAvailable;
            if (poolCap > pool.executable) poolCap = pool.executable;
            Gen4Queue.Source source = Gen4Queue.select(poolCap != 0, pool.firstIndex, hasListing, listing.poolTail);
            if (source == Gen4Queue.Source.None) break;

            ++attempts;
            uint256 remaining = Gen4Accounting.remainingOutput(totals, target);
            uint256 legGas = _legGas();
            if (source == Gen4Queue.Source.Pool) {
                uint256 sized = _poolLegSize(pool, legGas, nodeGas);
                if (sized == 0) break;
                if (sized < poolCap) poolCap = sized;
                uint256 amount = poolCap < remaining ? poolCap : remaining;
                uint256 poolPrefund = _quoteFor(amount, priceRate);
                _prefundInput(input, poolPrefund);
                try market.buyFromPoolBounded{gas: _legGas()}(
                    cfg.marketPool,
                    cfg.marketAsset,
                    amount,
                    resellerCode,
                    address(this),
                    poolPrefund,
                    0,
                    0
                ) returns (uint256 poolTokens, uint256 poolQuote) {
                    if (poolQuote > poolPrefund || poolTokens == 0) revert Gen4FillShortfall(poolTokens, amount);
                    if (poolPrefund > poolQuote) _returnPrefund(input, poolPrefund - poolQuote);
                    Gen4Accounting.recordPool(totals, poolTokens, poolQuote);
                } catch {
                    // rolled back inside the market; the shortfall check below reverts the swap
                    _returnPrefund(input, poolPrefund);
                    break;
                }
                continue;
            }

            if (legGas < GEN4_LISTING_LEG_MIN_GAS) break;
            uint256 maxAmount = listing.state == LISTING_DEAD
                ? 1
                : (listing.available < remaining ? listing.available : remaining);
            uint256 listingPrefund = listing.state == LISTING_DEAD ? 0 : _quoteFor(maxAmount, priceRate);
            if (listingPrefund != 0) _prefundInput(input, listingPrefund);
            try listingSettlement.settleHead{gas: _legGas()}(
                token,
                listing.id,
                listing.version,
                maxAmount,
                cfg.marketAsset,
                listingPrefund,
                address(this),
                resellerCode,
                0
            ) returns (uint8 outcome, uint64 actualId, uint256 listingTokens, uint256 listingQuote) {
                if (outcome == LISTING_SOLD) {
                    if (actualId != listing.id || listingTokens == 0 || listingQuote > listingPrefund) {
                        revert UnexpectedListingOutcome(outcome);
                    }
                    if (listingPrefund > listingQuote) _returnPrefund(input, listingPrefund - listingQuote);
                    Gen4Accounting.recordListingAttempt(totals, GEN4_MAX_ATTEMPTS, true, listingTokens, listingQuote);
                } else if (
                    outcome == LISTING_SKIPPED || outcome == LISTING_STALE || outcome == LISTING_CLOSED
                ) {
                    if (listingPrefund != 0) _returnPrefund(input, listingPrefund);
                    Gen4Accounting.recordListingAttempt(totals, GEN4_MAX_ATTEMPTS, false, 0, 0);
                    if (outcome == LISTING_CLOSED) break;
                } else {
                    revert UnexpectedListingOutcome(outcome);
                }
            } catch {
                if (listingPrefund != 0) _returnPrefund(input, listingPrefund);
                break;
            }
        }

        uint256 filled = totals.poolTokens + totals.listingTokens;
        if (filled != target) {
            if (attempts == GEN4_MAX_ATTEMPTS) revert Gen4AttemptCapExceeded(attempts);
            revert Gen4FillShortfall(filled, target);
        }
        Gen4Accounting.Final memory result =
            Gen4Accounting.exactOutput(totals, _spreadBps(cfg.baseSpreadBps, Currency.wrap(cfg.marketAsset), totals.poolQuote + totals.listingQuote), jarFeeBps);
        if (result.spread != 0) _prefundInput(input, result.spread);
        _settle(output, result.tokensOut);

        f.quoteIn = result.charged;
        f.tokensOut = result.tokensOut;
        f.spreadAccrued = result.spread;
        f.costBase = result.cost;
        f.hookDelta = toBeforeSwapDelta((-amountSpecified).toInt128(), f.quoteIn.toInt128());
    }

    function _inspectListing(address token) internal view returns (ListingCandidate memory c) {
        try listingRegistry.peek{gas: GEN4_READ_GAS_LIMIT}(token) returns (
            uint8 state,
            uint64 id,
            uint64,
            uint256 available,
            uint32 version,
            uint64 poolTail
        ) {
            if (state > LISTING_DEAD || (state == LISTING_EMPTY) != (id == 0)) {
                revert CandidateInspectionFailed(uint8(Gen4Queue.Source.Listing));
            }
            c = ListingCandidate(state, id, available, version, poolTail);
        } catch {
            revert CandidateInspectionFailed(uint8(Gen4Queue.Source.Listing));
        }
    }

    function _inspectPool(PairConfig memory cfg, ListingCandidate memory listing)
        internal
        view
        returns (PoolCandidate memory c)
    {
        uint64 head;
        try IGen4Pool(cfg.marketPool).tokenQueueEnds{gas: GEN4_READ_GAS_LIMIT}() returns (uint64 h, uint64) {
            head = h;
        } catch {
            revert CandidateInspectionFailed(uint8(Gen4Queue.Source.Pool));
        }
        IGen4Pool.QueueNode[] memory nodes;
        try IGen4Pool(cfg.marketPool).queue{gas: GEN4_QUEUE_READ_GAS_LIMIT}(GEN4_MAX_POOL_NODES) returns (
            IGen4Pool.QueueNode[] memory readNodes
        ) {
            nodes = readNodes;
        } catch {
            revert CandidateInspectionFailed(uint8(Gen4Queue.Source.Pool));
        }
        if ((head == 0) != (nodes.length == 0) || (nodes.length != 0 && nodes[0].index != head)) {
            revert CandidateInspectionFailed(uint8(Gen4Queue.Source.Pool));
        }
        uint64 boundary = listing.state == LISTING_EMPTY ? type(uint64).max : listing.poolTail;
        (c.firstIndex, c.boundedAvailable, c.totalAvailable) = Gen4Queue.inspect(nodes, boundary);
        c.boundary = boundary;
        c.nodes = nodes;

        // maxBuy runs the venue evaluation (review F2): it gets the gas that is left, and a failure is
        // reported to the caller (exact input stops or reverts, exact output reverts)
        uint256 marketMax;
        uint256 before = gasleft();
        try market.maxBuy{gas: _legGas()}(cfg.marketPool, cfg.marketAsset) returns (uint256 maxTokens, uint256) {
            marketMax = maxTokens;
        } catch {
            c.readFailed = true;
            return c;
        }
        // the market's bounded buy re-runs this evaluation (warm): use what it cost here as an estimate
        // of the leg's base, never below the measured floor; a leg that still runs short is caught
        uint256 spent = before - gasleft();
        c.legBase = spent > GEN4_POOL_LEG_BASE_GAS ? spent : GEN4_POOL_LEG_BASE_GAS;
        c.executable = c.totalAvailable < marketMax ? c.totalAvailable : marketMax;
    }

    /// @dev Gas to forward to one leg or venue read: everything but the finalisation reserve and what
    ///      this frame needs once the call returns, capped. Read it at the call site: the callee gets at
    ///      most this (EIP-150 only binds when it exceeds 63/64 of what is left), so after a callee
    ///      that runs out of gas this frame keeps the reserve plus the return allowance, less what it
    ///      spent between this read and the call.
    function _legGas() internal view returns (uint256 g) {
        uint256 keep = GEN4_FINALIZATION_GAS_RESERVE + GEN4_LEG_RETURN_GAS;
        uint256 left = gasleft();
        if (left <= keep) return 0;
        g = left - keep;
        if (g > GEN4_MAX_LEG_GAS) g = GEN4_MAX_LEG_GAS;
    }

    /// @dev Tokens a pool leg may take within `legGas`: the executable inventory of the inspected
    ///      nodes at or below the boundary, in queue order, up to what the walk can afford.
    function _poolLegSize(PoolCandidate memory pool, uint256 legGas, uint256 nodeGas) internal pure returns (uint256) {
        if (legGas <= pool.legBase) return 0;
        return Gen4Queue.sizeForGas(pool.nodes, pool.boundary, legGas - pool.legBase, nodeGas, GEN4_POOL_SKIP_GAS);
    }

    /// @dev Per-node planning gas for this swap, from two settings read once: whether the market pays
    ///      sell-side partners (supplier registry set) and whether proceeds can recycle into this
    ///      pool's buy-back (buy-back on with the traded asset). A getter that reverts or runs out of
    ///      gas counts as on. Malformed return data from a getter reverts in this frame (try/catch does
    ///      not cover decoding): the market and pool are FlowState's own contracts, fixed at pair
    ///      registration and upgraded only through the timelock (Robin pass 58).
    function _poolNodeGas(PairConfig memory cfg) internal view returns (uint256) {
        bool attributed = true;
        try market.supplierRegistry{gas: GEN4_REGISTRY_READ_GAS}() returns (address registry) {
            attributed = registry != address(0);
        } catch {}
        bool recycled = true;
        try IGen4Pool(cfg.marketPool).buyBackEnabled{gas: GEN4_REGISTRY_READ_GAS}() returns (bool enabled) {
            if (!enabled) {
                recycled = false;
            } else {
                try IGen4Pool(cfg.marketPool).buybackAsset{gas: GEN4_REGISTRY_READ_GAS}() returns (address asset) {
                    recycled = asset == cfg.marketAsset;
                } catch {}
            }
        } catch {}
        if (attributed) return recycled ? GEN4_POOL_NODE_GAS_ATTRIBUTED_RECYCLED : GEN4_POOL_NODE_GAS_ATTRIBUTED;
        return recycled ? GEN4_POOL_NODE_GAS_RECYCLED : GEN4_POOL_NODE_GAS;
    }

    /// @dev The swap route's price, read once per swap (Hamish, 26 Sep 2026). It is the passive rule of
    ///      the pool's registered venue, which this swap does not trade: pool legs and listing sales move
    ///      neither the venue nor anything else the rule prices from, and no admin call can land inside
    ///      the swap. Each leg still prices itself at execution and is bounded by what the hook offers
    ///      (maxCost, maxQuoteIn), so a moved price fails that leg, which is caught. The read runs the
    ///      venue evaluation, so it gets the gas that is left (review F2).
    function _readPrice(address token, address asset) internal view returns (bool ok, uint8 why, uint256 rate) {
        try listingSettlement.price{gas: _legGas()}(token, asset) returns (uint8 w, uint256 r) {
            return (true, w, r);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Exact input: a stop caused by gas, a failed read or a failed leg keeps what already filled
    ///      and refunds the rest, but with NOTHING filled it reverts, so an under-gassed swap fails
    ///      loudly and gas estimators search upward instead of settling on a limit that buys nothing
    ///      (review F3).
    function _softStop(Gen4Accounting.Totals memory totals, uint8 reason) internal pure {
        if (totals.poolTokens + totals.listingTokens == 0) revert Gen4NothingFilled(reason);
    }

    function _affordable(uint256 available, uint256 budget, uint256 rate) internal pure returns (uint256 amount) {
        if (rate == 0) return 0;
        amount = Math.mulDiv(budget, 1e18, rate);
        if (amount > available) amount = available;
    }

    function _quoteFor(uint256 amount, uint256 rate) internal pure returns (uint256) {
        return Math.mulDiv(amount, rate, 1e18, Math.Rounding.Ceil);
    }

    function _prefundInput(Currency input, uint256 amount) internal {
        _takeChecked(input, amount);
        if (input.isAddressZero()) weth9.deposit{value: amount}();
    }

    function _refundInput(Currency input, address recipient, uint256 amount) internal {
        if (input.isAddressZero()) {
            weth9.withdraw(amount);
            poolManager.settleFor{value: amount}(recipient);
        } else {
            poolManager.sync(input);
            IERC20(Currency.unwrap(input)).safeTransfer(address(poolManager), amount);
            poolManager.settleFor(recipient);
        }
    }

    /// @dev Return an exact-output leg's unused pre-funding to this hook's own
    ///      PoolManager delta. The swapper is charged only by the final returned
    ///      hook delta, so crediting the caller here would leave the hook itself in
    ///      debt and make the unlock fail.
    function _returnPrefund(Currency input, uint256 amount) internal {
        if (input.isAddressZero()) {
            weth9.withdraw(amount);
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(input);
            IERC20(Currency.unwrap(input)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
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
        if (msg.sender != address(poolManager) && msg.sender != address(weth9)) revert UnexpectedNativeSender(msg.sender);
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

    /// @dev baseSpread must clear the current per-chain oracle-drift floor and sit
    ///      under the hard cap. Shared by config-time checks and the readiness gate.
    function _checkBaseSpread(uint16 bps) internal view {
        // JUP-621: the effective lower bound is max(floor, jarFeeBps): every spread must
        // be able to carry the TokenJar fee without touching the buyer's price.
        uint16 lower = baseSpreadFloorBps > jarFeeBps ? baseSpreadFloorBps : jarFeeBps;
        if (bps < lower || bps > MAX_SPREAD_BPS) {
            revert SpreadOutOfRange(bps, lower, MAX_SPREAD_BPS);
        }
    }

    enum MarketWiringStatus {
        Valid,
        Unverifiable,
        UnknownPool,
        InventoryMismatch,
        QuoteNotApproved
    }

    function _marketWiringStatus(address marketPool, address expectedInventory, address quoteAsset)
        internal
        view
        returns (MarketWiringStatus status, address actualInventory)
    {
        bool exists;
        try market.poolRecords(marketPool) returns (address inventoryToken, bool poolExists) {
            actualInventory = inventoryToken;
            exists = poolExists;
        } catch {
            return (MarketWiringStatus.Unverifiable, address(0));
        }
        if (!exists) return (MarketWiringStatus.UnknownPool, actualInventory);
        if (actualInventory != expectedInventory) return (MarketWiringStatus.InventoryMismatch, actualInventory);

        try market.approvedQuoteAssets(quoteAsset) returns (bool approved) {
            if (!approved) return (MarketWiringStatus.QuoteNotApproved, actualInventory);
        } catch {
            return (MarketWiringStatus.Unverifiable, actualInventory);
        }
        return (MarketWiringStatus.Valid, actualInventory);
    }

    function _validateMarketWiring(address marketPool, address expectedInventory, address quoteAsset) internal view {
        (MarketWiringStatus status, address actualInventory) =
            _marketWiringStatus(marketPool, expectedInventory, quoteAsset);
        if (status == MarketWiringStatus.Valid) return;
        if (status == MarketWiringStatus.Unverifiable) revert MarketStateUnverifiable();
        if (status == MarketWiringStatus.UnknownPool) revert MarketPoolNotRecognized(marketPool);
        if (status == MarketWiringStatus.InventoryMismatch) {
            revert MarketInventoryMismatch(marketPool, expectedInventory, actualInventory);
        }
        revert MarketQuoteAssetNotApproved(marketPool, quoteAsset);
    }

    function _requirePairReady(PairConfig memory cfg, Currency c0, Currency c1) internal view {
        if (!cfg.registered) revert PairNotRegistered();
        _checkBaseSpread(cfg.baseSpreadBps);
        Currency inventory = cfg.quoteIsCurrency0 ? c1 : c0;
        _validateMarketWiring(cfg.marketPool, Currency.unwrap(inventory), cfg.marketAsset);
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
