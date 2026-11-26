// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {FlowstateC1Hook} from "../FlowstateC1Hook.sol";

/// @notice The rate the settlement prices a hook buy at. FlowstateMarket exposes it; the
///         listing settlement calls the same function when the hook asks (C1ListingSettlement._price).
interface IFlowstateHookRate {
    function previewHookRate(address pool, address asset) external view returns (bool ok, uint256 rate);
}

/// @title FlowstateC1View
/// @notice Read-only answers about the FlowState C1 hook's pools, for routers that price the
///         hook off chain (Tycho's FlowState client first). Amounts come from simulating the
///         hook's own exact-input buy through the PoolManager, so they follow the hook's walk,
///         listing checks and limits instead of a copy of them.
/// @dev    No owner, no storage, no funds. The answering functions are not `view` because the
///         simulation runs inside `PoolManager.unlock` and always reverts; call them with
///         `eth_call` only. Buy direction and exact input only: the hook refuses sells.
///         `simGas` is the gas handed to the simulated swap. The hook stops early when gas runs
///         short, so pass a figure close to what a real router call leaves the swap, or the
///         answer can be larger than a real call fills. 0 means all remaining gas.
contract FlowstateC1View is IUnlockCallback {
    using CurrencyLibrary for Currency;

    /// @notice `reason` values. 1 to 7 are the hook's own stop codes (FlowstateC1Hook STOP_*).
    uint8 public constant REASON_NONE = 0;
    uint8 public constant REASON_OTHER_REVERT = 100; // see `otherSelector`
    uint8 public constant REASON_NO_RESERVES = 101; // the PoolManager holds none of the quote asset
    uint8 public constant REASON_UNEXPECTED = 102; // the simulation returned instead of reverting

    struct PoolAnswer {
        PoolKey key;
        address marketPool; // two keys can share one market pool: count its stock once, never per key
        bool active; // one exact-input buy can fill something now
        uint8 reason; // why not, or why the probe stopped (0 when the probe filled in full)
        bytes4 otherSelector; // the innermost error when reason == REASON_OTHER_REVERT
        bool rateOk; // the market's hook rate read succeeded
        uint256 rate; // quote units per 1e18 tokens before spread, as the settlement prices hook buys
        uint16 baseSpreadBps; // the pair's base spread; size rungs via spreadBpsFor / sizeRungs
        address quoteCurrency; // the V4 currency a buy pays in (address(0) = native ETH)
        uint256 probeIn; // the quote amount the probe offered (capped at PoolManager reserves)
        uint256 available; // tokens one exact-input buy would take at this block
        bool availableIsFloor; // the probe filled in full, so more may be available
        uint64 blockNumber;
    }

    error NotPoolManager();
    error WrongHook(address hooks);
    error Simulated(uint256 tokensOut);

    IPoolManager public immutable poolManager;
    FlowstateC1Hook public immutable hook;
    IFlowstateHookRate public immutable market;

    constructor(FlowstateC1Hook hook_) {
        hook = hook_;
        poolManager = hook_.poolManager();
        market = IFlowstateHookRate(address(hook_.market()));
    }

    // ---------------------------------------------------------------- answers

    function answerAll(PoolKey[] calldata keys, uint256 simGas) external returns (PoolAnswer[] memory out) {
        out = new PoolAnswer[](keys.length);
        for (uint256 i; i < keys.length; i++) {
            out[i] = answer(keys[i], simGas);
        }
    }

    function answer(PoolKey calldata key, uint256 simGas) public returns (PoolAnswer memory a) {
        if (address(key.hooks) != address(hook)) revert WrongHook(address(key.hooks));
        a.key = key;
        a.blockNumber = uint64(block.number);

        (address marketPool, bool quoteIsCurrency0,, uint16 baseSpreadBps, address marketAsset) =
            hook.pairs(keccak256(abi.encode(key.currency0, key.currency1)));
        a.marketPool = marketPool;
        a.baseSpreadBps = baseSpreadBps;
        Currency payIn = quoteIsCurrency0 ? key.currency0 : key.currency1;
        a.quoteCurrency = Currency.unwrap(payIn);

        if (marketPool != address(0)) {
            try market.previewHookRate(marketPool, marketAsset) returns (bool ok, uint256 rate) {
                a.rateOk = ok && rate != 0;
                a.rate = a.rateOk ? rate : 0;
            } catch {}
        }

        // The hook takes the whole input from the PoolManager before it fills
        // (FlowstateC1Hook._takeChecked), so no buy can be larger than the manager's reserves.
        a.probeIn = payIn.balanceOf(address(poolManager));
        if (a.probeIn == 0) {
            a.reason = REASON_NO_RESERVES;
            return a;
        }

        (uint8 reason, uint256 tokens, bytes4 sel) = _simulate(key, quoteIsCurrency0, a.probeIn, simGas);
        a.reason = reason;
        a.otherSelector = sel;
        if (reason == REASON_NONE) {
            a.available = tokens;
            a.availableIsFloor = true;
        } else if (reason <= 7) {
            a.available = tokens; // the shortfall's `filled`
        }
        a.active = a.available != 0;
    }

    /// @notice Exact tokens out for each exact-input size, or why that size would not fill.
    ///         tokensOut is 0 whenever reasons[i] != 0 (an exact-input buy fills in full or reverts).
    function quote(PoolKey calldata key, uint256[] calldata amountsIn, uint256 simGas)
        external
        returns (uint256[] memory tokensOut, uint8[] memory reasons, bytes4[] memory otherSelectors)
    {
        if (address(key.hooks) != address(hook)) revert WrongHook(address(key.hooks));
        (, bool quoteIsCurrency0,,,) = hook.pairs(keccak256(abi.encode(key.currency0, key.currency1)));
        uint256 n = amountsIn.length;
        tokensOut = new uint256[](n);
        reasons = new uint8[](n);
        otherSelectors = new bytes4[](n);
        for (uint256 i; i < n; i++) {
            (uint8 reason, uint256 tokens, bytes4 sel) = _simulate(key, quoteIsCurrency0, amountsIn[i], simGas);
            reasons[i] = reason;
            otherSelectors[i] = sel;
            if (reason == REASON_NONE) tokensOut[i] = tokens;
        }
    }

    /// @notice The hook's total spread for a trade of `quoteNotional` (base plus size rung).
    ///         Reverts when the pair is not ready, as the hook's own function does.
    function spreadBpsFor(PoolKey calldata key, uint256 quoteNotional) external view returns (uint256) {
        (, bool quoteIsCurrency0,,,) = hook.pairs(keccak256(abi.encode(key.currency0, key.currency1)));
        (Currency q, Currency t) = quoteIsCurrency0 ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        return hook.spreadBpsFor(q, t, quoteNotional);
    }

    /// @notice The hook's size rungs for a market asset (the wrapped asset for a native pair).
    function sizeRungs(Currency marketAsset) external view returns (FlowstateC1Hook.SpreadRung[] memory) {
        return hook.sizeRungs(marketAsset);
    }

    // ------------------------------------------------------------- simulation

    /// @dev Runs one exact-input buy inside PoolManager.unlock and reads the revert.
    ///      Returns (0, tokensOut, 0) on a full fill; (stop, filled, 0) on the hook's
    ///      ExactInputShortfall; (REASON_OTHER_REVERT, 0, selector) on anything else.
    function _simulate(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 simGas)
        internal
        returns (uint8 reason, uint256 tokens, bytes4 sel)
    {
        bytes memory data = abi.encode(key, zeroForOne, amountIn);
        uint256 g = simGas == 0 ? gasleft() : simGas;
        try poolManager.unlock{gas: g}(data) {
            return (REASON_UNEXPECTED, 0, bytes4(0));
        } catch (bytes memory err) {
            return _decode(err);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 out = zeroForOne ? delta.amount1() : delta.amount0();
        revert Simulated(out > 0 ? uint256(uint128(out)) : 0);
    }

    function _decode(bytes memory err) internal pure returns (uint8 reason, uint256 tokens, bytes4 sel) {
        sel = _selector(err);
        if (sel == Simulated.selector) {
            return (REASON_NONE, abi.decode(_args(err), (uint256)), bytes4(0));
        }
        // A hook revert reaches us wrapped by the PoolManager's hook call
        if (sel == CustomRevert.WrappedError.selector) {
            (,, bytes memory inner,) = abi.decode(_args(err), (address, bytes4, bytes, bytes));
            err = inner;
            sel = _selector(err);
        }
        if (sel == FlowstateC1Hook.ExactInputShortfall.selector) {
            (uint256 filled,, uint8 stop) = abi.decode(_args(err), (uint256, uint256, uint8));
            return (stop, filled, bytes4(0));
        }
        return (REASON_OTHER_REVERT, 0, sel);
    }

    function _selector(bytes memory b) private pure returns (bytes4 s) {
        if (b.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            s := mload(add(b, 32))
        }
    }

    /// @dev The ABI-encoded arguments after a 4-byte selector.
    function _args(bytes memory b) private pure returns (bytes memory out) {
        if (b.length < 4) return out;
        uint256 len = b.length - 4;
        out = new bytes(len);
        for (uint256 i; i < len; i++) {
            out[i] = b[i + 4];
        }
    }
}
