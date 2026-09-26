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
abstract contract NativeQuoteFixture is ForkTestBase {
    // token/aeWETH rate: 0.0004 aeWETH (18 dec) per token unit
    uint256 constant RATE_W = 4e14;

    PoolKey nativeKey;

    function setUp() public override {
        super.setUp();

        // the SAME C1 pool gains an aeWETH anchor (late-seeding lane: admin resetAnchor)
        oracle.setRate(address(token), AEWETH, RATE_W);
        market.setQuoteAsset(AEWETH, true);
        vm.prank(address(stack.tl48)); // JUP-611 (#40): resetAnchor is behind the 48h TIMELOCK_ROLE
        market.resetAnchor(pool, AEWETH);

        // native-quoted V4 pool on the SAME hook, wired to the SAME C1 pool
        hook.registerPair(Currency.wrap(address(0)), Currency.wrap(address(token)), pool, _fixtureSpreadBps());
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








}

contract NativeQuoteForkTest is NativeQuoteFixture {
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
    /// @dev Rung unification: schedules key on the MARKET asset, so the wrapper's
    ///      schedule governs native pools too — one schedule to maintain per economic
    ///      asset, no drift between the two V4 representations of the same value.
    function test_Native_RungsSharedWithWrapperSchedule() public {
        hook.setBaseSpread(Currency.wrap(address(0)), Currency.wrap(address(token)), 50);
        FlowstateC1Hook.SpreadRung[] memory rungs = new FlowstateC1Hook.SpreadRung[](1);
        rungs[0] = FlowstateC1Hook.SpreadRung({notionalCeiling: uint128(1e17), extraBps: 25});
        hook.setSizeRungs(Currency.wrap(AEWETH), rungs); // configured under the WRAPPER

        // the native pair reads the wrapper's schedule
        assertEq(
            hook.spreadBpsFor(Currency.wrap(address(0)), Currency.wrap(address(token)), 1e16),
            75,
            "native pair pays base + the wrapper-keyed rung"
        );
        // and it binds end to end: margin accrues at 75 bps on a native swap
        uint256 quoteIn = 1e16;
        uint256 wethBefore = IERC20(AEWETH).balanceOf(address(hook));
        _swapBuyNative(-int256(quoteIn), quoteIn);
        uint256 accrued = IERC20(AEWETH).balanceOf(address(hook)) - wethBefore;
        // netQuote carve at 75 bps, spread = ceil(quotePaid x 75 / 10000); dust makes
        // the exact wei value carve-dependent, so assert the tight band
        assertGt(accrued, quoteIn * 70 / 10_000, "accrual reflects the rung");
        assertLt(accrued, quoteIn * 80 / 10_000, "accrual bounded near 75 bps");
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
    /// @dev The multi-asset core, end to end through the hook: TWO V4 doors (USDG and
    ///      native) draw from ONE C1 pool in the same block. Per-asset anchors resolve
    ///      independently, both fill, inventory is shared, and the lister's proceeds
    ///      arrive as a mix of both assets, swept in a single claim.
    function test_Native_BothDoorsShareOneC1PoolSameBlock() public {
        uint256 invBefore = poolContract.tokenBalance();

        // door 1: USDG-quoted V4 pool (the base fixture's poolKey)
        uint256 usdgIn = 100e6;
        vm.prank(swapper);
        _swapBuy(-int256(usdgIn), "");
        // door 2: native-quoted V4 pool, same block, same C1 pool
        uint256 nativeIn = 1e16;
        _swapBuyNative(-int256(nativeIn), nativeIn);

        uint256 usdgTokens = usdgIn * 1e18 / ORACLE_RATE;
        uint256 nativeTokens = nativeIn * 1e18 / RATE_W;
        assertEq(invBefore - poolContract.tokenBalance(), usdgTokens + nativeTokens, "one inventory, two doors");

        // proceeds are a mix across both claim ledgers, swept in one claim
        uint256 usdgFee = usdgIn * MARKET_FEE_BPS / 10_000;
        uint256 wethFee = nativeIn * MARKET_FEE_BPS / 10_000;
        assertEq(poolContract.claimableQuote(USDG, lister), usdgIn - usdgFee, "USDG leg credited");
        assertEq(poolContract.claimableQuote(AEWETH, lister), nativeIn - wethFee, "aeWETH leg credited");
        uint256 usdgBal = IERC20(USDG).balanceOf(lister);
        uint256 wethBal = IERC20(AEWETH).balanceOf(lister);
        vm.prank(lister);
        poolContract.claimQuote();
        assertEq(IERC20(USDG).balanceOf(lister) - usdgBal, usdgIn - usdgFee, "one claim sweeps USDG");
        assertEq(IERC20(AEWETH).balanceOf(lister) - wethBal, nativeIn - wethFee, "and aeWETH");
    }
    /// @dev Config safety: a chain with no wrapper configured cannot register native
    ///      pairs — loud at config time, never on the hot path.
    function test_Native_RegisterRevertsWithoutWeth9() public {
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(FlowstateC1Hook).creationCode,
            abi.encode(POOL_MANAGER, address(market), address(this), address(0), TOKEN_JAR, 0, address(0), address(0))
        );
        FlowstateC1Hook bare = new FlowstateC1Hook{salt: salt}(
            POOL_MANAGER, address(market), address(this), address(0), TOKEN_JAR, 0, address(0), address(0)
        );
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

/// JUP-621 on the NATIVE quote path (Wilko, PR #12 review): the hook takes native,
/// wraps the whole take into aeWETH for the market call, and the TokenJar fee is paid
/// in that wrapper, in the same fill, out of the spread. Nothing native strands on the
/// hook and the jar receives aeWETH, never ETH.
contract NativeQuoteJarFeeForkTest is NativeQuoteFixture {
    function _jarFeeBps() internal pure override returns (uint16) {
        return JAR_FEE_BPS;
    }

    function _fixtureSpreadBps() internal pure override returns (uint16) {
        return 16;
    }

    function _ceilBpsLocal(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps + 10_000 - 1) / 10_000;
    }

    function test_NativeQuote_JarPaidInWrapper_OutOfSpread() public {
        uint256 quoteIn = 1e16; // 0.01 native
        uint256 jarWethBefore = IERC20(AEWETH).balanceOf(TOKEN_JAR);
        uint256 jarEthBefore = TOKEN_JAR.balance;
        uint256 marginBefore = hook.accruedSpreadMargin(Currency.wrap(AEWETH));
        uint256 tokBefore = token.balanceOf(swapper);

        _swapBuyNative(-int256(quoteIn), quoteIn);

        uint256 tokens = token.balanceOf(swapper) - tokBefore;
        uint256 quotePaid = (tokens * RATE_W + 1e18 - 1) / 1e18; // the market's ceil cost at the fixed mock rate
        uint256 jarFee = IERC20(AEWETH).balanceOf(TOKEN_JAR) - jarWethBefore;
        assertEq(TOKEN_JAR.balance - jarEthBefore, 0, "jar never receives raw native");
        assertApproxEqAbs(jarFee, _ceilBpsLocal(quotePaid, JAR_FEE_BPS), 1, "jar paid JAR_FEE_BPS of the realised cost, in aeWETH");
        uint256 marginKept = hook.accruedSpreadMargin(Currency.wrap(AEWETH)) - marginBefore;
        assertApproxEqAbs(jarFee + marginKept, _ceilBpsLocal(quotePaid, 16), 1, "jar + kept margin == the 16 bps spread");
        assertEq(address(hook).balance, 0, "no native strands on the hook");
        assertEq(
            IERC20(AEWETH).balanceOf(address(hook)),
            hook.accruedSpreadMargin(Currency.wrap(AEWETH)) + hook.accruedDust(Currency.wrap(AEWETH)),
            "hook holds only its booked margin + dust in the wrapper"
        );
    }
}
