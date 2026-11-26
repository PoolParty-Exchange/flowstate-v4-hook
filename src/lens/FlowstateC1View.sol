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
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {FlowstateC1Hook} from "../FlowstateC1Hook.sol";

/// @notice The rate the settlement prices a hook buy at. The listing settlement calls this same
///         market function when the hook asks (C1ListingSettlementV2._price, hookPricing = true).
interface IFlowstateHookRate {
    function previewHookRate(address pool, address asset) external view returns (bool ok, uint256 rate);
}

/// @title FlowstateC1View
/// @notice Read-only answers about the FlowState C1 hook's pools, for routers that price the hook
///         off chain (Tycho's FlowState client first). Amounts come from simulating the hook's own
///         exact-input buy through the PoolManager, so they follow the hook's walk, listing checks,
///         gas use and limits instead of a copy of them.
/// @dev    No owner, no storage, no funds. The answering functions are not `view` because each
///         simulation runs inside `PoolManager.unlock` and always reverts; call them with `eth_call`
///         only. Buy direction and exact input only: the hook refuses sells.
///
///         GAS. `simGas` is the gas handed to `PoolManager.unlock` for each simulated buy, and it is
///         required. The hook stops early when gas runs short, so an answer holds only for a real
///         call whose `unlock` gets at least `simGas`. Inside the simulation, POST_SWAP_RESERVE is
///         held back from the swap for the router's own settle and take after the hook returns.
///         Every simulation runs in a frame that reverts, and every read the view makes for itself
///         runs in a reverting frame too, so nothing is pre-warmed: each simulation starts as cold
///         as a fresh transaction's first touch of the hook, market and listing contracts.
///
///         WHAT IT CANNOT SEE. Another buy in the same block taking the same stock; a listing that
///         expires, or whose seller moves tokens or loses the Permit2 permission, between the read
///         and the fill; a router mapped to a partner fee code (the view itself resolves to the
///         house code); the extra gas of a pool's first fill when its beacon is not yet lit (the
///         beacon is skipped, never blocks, when gas is short); state a router changes earlier in
///         its own transaction.
contract FlowstateC1View is IUnlockCallback {
    using CurrencyLibrary for Currency;

    /// @notice `reason` values. 1 to 7 are the hook's own stop codes (FlowstateC1Hook STOP_*):
    ///         1 gas, 2 price read, 3 pool leg, 4 listing leg, 5 stock, 6 closed, 7 attempt cap.
    uint8 public constant REASON_NONE = 0;
    uint8 public constant REASON_OTHER_REVERT = 100; // see `otherSelector`
    uint8 public constant REASON_NO_RESERVES = 101; // the PoolManager holds none of the quote asset
    uint8 public constant REASON_UNEXPECTED = 102; // a simulation returned instead of reverting
    uint8 public constant REASON_UNCONFIRMED = 103; // the probe reported stock but no buy confirmed it

    /// @notice Gas held back inside the simulation for a router's settle and take after the swap.
    uint256 public constant POST_SWAP_RESERVE = 60_000;
    /// @notice The confirming buy is sized at this share of the probe's implied ceiling.
    uint16 public constant CONFIRM_BPS = 9_950;

    struct PoolAnswer {
        PoolKey key;
        address marketPool; // two keys can share one market pool: take one figure per pool, never a sum
        address marketAsset; // the asset the market is called with (the wrapped asset for a native pair)
        address quoteCurrency; // the V4 currency a buy pays in (address(0) = native ETH)
        bool active; // a confirmed exact-input buy fills now
        uint8 reason; // why not, or why the probe stopped (0 when the probe filled in full)
        bytes4 otherSelector; // the decoded error when reason == REASON_OTHER_REVERT
        uint256 maxAmountIn; // an exact input confirmed to fill in full (0 when inactive)
        uint256 available; // tokens that confirmed buy takes; a lower bound on what one buy can take
        uint256 probeCeiling; // tokens the probe reached before it stopped (unconfirmed upper figure)
        bool availableIsFloor; // the probe itself filled in full at PoolManager reserves
        bool rateOk;
        uint256 rate; // quote units per 1e18 tokens, before the hook's spread (the market's hook rate)
        uint8 gateWhy; // the settlement's gate code read as a plain caller; 1-4 are its gates (see doc)
        uint16 baseSpreadBps;
    }

    struct Peek {
        address marketPool;
        bool quoteIsCurrency0;
        uint16 baseSpreadBps;
        address marketAsset;
        uint256 reserves;
    }

    error NotPoolManager();
    error WrongHook(address hooks);
    error SimGasRequired();
    error Simulated(uint256 tokensOut);
    error Peeked(Peek p);
    error Rated(bool ok, uint256 rate, uint8 gateWhy);
    error HookNotSettled(int256 delta0, int256 delta1);
    error UnexpectedPeek();

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
        if (simGas == 0) revert SimGasRequired();
        a.key = key;

        Peek memory p = _peek(key);
        a.marketPool = p.marketPool;
        a.marketAsset = p.marketAsset;
        a.baseSpreadBps = p.baseSpreadBps;
        a.quoteCurrency = Currency.unwrap(p.quoteIsCurrency0 ? key.currency0 : key.currency1);

        if (p.reserves == 0) {
            a.reason = REASON_NO_RESERVES;
        } else {
            // The probe: the largest input the hook accepts (it takes the whole input from the
            // PoolManager first, FlowstateC1Hook._takeChecked). It reports how far one buy walks.
            (uint8 reason, uint256 filled, uint256 wanted, bytes4 sel) =
                _simulate(key, p.quoteIsCurrency0, p.reserves, simGas);
            a.reason = reason;
            a.otherSelector = sel;
            if (reason == REASON_NONE) {
                a.maxAmountIn = p.reserves;
                a.available = filled;
                a.probeCeiling = filled;
                a.availableIsFloor = true;
            } else if (reason <= 7 && filled != 0 && wanted != 0) {
                a.probeCeiling = filled;
                // Confirm with a real full fill sized just under the probe's implied ceiling. Only a
                // buy the simulation completes counts, so a forged or misleading shortfall reports 0.
                // The size rung can differ between the probe and a smaller buy, so step down twice.
                uint256 ceilingIn = p.reserves * filled / wanted;
                uint16[3] memory steps = [CONFIRM_BPS, 9_800, 9_000];
                for (uint256 i; i < 3 && a.available == 0; i++) {
                    uint256 confirmIn = ceilingIn * steps[i] / 10_000;
                    if (confirmIn == 0) break;
                    (uint8 r2, uint256 got,,) = _simulate(key, p.quoteIsCurrency0, confirmIn, simGas);
                    if (r2 == REASON_NONE && got != 0) {
                        a.maxAmountIn = confirmIn;
                        a.available = got;
                    }
                }
                if (a.available == 0) a.reason = REASON_UNCONFIRMED;
            }
        }
        a.active = a.available != 0;

        // Reads for the caller's own pricing, after the simulations and in a reverting frame.
        if (p.marketPool != address(0)) (a.rateOk, a.rate, a.gateWhy) = _rate(key, p);
    }

    /// @notice Exact tokens out for each exact-input size, or why that size would not fill.
    ///         tokensOut is 0 whenever reasons[i] != 0 (an exact-input buy fills in full or reverts).
    function quote(PoolKey calldata key, uint256[] calldata amountsIn, uint256 simGas)
        external
        returns (uint256[] memory tokensOut, uint8[] memory reasons, bytes4[] memory otherSelectors)
    {
        if (address(key.hooks) != address(hook)) revert WrongHook(address(key.hooks));
        if (simGas == 0) revert SimGasRequired();
        bool quoteIsCurrency0 = _peek(key).quoteIsCurrency0;
        uint256 n = amountsIn.length;
        tokensOut = new uint256[](n);
        reasons = new uint8[](n);
        otherSelectors = new bytes4[](n);
        for (uint256 i; i < n; i++) {
            (uint8 reason, uint256 got,, bytes4 sel) = _simulate(key, quoteIsCurrency0, amountsIn[i], simGas);
            reasons[i] = reason;
            otherSelectors[i] = sel;
            if (reason == REASON_NONE) tokensOut[i] = got;
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

    // ------------------------------------------------------- reverting reads

    /// @dev Reads the pair and the PoolManager's reserves in a frame that reverts, so the storage
    ///      it touches is not left warm for the simulation that follows.
    function _peek(PoolKey calldata key) internal returns (Peek memory p) {
        try this.peekAndRevert(key) {} catch (bytes memory err) {
            if (_selector(err) != Peeked.selector || err.length != 4 + 5 * 32) revert UnexpectedPeek();
            p = abi.decode(_args(err), (Peek));
        }
    }

    /// @notice Always reverts with `Peeked`. Used by the view on itself; harmless to anyone else.
    function peekAndRevert(PoolKey calldata key) external view {
        (address marketPool, bool quoteIsCurrency0,, uint16 baseSpreadBps, address marketAsset) =
            hook.pairs(keccak256(abi.encode(key.currency0, key.currency1)));
        Currency payIn = quoteIsCurrency0 ? key.currency0 : key.currency1;
        revert Peeked(Peek(marketPool, quoteIsCurrency0, baseSpreadBps, marketAsset, payIn.balanceOf(address(poolManager))));
    }

    function _rate(PoolKey calldata key, Peek memory p) internal returns (bool ok, uint256 rate, uint8 why) {
        try this.rateAndRevert(key, p.marketPool, p.marketAsset, p.quoteIsCurrency0) {} catch (bytes memory err) {
            if (_selector(err) == Rated.selector && err.length == 4 + 3 * 32) {
                (ok, rate, why) = abi.decode(_args(err), (bool, uint256, uint8));
            }
        }
    }

    /// @notice Always reverts with `Rated`. `gateWhy` is the settlement's own code read as a plain
    ///         caller: 1 no pool, 2 market paused, 3 asset not approved, 4 lane closed or pool paused,
    ///         5 rate unusable (for a plain caller; the hook's rate is `rate`). 0 = gates open.
    function rateAndRevert(PoolKey calldata key, address marketPool, address marketAsset, bool quoteIsCurrency0)
        external
        view
    {
        bool ok;
        uint256 rate;
        uint8 why = type(uint8).max;
        try market.previewHookRate(marketPool, marketAsset) returns (bool o, uint256 r) {
            ok = o && r != 0;
            rate = ok ? r : 0;
        } catch {}
        address token = Currency.unwrap(quoteIsCurrency0 ? key.currency1 : key.currency0);
        try hook.listingSettlement().price(token, marketAsset) returns (uint8 w, uint256) {
            why = w;
        } catch {}
        revert Rated(ok, rate, why);
    }

    // ------------------------------------------------------------- simulation

    /// @dev One exact-input buy inside PoolManager.unlock, read back from the revert.
    ///      (0, tokensOut, 0, 0) on a full fill; (stop 1-7, filled, wanted, 0) on the hook's
    ///      ExactInputShortfall; (REASON_OTHER_REVERT, 0, 0, selector) on anything else.
    function _simulate(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 simGas)
        internal
        returns (uint8 reason, uint256 a, uint256 b, bytes4 sel)
    {
        bytes memory data = abi.encode(key, zeroForOne, amountIn);
        try poolManager.unlock{gas: simGas}(data) {
            return (REASON_UNEXPECTED, 0, 0, bytes4(0));
        } catch (bytes memory err) {
            return _decode(err);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        uint256 g = gasleft();
        // hold back what a router needs after the swap: settle the input and take the output
        uint256 swapGas = g > POST_SWAP_RESERVE ? g - POST_SWAP_RESERVE : 0;
        BalanceDelta delta = poolManager.swap{gas: swapGas}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        // the hook must leave its own books square, as PoolManager's end-of-unlock check demands
        int256 h0 = TransientStateLibrary.currencyDelta(poolManager, address(hook), key.currency0);
        int256 h1 = TransientStateLibrary.currencyDelta(poolManager, address(hook), key.currency1);
        if (h0 != 0 || h1 != 0) revert HookNotSettled(h0, h1);
        int128 out = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 tokens = out > 0 ? uint256(uint128(out)) : 0;
        // take the output as a router would, so a token that refuses to leave the PoolManager shows here
        if (tokens != 0) poolManager.take(zeroForOne ? key.currency1 : key.currency0, address(this), tokens);
        revert Simulated(tokens);
    }

    /// @dev Only an unwrapped `Simulated` raised by this contract's callback counts as a fill. A hook
    ///      shortfall counts only with a stop code from 1 to 7. Anything else, including malformed
    ///      data, is REASON_OTHER_REVERT. Never reverts.
    function _decode(bytes memory err) internal view returns (uint8 reason, uint256 a, uint256 b, bytes4 sel) {
        sel = _selector(err);
        if (sel == Simulated.selector && err.length == 36) {
            return (REASON_NONE, abi.decode(_args(err), (uint256)), 0, bytes4(0));
        }
        if (sel == CustomRevert.WrappedError.selector) {
            try this.unwrap(err) returns (bytes memory inner) {
                err = inner;
                sel = _selector(err);
            } catch {
                return (REASON_OTHER_REVERT, 0, 0, sel);
            }
        }
        if (sel == FlowstateC1Hook.ExactInputShortfall.selector && err.length == 4 + 3 * 32) {
            (uint256 filled, uint256 wanted, uint256 stop) = abi.decode(_args(err), (uint256, uint256, uint256));
            if (stop >= 1 && stop <= 7) return (uint8(stop), filled, wanted, bytes4(0));
        }
        return (REASON_OTHER_REVERT, 0, 0, sel);
    }

    /// @notice Decodes a v4-core WrappedError and returns its inner revert data.
    function unwrap(bytes memory err) external pure returns (bytes memory inner) {
        (,, inner,) = abi.decode(_args(err), (address, bytes4, bytes, bytes));
    }

    function _selector(bytes memory b) private pure returns (bytes4 s) {
        if (b.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            s := mload(add(b, 32))
        }
    }

    /// @dev The bytes after a 4-byte selector, without copying: re-points at b + 4 and writes the
    ///      shorter length there. `b` must not be used afterwards.
    function _args(bytes memory b) private pure returns (bytes memory out) {
        if (b.length < 4) return out;
        assembly ("memory-safe") {
            out := add(b, 4)
            mstore(out, sub(mload(b), 4))
        }
    }
}
