// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Phase 1 slice 2: the fee-determination rungs (scope §5).
///
///         spreadBps = baseSpread[pair] + sizeAdjustment(quote notional); the buyer
///         pays market cost * (1 + spreadBps/10_000) in BOTH directions; the spread
///         accrues on the hook per quote asset. These tests hold the acceptance line
///         from rule 2 — quoter == execution to the wei — WITH spread applied, and
///         prove the rounding never undercollects.
abstract contract SpreadTestBase is ForkTestBase {
    Currency internal usdg = Currency.wrap(USDG);
    address internal freshSender = makeAddr("arbitrary-fresh-eoa");

    // -- config helpers -------------------------------------------------------

    function _setBase(uint16 bps) internal {
        hook.setBaseSpread(usdg, Currency.wrap(address(token)), bps);
    }

    function _setRungs(uint128[] memory ceilings, uint16[] memory extras) internal {
        FlowstateC1Hook.SpreadRung[] memory rungs = new FlowstateC1Hook.SpreadRung[](ceilings.length);
        for (uint256 i = 0; i < ceilings.length; i++) {
            rungs[i] = FlowstateC1Hook.SpreadRung({notionalCeiling: ceilings[i], extraBps: extras[i]});
        }
        hook.setSizeRungs(usdg, rungs);
    }

    /// @dev The conservative v1-shaped schedule used across the parity tests:
    ///      <= 1,000 USDG +0 bps, <= 10,000 USDG +5 bps, above +15 bps.
    function _setShipRungs() internal {
        uint128[] memory ceilings = new uint128[](3);
        uint16[] memory extras = new uint16[](3);
        ceilings[0] = 1_000e6;
        extras[0] = 0;
        ceilings[1] = 10_000e6;
        extras[1] = 5;
        ceilings[2] = 100_000e6;
        extras[2] = 15;
        _setRungs(ceilings, extras);
    }

    // -- expectation helpers (mirror the mock market's rate exactly) ----------

    function _ceilBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (bps == 0) return 0;
        return (amount * bps + 9_999) / 10_000;
    }

    function _marketTokensFor(uint256 quoteIn) internal view returns (uint256) {
        return quoteIn * market.rateNum() / market.rateDen();
    }

    function _marketCostFor(uint256 tokens) internal view returns (uint256) {
        return (tokens * market.rateDen() + market.rateNum() - 1) / market.rateNum();
    }

    struct ExactInExpectation {
        uint256 netQuote;
        uint256 tokensOut;
        uint256 quotePaid;
        uint256 spread;
        uint256 dust;
    }

    function _expectExactIn(uint256 quoteIn) internal view returns (ExactInExpectation memory e) {
        uint256 bps = hook.spreadBpsFor(usdg, Currency.wrap(address(token)), quoteIn);
        e.netQuote = bps == 0 ? quoteIn : quoteIn * 10_000 / (10_000 + bps);
        e.tokensOut = _marketTokensFor(e.netQuote);
        e.quotePaid = _marketCostFor(e.tokensOut);
        e.spread = _ceilBps(e.quotePaid, bps);
        e.dust = quoteIn - e.quotePaid - e.spread;
    }

    struct ExactOutExpectation {
        uint256 cost;
        uint256 spread;
        uint256 quoteIn;
    }

    function _expectExactOut(uint256 tokensOut) internal view returns (ExactOutExpectation memory e) {
        e.cost = _marketCostFor(tokensOut);
        uint256 bps = hook.spreadBpsFor(usdg, Currency.wrap(address(token)), e.cost);
        e.spread = _ceilBps(e.cost, bps);
        e.quoteIn = e.cost + e.spread;
    }

    // -- quoter helpers -------------------------------------------------------

    function _quoteExactIn(address caller, uint128 quoteIn) internal returns (uint256 amountOut) {
        vm.prank(caller);
        (amountOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: _buyZeroForOne(),
                exactAmount: quoteIn,
                hookData: ""
            })
        );
    }

    function _quoteExactOut(address caller, uint128 tokensOut) internal returns (uint256 amountIn) {
        vm.prank(caller);
        (amountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: _buyZeroForOne(),
                exactAmount: tokensOut,
                hookData: ""
            })
        );
    }
}

/// @notice Parity to the wei WITH spread applied, both directions, three sizes,
///         across the four spread configurations that matter (zero, base-only,
///         base+rungs below a boundary, base+rungs above it).
contract SpreadParityForkTest is SpreadTestBase {
    uint128[3] sizesIn = [uint128(10e6), uint128(1_000e6), uint128(25_000e6)];
    uint128[3] sizesOut = [uint128(20e18), uint128(2_000e18), uint128(50_000e18)];

    function _parityExactIn(string memory label) internal {
        for (uint256 i = 0; i < sizesIn.length; i++) {
            uint256 quoteIn = sizesIn[i];
            ExactInExpectation memory e = _expectExactIn(quoteIn);

            uint256 quotedFresh = _quoteExactIn(freshSender, uint128(quoteIn));
            uint256 quotedZero = _quoteExactIn(address(0), uint128(quoteIn));
            assertEq(quotedFresh, quotedZero, "quote differs by sender");
            assertEq(quotedFresh, e.tokensOut, "quote != spread-adjusted expectation");

            uint256 tokBefore = token.balanceOf(swapper);
            uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);
            uint256 spreadBefore = hook.accruedSpreadMargin(usdg);
            uint256 dustBefore = hook.accruedDust(usdg);

            vm.prank(swapper);
            _swapBuy(-int256(quoteIn), "");

            assertEq(token.balanceOf(swapper) - tokBefore, quotedFresh, "delivered != quoted");
            assertEq(usdgBefore - IERC20(USDG).balanceOf(swapper), quoteIn, "buyer paid != specified");
            assertEq(hook.accruedSpreadMargin(usdg) - spreadBefore, e.spread, "spread accrual");
            assertEq(hook.accruedDust(usdg) - dustBefore, e.dust, "dust accrual");
            console2.log(label);
            console2.log("  exactIn quoteIn / tokensOut:", quoteIn, quotedFresh);
            console2.log("  spread / dust accrued:", e.spread, e.dust);
        }
    }

    function _parityExactOut(string memory label) internal {
        for (uint256 i = 0; i < sizesOut.length; i++) {
            uint256 tokensOut = sizesOut[i];
            ExactOutExpectation memory e = _expectExactOut(tokensOut);

            uint256 quotedFresh = _quoteExactOut(freshSender, uint128(tokensOut));
            uint256 quotedZero = _quoteExactOut(address(0), uint128(tokensOut));
            assertEq(quotedFresh, quotedZero, "quote differs by sender");
            assertEq(quotedFresh, e.quoteIn, "quote != cost + spread");

            uint256 tokBefore = token.balanceOf(swapper);
            uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);
            uint256 spreadBefore = hook.accruedSpreadMargin(usdg);
            uint256 dustBefore = hook.accruedDust(usdg);

            vm.prank(swapper);
            _swapBuy(int256(tokensOut), "");

            assertEq(token.balanceOf(swapper) - tokBefore, tokensOut, "delivered != specified");
            assertEq(usdgBefore - IERC20(USDG).balanceOf(swapper), quotedFresh, "paid != quoted");
            assertEq(hook.accruedSpreadMargin(usdg) - spreadBefore, e.spread, "spread accrual");
            assertEq(hook.accruedDust(usdg) - dustBefore, 0, "exactOut must accrue no dust");
            console2.log(label);
            console2.log("  exactOut tokensOut / usdgIn:", tokensOut, quotedFresh);
            console2.log("  spread accrued:", e.spread);
        }
    }

    // -- config A: zero spread (the pre-slice baseline must be unchanged) -----

    function test_Parity_ZeroSpread_ExactIn() public {
        _parityExactIn("zero spread");
        assertEq(hook.accruedSpreadMargin(usdg), 0, "zero config must accrue nothing");
    }

    function test_Parity_ZeroSpread_ExactOut() public {
        _parityExactOut("zero spread");
        assertEq(hook.accruedSpreadMargin(usdg), 0, "zero config must accrue nothing");
    }

    // -- config B: base only, no rung schedule --------------------------------

    function test_Parity_BaseOnly_ExactIn() public {
        _setBase(16); // the measured RH oracle-drift floor
        _parityExactIn("base 16 bps, no rungs");
        assertGt(hook.accruedSpreadMargin(usdg), 0);
    }

    function test_Parity_BaseOnly_ExactOut() public {
        _setBase(16);
        _parityExactOut("base 16 bps, no rungs");
        assertGt(hook.accruedSpreadMargin(usdg), 0);
    }

    // -- config C: base + rungs, sizes straddling a rung boundary -------------

    function test_Parity_BaseAndRungs_ExactIn_CrossesBoundary() public {
        _setBase(16);
        _setShipRungs();
        // 10 and 1,000 USDG sit in rung 0 (+0); 25,000 sits in rung 2 (+15).
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1_000e6), 16, "at ceiling = that rung");
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1_000e6 + 1), 21, "one wei over the ceiling");
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 25_000e6), 31, "top rung");
        _parityExactIn("base 16 + ship rungs");
    }

    function test_Parity_BaseAndRungs_ExactOut_CrossesBoundary() public {
        _setBase(16);
        _setShipRungs();
        _parityExactOut("base 16 + ship rungs");
    }

    /// @dev Above the top ceiling the TOP rung applies (open-ended), so a huge trade
    ///      never pays fewer bps than a mid-size one.
    function test_RungAboveTopCeiling_UsesTopRung() public {
        _setBase(16);
        _setShipRungs();
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 100_000e6), 31);
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 500_000e6), 31, "open-ended top rung");
    }

    /// @dev hookData must remain irrelevant with spread configured (rule 1).
    function test_HookDataStillIgnored_WithSpread() public {
        _setBase(16);
        _setShipRungs();
        uint256 snapshot = vm.snapshotState();

        vm.prank(swapper);
        _swapBuy(-5_000e6, "");
        uint256 outEmpty = token.balanceOf(swapper);
        uint256 spreadEmpty = hook.accruedSpreadMargin(usdg);

        vm.revertToState(snapshot);

        vm.prank(swapper);
        _swapBuy(-5_000e6, hex"deadbeef0102030405ffffffffffffffffffffffff00");
        assertEq(token.balanceOf(swapper), outEmpty);
        assertEq(hook.accruedSpreadMargin(usdg), spreadEmpty);
    }
}

/// @notice Rounding: the spread never undercollects and never exceeds the configured
///         bps by more than one wei, in both directions, including against a market
///         rate whose inversion genuinely loses dust to the floor.
contract SpreadRoundingForkTest is SpreadTestBase {
    /// @dev A rate with rateDen > 1 so the market's floor inversion actually drops
    ///      units (with the default 2e12/1 rate the inversion is exact and the only
    ///      residue is the hook's own carve).
    function _setAwkwardRate() internal {
        market.setRate(3e12, 7);
        token.mint(address(market), 10_000_000e18);
    }

    function _assertExactInRounding(uint256 quoteIn) internal {
        uint256 bps = hook.spreadBpsFor(usdg, Currency.wrap(address(token)), quoteIn);
        ExactInExpectation memory e = _expectExactIn(quoteIn);

        uint256 spreadBefore = hook.accruedSpreadMargin(usdg);
        uint256 dustBefore = hook.accruedDust(usdg);
        uint256 hookBalBefore = IERC20(USDG).balanceOf(address(hook));
        uint256 marketBefore = IERC20(USDG).balanceOf(address(market));

        vm.prank(swapper);
        _swapBuy(-int256(quoteIn), "");

        uint256 spread = hook.accruedSpreadMargin(usdg) - spreadBefore;
        uint256 dust = hook.accruedDust(usdg) - dustBefore;
        uint256 quotePaid = IERC20(USDG).balanceOf(address(market)) - marketBefore;

        assertEq(quotePaid, e.quotePaid, "market pulled != expected oracle cost");

        // 1. Never undercollects: at least the exact bps product on what the market
        //    actually charged.
        assertGe(spread * 10_000, quotePaid * bps, "spread undercollected");
        // 2. Never overcharges by more than one wei-equivalent of the bps product.
        assertLt(spread * 10_000, quotePaid * bps + 10_000, "spread exceeds configured bps by >= 1 wei");
        // 3. Conservation to the wei: the buyer's whole payment is cost + spread + dust.
        assertEq(quotePaid + spread + dust, quoteIn, "quoteIn conservation");
        // 4. The carve can never make the split negative (the floor guarantee).
        assertEq(IERC20(USDG).balanceOf(address(hook)) - hookBalBefore, spread + dust, "hook balance == accruals");
        // 5. The buyer's effective rate is never better than the configured spread.
        assertGe((quoteIn - quotePaid) * 10_000, quotePaid * bps, "buyer paid less than configured spread");
    }

    function _assertExactOutRounding(uint256 tokensOut) internal {
        ExactOutExpectation memory e = _expectExactOut(tokensOut);
        uint256 bps = hook.spreadBpsFor(usdg, Currency.wrap(address(token)), e.cost);

        uint256 spreadBefore = hook.accruedSpreadMargin(usdg);
        uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);

        vm.prank(swapper);
        _swapBuy(int256(tokensOut), "");

        uint256 spread = hook.accruedSpreadMargin(usdg) - spreadBefore;
        uint256 paid = usdgBefore - IERC20(USDG).balanceOf(swapper);

        assertEq(paid, e.cost + spread, "buyer paid != cost + spread");
        assertGe(spread * 10_000, e.cost * bps, "spread undercollected");
        assertLt(spread * 10_000, e.cost * bps + 10_000, "spread exceeds configured bps by >= 1 wei");
        assertEq(hook.accruedDust(usdg), 0, "exactOut accrues no dust");
    }

    function test_Rounding_ExactIn_OddSizes_DefaultRate() public {
        _setBase(16);
        _setShipRungs();
        // Two raw units is the smallest ticket the carve still leaves priceable (see
        // the boundary test below); everything at or above it must round cleanly.
        uint256[5] memory sizes =
            [uint256(2), uint256(1_009), uint256(1_000_001), uint256(3_333_333), uint256(9_999_999_999)];
        for (uint256 i = 0; i < sizes.length; i++) {
            _assertExactInRounding(sizes[i]);
        }
    }

    /// @dev The carve's lower boundary: below it the hook raises its OWN typed error
    ///      rather than letting the market's ZeroAmount surface, and it does so
    ///      identically in the quoter simulation and the real swap (rule 2).
    function test_SubDustTicket_RevertsTypedInQuoterAndSwap() public {
        _setBase(16); // netQuote = floor(quoteIn * 10000 / 10016)

        // The carve only strands a ticket at the very bottom: netQuote == 0 iff
        // quoteIn * 10_000 < 10_000 + spreadBps, i.e. exactly one raw unit for any
        // nonzero spread below 100%.
        uint256 smallestPriceable = 2;
        assertEq(smallestPriceable * 10_000 / 10_016, 1, "two raw units still price");
        assertEq(uint256(1) * 10_000 / 10_016, 0, "one raw unit is unpriceable");

        vm.prank(swapper);
        _swapBuy(-int256(smallestPriceable), ""); // executes

        try this.swapBuyExternal(-int256(uint256(1))) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.TradeTooSmallForSpread.selector), "swap typed revert");
        }

        vm.prank(freshSender);
        try quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: _buyZeroForOne(),
                exactAmount: uint128(1),
                hookData: ""
            })
        ) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(
                _containsSelector(reason, FlowstateC1Hook.TradeTooSmallForSpread.selector), "quoter typed revert"
            );
        }
    }

    function swapBuyExternal(int256 amountSpecified) external {
        _swapBuy(amountSpecified, "");
    }

    function test_Rounding_ExactIn_OddSizes_AwkwardRate() public {
        _setAwkwardRate();
        _setBase(23); // the Base-chain floor, the highest measured
        _setShipRungs();
        uint256[4] memory sizes = [uint256(1_009), uint256(999_983), uint256(12_345_679), uint256(7_777_777_777)];
        for (uint256 i = 0; i < sizes.length; i++) {
            _assertExactInRounding(sizes[i]);
        }
    }

    function test_Rounding_ExactOut_OddSizes_AwkwardRate() public {
        _setAwkwardRate();
        _setBase(23);
        _setShipRungs();
        uint256[4] memory sizes = [uint256(1e12 + 1), uint256(3e15 + 7), uint256(101e18 + 3), uint256(999e18)];
        for (uint256 i = 0; i < sizes.length; i++) {
            _assertExactOutRounding(sizes[i]);
        }
    }

    function testFuzz_Rounding_ExactIn_NeverUndercollects(uint96 rawQuoteIn, uint16 rawBps) public {
        uint256 quoteIn = bound(uint256(rawQuoteIn), 1_000, 200_000e6);
        uint16 bps = uint16(bound(uint256(rawBps), 0, 1_000));
        _setBase(bps);
        _assertExactInRounding(quoteIn);
    }

    function testFuzz_Rounding_ExactOut_NeverUndercollects(uint96 rawTokensOut, uint16 rawBps) public {
        uint256 tokensOut = bound(uint256(rawTokensOut), 1e12, 100_000e18);
        uint16 bps = uint16(bound(uint256(rawBps), 0, 1_000));
        _setBase(bps);
        _assertExactOutRounding(tokensOut);
    }
}

/// @notice Accrual, sweep, and the custody invariant from scope §8: outside an unlock
///         the hook's ONLY balance is accrued margin + dust.
contract SpreadSweepForkTest is SpreadTestBase {
    address sweepTo = makeAddr("margin-sweep-wallet");

    function _accrueOverSeveralFills() internal returns (uint256 spread, uint256 dust) {
        _setBase(16);
        _setShipRungs();
        vm.startPrank(swapper);
        _swapBuy(-500e6, "");
        _swapBuy(-5_000e6, "");
        _swapBuy(-25_000e6, "");
        _swapBuy(int256(2_000e18), "");
        _swapBuy(int256(150_000e18), "");
        vm.stopPrank();
        spread = hook.accruedSpreadMargin(usdg);
        dust = hook.accruedDust(usdg);
    }

    function test_MarginAccruesPerAsset_AndMatchesBalance() public {
        (uint256 spread, uint256 dust) = _accrueOverSeveralFills();
        assertGt(spread, 0, "spread must accrue");
        assertEq(IERC20(USDG).balanceOf(address(hook)), spread + dust, "hook balance == accruals exactly");
        // Accrual is keyed per quote asset: an untouched asset stays at zero.
        assertEq(hook.accruedSpreadMargin(Currency.wrap(AEWETH)), 0, "unrelated asset must not accrue");
    }

    /// @dev Scope §8 invariant: between unlocks the hook holds NOTHING but margin —
    ///      no inventory token, no unaccounted quote asset.
    function test_Invariant_HookHoldsZeroNonMarginBalance() public {
        (uint256 spread, uint256 dust) = _accrueOverSeveralFills();
        assertEq(token.balanceOf(address(hook)), 0, "hook must hold no inventory token");
        assertEq(IERC20(USDG).balanceOf(address(hook)) - (spread + dust), 0, "no unaccounted quote balance");
        assertEq(address(hook).balance, 0, "hook must hold no ETH");
    }

    function test_Sweep_TransfersExactlyAccrued_AndZeroesHook() public {
        (uint256 spread, uint256 dust) = _accrueOverSeveralFills();
        hook.setSweepDestination(sweepTo);

        uint256 swept = hook.sweepMargin(usdg);

        assertEq(swept, spread + dust, "swept != accrued");
        assertEq(IERC20(USDG).balanceOf(sweepTo), spread + dust, "destination received exactly accrued");
        assertEq(IERC20(USDG).balanceOf(address(hook)), 0, "hook balance must return to zero");
        assertEq(hook.accruedSpreadMargin(usdg), 0, "spread counter reset");
        assertEq(hook.accruedDust(usdg), 0, "dust counter reset");
    }

    function test_Sweep_EmitsSplitForReconciliation() public {
        (uint256 spread, uint256 dust) = _accrueOverSeveralFills();
        hook.setSweepDestination(sweepTo);

        vm.expectEmit(true, true, false, true, address(hook));
        emit FlowstateC1Hook.MarginSwept(usdg, sweepTo, spread, dust, spread + dust);
        hook.sweepMargin(usdg);
    }

    /// @dev Accrual resumes cleanly after a sweep (counters are not one-shot).
    function test_Sweep_ThenAccrueAgain() public {
        _accrueOverSeveralFills();
        hook.setSweepDestination(sweepTo);
        hook.sweepMargin(usdg);

        vm.prank(swapper);
        _swapBuy(-1_000e6, "");
        assertGt(hook.accruedSpreadMargin(usdg), 0, "accrual resumes after sweep");
        assertEq(
            IERC20(USDG).balanceOf(address(hook)),
            hook.accruedSpreadMargin(usdg) + hook.accruedDust(usdg),
            "invariant holds post-sweep"
        );
    }

    /// @dev Force-sent donations are recoverable through the same path (mirrors the
    ///      executor's stuck-dust recovery) and are reported as the excess over the
    ///      accrual split.
    function test_Sweep_RecoversForceSentDonation() public {
        (uint256 spread, uint256 dust) = _accrueOverSeveralFills();
        deal(USDG, address(this), 1_000e6);
        IERC20(USDG).transfer(address(hook), 1_000e6);
        hook.setSweepDestination(sweepTo);

        uint256 swept = hook.sweepMargin(usdg);
        assertEq(swept, spread + dust + 1_000e6, "donation recovered");
        assertEq(IERC20(USDG).balanceOf(address(hook)), 0);
    }

    /// @dev The one asymmetry in the exactOut path: the market SKIPS the fundBuy
    ///      callback when the hook's own accrued margin already covers the cost, in
    ///      which case the market pulls that margin and the hook must take the full
    ///      cost + spread from the PoolManager instead of just the spread. The hook
    ///      reads the flash-accounting ledger (currencyDelta) rather than assuming a
    ///      shape, so both shapes must net identically. Proven here by driving a fill
    ///      of each shape and comparing.
    function test_ExactOut_NetsIdentically_WhenFundBuyCallbackIsSkipped() public {
        _setBase(16);

        // Shape 1: no margin on the hook yet -> the callback RUNS.
        assertEq(IERC20(USDG).balanceOf(address(hook)), 0, "precondition: hook empty");
        ExactOutExpectation memory e1 = _expectExactOut(100e18);
        uint256 usdgBefore1 = IERC20(USDG).balanceOf(swapper);
        uint256 managerBefore = IERC20(USDG).balanceOf(POOL_MANAGER);
        vm.prank(swapper);
        _swapBuy(int256(uint256(100e18)), "");
        assertEq(usdgBefore1 - IERC20(USDG).balanceOf(swapper), e1.cost + e1.spread, "callback shape: buyer paid");
        assertEq(IERC20(USDG).balanceOf(address(hook)), e1.spread, "callback shape: hook holds exactly spread");
        assertEq(IERC20(USDG).balanceOf(POOL_MANAGER), managerBefore, "manager nets zero");

        // Build margin until it comfortably exceeds the next fill's cost, so the
        // market's skip rule (balance >= cost) fires.
        vm.startPrank(swapper);
        _swapBuy(-50_000e6, "");
        _swapBuy(-50_000e6, "");
        vm.stopPrank();

        ExactOutExpectation memory e2 = _expectExactOut(100e18);
        uint256 marginBefore = IERC20(USDG).balanceOf(address(hook));
        assertGt(marginBefore, e2.cost, "precondition: margin covers the cost, callback will be skipped");

        uint256 spreadCounterBefore = hook.accruedSpreadMargin(usdg);
        uint256 usdgBefore2 = IERC20(USDG).balanceOf(swapper);
        managerBefore = IERC20(USDG).balanceOf(POOL_MANAGER);

        vm.prank(swapper);
        _swapBuy(int256(uint256(100e18)), "");

        // Identical economics to shape 1: same cost, same spread, manager nets zero,
        // and the hook's balance grew by exactly the spread (its margin was used as
        // transient working capital and fully restored).
        assertEq(usdgBefore2 - IERC20(USDG).balanceOf(swapper), e2.cost + e2.spread, "skip shape: buyer paid");
        assertEq(e2.spread, e1.spread, "same spread both shapes");
        assertEq(IERC20(USDG).balanceOf(address(hook)) - marginBefore, e2.spread, "skip shape: margin restored + spread");
        assertEq(hook.accruedSpreadMargin(usdg) - spreadCounterBefore, e2.spread, "skip shape: accrual");
        assertEq(IERC20(USDG).balanceOf(POOL_MANAGER), managerBefore, "manager nets zero");
        assertEq(
            IERC20(USDG).balanceOf(address(hook)),
            hook.accruedSpreadMargin(usdg) + hook.accruedDust(usdg),
            "invariant survives the skip shape"
        );
    }

    function test_Sweep_RevertsForNonOwner() public {
        _accrueOverSeveralFills();
        hook.setSweepDestination(sweepTo);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        hook.sweepMargin(usdg);
    }

    function test_Sweep_RevertsWhenDestinationUnset() public {
        _accrueOverSeveralFills();
        vm.expectRevert(FlowstateC1Hook.SweepDestinationNotSet.selector);
        hook.sweepMargin(usdg);
    }

    function test_SweepETH_RecoversForceSentEth() public {
        hook.setSweepDestination(sweepTo);
        vm.deal(address(hook), 3 ether);

        uint256 swept = hook.sweepETH();
        assertEq(swept, 3 ether);
        assertEq(sweepTo.balance, 3 ether);
        assertEq(address(hook).balance, 0);
    }

    function test_SweepETH_RevertsForNonOwner() public {
        hook.setSweepDestination(sweepTo);
        vm.deal(address(hook), 1 ether);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        hook.sweepETH();
    }

    function test_SetSweepDestination_RejectsZeroAndNonOwner() public {
        vm.expectRevert(FlowstateC1Hook.ZeroAddress.selector);
        hook.setSweepDestination(address(0));

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        hook.setSweepDestination(sweepTo);
    }
}

/// @notice Config surface: access control, the config-time floor, and rung-schedule
///         edge cases. Documented choice: unordered/invalid schedules are REJECTED,
///         never normalized.
contract SpreadConfigForkTest is SpreadTestBase {
    address attacker = makeAddr("attacker");

    function _rungs(uint128 c0, uint16 e0, uint128 c1, uint16 e1)
        internal
        pure
        returns (FlowstateC1Hook.SpreadRung[] memory r)
    {
        r = new FlowstateC1Hook.SpreadRung[](2);
        r[0] = FlowstateC1Hook.SpreadRung({notionalCeiling: c0, extraBps: e0});
        r[1] = FlowstateC1Hook.SpreadRung({notionalCeiling: c1, extraBps: e1});
    }

    // -- access control -------------------------------------------------------

    function test_AccessControl_AllSettersOwnerOnly() public {
        vm.startPrank(attacker);
        vm.expectRevert();
        hook.setBaseSpread(usdg, Currency.wrap(address(token)), 20);
        vm.expectRevert();
        hook.setBaseSpreadFloor(16);
        vm.expectRevert();
        hook.setSizeRungs(usdg, new FlowstateC1Hook.SpreadRung[](0));
        vm.expectRevert();
        hook.registerPair(usdg, Currency.wrap(address(token)), address(market), 0);
        vm.expectRevert();
        hook.setResellerCode("x");
        vm.stopPrank();
    }

    function test_SetBaseSpread_RevertsForUnregisteredPair() public {
        vm.expectRevert(FlowstateC1Hook.PairNotRegistered.selector);
        hook.setBaseSpread(usdg, Currency.wrap(AEWETH), 20);
    }

    // -- floor + cap (config time only) --------------------------------------

    function test_BaseSpreadFloor_EnforcedAtConfigTime() public {
        hook.setBaseSpreadFloor(16); // the measured RH oracle-drift floor

        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, uint16(15), uint16(16), uint16(1_000)));
        hook.setBaseSpread(usdg, Currency.wrap(address(token)), 15);

        hook.setBaseSpread(usdg, Currency.wrap(address(token)), 16); // exactly at the floor is fine
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1e6), 16);
    }

    function test_BaseSpreadFloor_AppliesToRegisterPairToo() public {
        hook.setBaseSpreadFloor(16);
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, uint16(0), uint16(16), uint16(1_000)));
        hook.registerPair(usdg, Currency.wrap(AEWETH), address(market), 0);
    }

    /// @dev Raising the floor deliberately does NOT retro-check registered pairs, and
    ///      the swap path never re-validates config: an existing pair keeps trading at
    ///      its old spread until the runbook re-sets it.
    function test_RaisingFloor_DoesNotRetroBreakExistingPairsOrSwaps() public {
        hook.setBaseSpread(usdg, Currency.wrap(address(token)), 5);
        hook.setBaseSpreadFloor(50);

        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1e6), 5, "stored spread unchanged");
        vm.prank(swapper);
        _swapBuy(-1_000e6, ""); // hot path does not re-check the floor
        assertGt(hook.accruedSpreadMargin(usdg), 0);
    }

    function test_BaseSpread_RejectsAboveHardCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, uint16(1_001), uint16(0), uint16(1_000))
        );
        hook.setBaseSpread(usdg, Currency.wrap(address(token)), 1_001);
    }

    function test_SetBaseSpreadFloor_RejectsAboveHardCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, uint16(1_001), uint16(0), uint16(1_000))
        );
        hook.setBaseSpreadFloor(1_001);
    }

    // -- rung schedule edge cases --------------------------------------------

    function test_Rungs_EmptyScheduleIsBaseSpreadOnly() public {
        hook.setBaseSpread(usdg, Currency.wrap(address(token)), 16);
        assertEq(hook.sizeRungs(usdg).length, 0, "ship default is an empty schedule");
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1e6), 16);
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1_000_000e6), 16, "size irrelevant when empty");
    }

    function test_Rungs_SingleRungAppliesEverywhere() public {
        hook.setBaseSpread(usdg, Currency.wrap(address(token)), 10);
        FlowstateC1Hook.SpreadRung[] memory r = new FlowstateC1Hook.SpreadRung[](1);
        r[0] = FlowstateC1Hook.SpreadRung({notionalCeiling: 1_000e6, extraBps: 7});
        hook.setSizeRungs(usdg, r);

        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1), 17, "below ceiling");
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1_000e6), 17, "at ceiling");
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1_000e6 + 1), 17, "above: top rung applies");
    }

    function test_Rungs_RejectsUnorderedCeilings() public {
        vm.expectRevert(FlowstateC1Hook.RungScheduleInvalid.selector);
        hook.setSizeRungs(usdg, _rungs(10_000e6, 5, 1_000e6, 10));
    }

    function test_Rungs_RejectsDuplicateCeilings() public {
        vm.expectRevert(FlowstateC1Hook.RungScheduleInvalid.selector);
        hook.setSizeRungs(usdg, _rungs(1_000e6, 5, 1_000e6, 10));
    }

    function test_Rungs_RejectsDecreasingExtraBps() public {
        vm.expectRevert(FlowstateC1Hook.RungScheduleInvalid.selector);
        hook.setSizeRungs(usdg, _rungs(1_000e6, 10, 10_000e6, 5));
    }

    function test_Rungs_RejectsZeroCeiling() public {
        vm.expectRevert(FlowstateC1Hook.RungScheduleInvalid.selector);
        hook.setSizeRungs(usdg, _rungs(0, 5, 10_000e6, 10));
    }

    function test_Rungs_RejectsExtraBpsAboveCap() public {
        vm.expectRevert(FlowstateC1Hook.RungScheduleInvalid.selector);
        hook.setSizeRungs(usdg, _rungs(1_000e6, 1_001, 10_000e6, 1_001));
    }

    function test_Rungs_ReplacingScheduleClearsTheOldOne() public {
        _setShipRungs();
        assertEq(hook.sizeRungs(usdg).length, 3);

        FlowstateC1Hook.SpreadRung[] memory r = new FlowstateC1Hook.SpreadRung[](1);
        r[0] = FlowstateC1Hook.SpreadRung({notionalCeiling: 50e6, extraBps: 1});
        hook.setSizeRungs(usdg, r);
        assertEq(hook.sizeRungs(usdg).length, 1, "old rungs must not survive");
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 25_000e6), 1, "old top rung is gone");

        hook.setSizeRungs(usdg, new FlowstateC1Hook.SpreadRung[](0));
        assertEq(hook.sizeRungs(usdg).length, 0, "cleared back to the ship default");
    }

    /// @dev Rungs are keyed per quote asset: a USDG schedule must not leak onto aeWETH
    ///      (raw notionals are not comparable across decimals).
    function test_Rungs_AreKeyedPerQuoteAsset() public {
        _setShipRungs();
        assertEq(hook.sizeRungs(Currency.wrap(AEWETH)).length, 0, "aeWETH schedule untouched");
    }

    function test_RegisterPair_StoresBaseSpread() public {
        hook.registerPair(usdg, Currency.wrap(address(token)), address(market), 42);
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1e6), 42);
    }
}
