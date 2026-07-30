// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * Native-quoted V4 pools (v1 decision, 2026-07-30: pulled forward from phase 2 —
 * native carries ~3x aeWETH's volume inside RH V4 per the quote-asset share report).
 *
 * The design under test: ONE wrapped-quote C1 pool serves BOTH V4 currency
 * representations. A native-quoted V4 pool wires to the SAME multi-asset C1 pool via
 * its aeWETH anchor; the hook takes native from the PoolManager, wraps, and the
 * market's pull-exact transferFrom proceeds in the wrapper. Buy-only means only
 * `deposit` is ever needed — the unwrap direction cannot occur.
 */
contract NativeQuoteForkTest is ForkTestBase {
    // token/aeWETH rate: 0.0004 aeWETH (18 dec) per token unit
    uint256 constant RATE_W = 4e14;

    PoolKey nativeKey;

    function setUp() public override {
        super.setUp();

        // the SAME C1 pool gains an aeWETH anchor (late-seeding lane: admin resetAnchor)
        oracle.setRate(address(token), AEWETH, RATE_W);
        market.setQuoteAsset(AEWETH, true);
        market.resetAnchor(pool, AEWETH);

        // native-quoted V4 pool on the SAME hook, wired to the SAME C1 pool
        hook.registerPair(Currency.wrap(address(0)), Currency.wrap(address(token)), pool, 0);
        nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)), // native always sorts first
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(nativeKey, _sqrtPriceForMockRate());

        vm.deal(swapper, 100 ether);
        _expireRateCache();
    }

    function _swapBuyNative(int256 amountSpecified, uint256 valueToSend) internal {
        vm.prank(swapper);
        swapRouter.swap{value: valueToSend}(
            nativeKey,
            SwapParams({
                zeroForOne: true, // native (currency0) in, token out
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Exact-input: swapper pays native; the hook wraps the whole take and the
    ///      market fills from the C1 pool's aeWETH anchor. Depositor proceeds land on
    ///      the aeWETH claim ledger — the multi-asset "mix" arriving in practice.
    function test_Native_ExactInputBuy_FillsViaWrap() public {
        uint256 quoteIn = 1e16; // 0.01 native
        uint256 tokensExpected = quoteIn * 1e18 / RATE_W;
        uint256 balBefore = token.balanceOf(swapper);

        _swapBuyNative(-int256(quoteIn), quoteIn);

        assertEq(token.balanceOf(swapper) - balBefore, tokensExpected, "tokens delivered at the aeWETH anchor rate");
        assertEq(address(hook).balance, 0, "no native strands on the hook (wrapped in full)");
        // fee carved from the seller leg, credited on the aeWETH ledger
        uint256 fee = quoteIn * MARKET_FEE_BPS / 10_000;
        assertEq(poolContract.claimableQuote(AEWETH, lister), quoteIn - fee, "lister credited in the wrapper");
    }

    /// @dev Exact-output: the market computes cost inside its single oracle read and
    ///      fundBuy fires with the WRAPPER as quoteAsset; the armed one-frame flag
    ///      makes the hook take NATIVE and wrap so the pull-exact succeeds.
    function test_Native_ExactOutputBuy_FundsCallbackByWrapping() public {
        uint256 tokensOut = 5e18;
        uint256 cost = tokensOut * RATE_W / 1e18;
        uint256 nativeBefore = swapper.balance;

        _swapBuyNative(int256(tokensOut), cost);

        assertEq(token.balanceOf(swapper), tokensOut, "exact output delivered");
        assertEq(nativeBefore - swapper.balance, cost, "swapper paid exactly the oracle cost in native");
        assertEq(address(hook).balance, 0, "no native strands on the hook");
    }

    /// @dev Spread margin is custodied in the WRAPPER, never in native, so the sweep
    ///      path stays ERC-20-only.
    function test_Native_SpreadMarginAccruesInWrapper() public {
        hook.setBaseSpread(Currency.wrap(address(0)), Currency.wrap(address(token)), 100); // 1%
        uint256 quoteIn = 1e16;
        uint256 hookWethBefore = IERC20(AEWETH).balanceOf(address(hook));

        _swapBuyNative(-int256(quoteIn), quoteIn);

        assertGt(IERC20(AEWETH).balanceOf(address(hook)), hookWethBefore, "margin accrued as aeWETH");
        assertEq(address(hook).balance, 0, "zero native custody");
    }

    /// @dev Rule 2 unchanged on native pools: buy direction only.
    function test_Native_SellDirectionReverts() public {
        deal(address(token), swapper, 1e18);
        vm.startPrank(swapper);
        token.approve(address(swapRouter), type(uint256).max);
        vm.expectRevert();
        swapRouter.swap(
            nativeKey,
            SwapParams({
                zeroForOne: false, // token in, native out — the unsupported direction
                amountSpecified: -int256(1e18),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @dev Config safety: a chain with no wrapper configured cannot register native
    ///      pairs — loud at config time, never on the hot path.
    function test_Native_RegisterRevertsWithoutWeth9() public {
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(FlowstateC1Hook).creationCode,
            abi.encode(POOL_MANAGER, address(market), address(this), address(0))
        );
        FlowstateC1Hook bare =
            new FlowstateC1Hook{salt: salt}(POOL_MANAGER, address(market), address(this), address(0));
        assertEq(address(bare), hookAddress);
        vm.expectRevert(FlowstateC1Hook.NativeQuoteUnsupported.selector);
        bare.registerPair(Currency.wrap(address(0)), Currency.wrap(address(token)), pool, 0);
    }

    /// @dev Stray native (self-destruct aside, nothing should ever send here) is
    ///      rejected so custody accounting never has an unexplained balance.
    function test_Native_ReceiveRejectsStrangers() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "stray native rejected");
    }
}
