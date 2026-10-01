// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {ListingStandIn} from "./ListingStandIn.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/**
 * Native-quoted V4 pools (v1 decision, 2026-07-30: pulled forward from phase 2 —
 * native carries ~3x aeWETH's volume inside RH V4 per the quote-asset share report).
 *
 * The design under test: ONE wrapped-quote C1 pool serves BOTH V4 currency
 * representations. A native-quoted V4 pool wires to the SAME multi-asset C1 pool via
 * its aeWETH anchor; the hook takes native from the PoolManager, wraps, and the
 * market's pull-exact transferFrom proceeds in the wrapper. Buy-only means only
 * `deposit` is ever needed — the unwrap direction cannot occur.
 *
 * 29 Sep 2026: the native swap tests here (exact input and exact output through the wrap, margin
 * in the wrapper, both doors sharing one C1 pool, the jar paid in the wrapper) ran the deleted
 * Gen-3 path and are retired. The Gen-4 native path is covered offline
 * (test/Gen4HookIntegration.t.sol: test_NativeQuotePoolLegWrapsAndLeavesNoBalance, the design E
 * two-door tests) and on the Robinhood Chain fork (test/stack/fork-rh-gen4.cjs sections [4], [10]).
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
}

contract NativeQuoteForkTest is NativeQuoteFixture {
    /// @dev Rung unification: schedules key on the MARKET asset, so the wrapper's
    ///      schedule governs native pools too — one schedule to maintain per economic
    ///      asset, no drift between the two V4 representations of the same value.
    ///      29 Sep 2026: the end-to-end half (a native swap accruing at 75 bps) ran the
    ///      deleted Gen-3 path and is retired; the swap computes the same _spreadBps as
    ///      spreadBpsFor, and test/stack/gen4-stack.test.cjs ("spread rungs") checks that a
    ///      swap charges exactly the spreadBpsFor bps.
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
        (address standInRegistry, address standInSettlement) = ListingStandIn.deploy(address(market));
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(FlowstateC1Hook).creationCode,
            abi.encode(POOL_MANAGER, address(market), address(this), address(0), TOKEN_JAR, 0, standInRegistry, standInSettlement)
        );
        FlowstateC1Hook bare = new FlowstateC1Hook{salt: salt}(
            POOL_MANAGER, address(market), address(this), address(0), TOKEN_JAR, 0, standInRegistry, standInSettlement
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
