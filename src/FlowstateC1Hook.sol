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
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlowstateMarketMinimal} from "./interfaces/IFlowstateMarketMinimal.sol";

/// @title FlowstateC1Hook
/// @notice Uniswap V4 custom-curve hook adapting routed BUY flow onto Flowstate C1 pool
///         inventory via the pull-exact FlowstateMarket. The hook fully overrides the
///         concentrated-liquidity curve (BEFORE_SWAP_RETURNS_DELTA consuming the entire
///         specified amount), so pools carry zero real V4 liquidity and the market does
///         100% of the pricing.
///
/// @dev BUY-ONLY (scope §4, correction C1): a buy is quote-asset in, inventory token out.
///      Both sell-direction paths revert with SellDirectionNotSupported, identically in
///      the V4Quoter simulation and the real swap. Sellers exit through the existing C1
///      deposit-and-claim path, off-hook.
///
///      Custody: the hook holds no user funds. Balances exist only transiently inside a
///      single PoolManager unlock (take input -> market pulls exactly the cost -> settle
///      output). No pause, no sender gates, hookData never read (scope rules 1-3).
///
///      Address flags must be 0x28cc: BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY |
///      BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA.
contract FlowstateC1Hook is IHooks, Ownable2Step {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotPoolManager();
    error HookNotImplemented();
    error ZeroAddress();
    error PairNotRegistered();
    error LpFeeMustBeZero();
    error LiquidityNotAllowed();
    error SellDirectionNotSupported();
    error ManagerReservesExceeded(Currency currency, uint256 requested, uint256 available);
    error QuoteExecutionMismatch(uint256 quoted, uint256 pulled);
    error FillShortfall(uint256 requested, uint256 filled);

    // -------------------------------------------------------------------------
    // Immutable wiring
    // -------------------------------------------------------------------------

    /// @notice The canonical PoolManager on this chain.
    IPoolManager public immutable poolManager;

    /// @notice The FlowstateMarket router (Phase 0: a mock with the same pull-exact shape).
    IFlowstateMarketMinimal public immutable market;

    // -------------------------------------------------------------------------
    // Admin-controlled state
    // -------------------------------------------------------------------------

    struct PairConfig {
        address marketPool;
        bool quoteIsCurrency0;
        bool registered;
    }

    /// @notice Pair registry gating pool initialization and resolving swap-time config.
    ///         Keyed by keccak256(currency0, currency1) in V4 sorted order.
    mapping(bytes32 pairKey => PairConfig config) public pairs;

    /// @notice Reseller code passed to the market on each buy ("" = none).
    string public resellerCode;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PairRegistered(
        Currency indexed currency0, Currency indexed currency1, address indexed marketPool, bool quoteIsCurrency0
    );
    event PairUnregistered(Currency indexed currency0, Currency indexed currency1);
    event ResellerCodeUpdated(string previous, string current);
    event BuyExecuted(
        PoolId indexed poolId, Currency quote, Currency token, uint256 quoteIn, uint256 tokensOut, bool exactInput
    );

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _poolManager canonical PoolManager for this chain.
    /// @param _market      FlowstateMarket (must be non-zero and code-bearing).
    /// @param _owner       admin for the pair registry and reseller code.
    constructor(address _poolManager, address _market, address _owner) Ownable(_owner) {
        if (_poolManager == address(0) || _market == address(0)) revert ZeroAddress();
        if (_market.code.length == 0) revert ZeroAddress();

        poolManager = IPoolManager(_poolManager);
        market = IFlowstateMarketMinimal(_market);

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
    ///         transferFrom never pays approval gas on the hot path.
    function registerPair(Currency quote, Currency token, address marketPool) external onlyOwner {
        if (marketPool == address(0)) revert ZeroAddress();
        (Currency c0, Currency c1) = _sort(quote, token);
        bool quoteIsCurrency0 = Currency.unwrap(quote) == Currency.unwrap(c0);
        pairs[_pairKey(c0, c1)] =
            PairConfig({marketPool: marketPool, quoteIsCurrency0: quoteIsCurrency0, registered: true});
        IERC20(Currency.unwrap(quote)).forceApprove(address(market), type(uint256).max);
        emit PairRegistered(c0, c1, marketPool, quoteIsCurrency0);
    }

    function unregisterPair(Currency currencyA, Currency currencyB) external onlyOwner {
        (Currency c0, Currency c1) = _sort(currencyA, currencyB);
        delete pairs[_pairKey(c0, c1)];
        emit PairUnregistered(c0, c1);
    }

    function setResellerCode(string calldata code) external onlyOwner {
        emit ResellerCodeUpdated(resellerCode, code);
        resellerCode = code;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function isPairRegistered(Currency currencyA, Currency currencyB) external view returns (bool) {
        (Currency c0, Currency c1) = _sort(currencyA, currencyB);
        return pairs[_pairKey(c0, c1)].registered;
    }

    // -------------------------------------------------------------------------
    // Hook callbacks — implemented
    // -------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (key.fee != 0) revert LpFeeMustBeZero();
        if (!pairs[_pairKey(key.currency0, key.currency1)].registered) revert PairNotRegistered();
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev The custom curve. Consumes the entire specified amount (specifiedDelta =
    ///      -amountSpecified) so the concentrated-liquidity swap runs on zero and the
    ///      hook does 100% of the pricing. hookData is never read (rule 1).
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
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
        (uint256 quoteIn, uint256 tokensOut, BeforeSwapDelta hookDelta) = exactInput
            ? _buyExactInput(cfg.marketPool, input, output, params.amountSpecified)
            : _buyExactOutput(cfg.marketPool, input, output, params.amountSpecified);

        emit BuyExecuted(key.toId(), quote, output, quoteIn, tokensOut, exactInput);
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    function _buyExactInput(address marketPool, Currency input, Currency output, int256 amountSpecified)
        internal
        returns (uint256 quoteIn, uint256 tokensOut, BeforeSwapDelta hookDelta)
    {
        quoteIn = uint256(-amountSpecified);
        _takeChecked(input, quoteIn);
        tokensOut = market.buyFromPoolExactQuote(marketPool, quoteIn, resellerCode, address(this));
        _settle(output, tokensOut);
        hookDelta = toBeforeSwapDelta((-amountSpecified).toInt128(), -tokensOut.toInt128());
    }

    function _buyExactOutput(address marketPool, Currency input, Currency output, int256 amountSpecified)
        internal
        returns (uint256 quoteIn, uint256 tokensOut, BeforeSwapDelta hookDelta)
    {
        tokensOut = uint256(amountSpecified);
        uint256 quoted = market.quoteBuyFromPool(marketPool, tokensOut);
        _takeChecked(input, quoted);
        (uint256 tokensFilled, uint256 quotePaid) =
            market.buyFromPool(marketPool, tokensOut, resellerCode, address(this));
        if (tokensFilled != tokensOut) revert FillShortfall(tokensOut, tokensFilled);
        if (quotePaid != quoted) revert QuoteExecutionMismatch(quoted, quotePaid);
        quoteIn = quotePaid;
        _settle(output, tokensOut);
        hookDelta = toBeforeSwapDelta((-amountSpecified).toInt128(), quoteIn.toInt128());
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

    function _sort(Currency a, Currency b) internal pure returns (Currency, Currency) {
        return Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
    }

    function _pairKey(Currency c0, Currency c1) internal pure returns (bytes32) {
        return keccak256(abi.encode(c0, c1));
    }
}
