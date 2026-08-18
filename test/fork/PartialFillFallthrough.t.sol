// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {MockInventoryToken} from "../mocks/MockInventoryToken.sol";

/// @notice JUP-559 DD. Measures what the V4 CORE does with input a hook does not
///         consume, in the exact configuration our hooked pools run: tickSpacing 60,
///         no real LP liquidity, only the 1-wei visibility beacon in a single
///         tickSpacing, and a router passing MIN/MAX sqrtPrice (no price limit).
///
///         This is the load-bearing measurement for whether the hook may safely
///         return a PARTIAL BeforeSwapDelta. Two questions, both measured here
///         rather than reasoned about:
///
///           Q2  Does the swapper get a terrible fill on the remainder, or is the
///               remainder left unconsumed?
///           C7  What does the tick-bitmap walk to the price limit actually COST?
///
///         The pool here is hookless on purpose: a hook that consumes nothing is
///         behaviourally identical to no hook at all for the core's swap loop, so
///         this isolates the core's fall-through from anything our hook does.
contract PartialFillFallthroughTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    bytes32 constant LIVE_CASHCAT_POOL_ID = 0x626d6ca49f8b0198632914a934d67533dfbc12e6e9434a573fbbd8208ce1b01f;

    IPoolManager pm;
    PoolModifyLiquidityTest liqRouter;
    PoolSwapTest swapRouter;
    MockInventoryToken tokenA;
    MockInventoryToken tokenB;

    PoolKey key;
    Currency c0;
    Currency c1;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("robinhood"));
        pm = IPoolManager(POOL_MANAGER);
        liqRouter = new PoolModifyLiquidityTest(pm);
        swapRouter = new PoolSwapTest(pm);

        tokenA = new MockInventoryToken();
        tokenB = new MockInventoryToken();
        tokenA.mint(address(this), 1e24);
        tokenB.mint(address(this), 1e24);
        tokenA.approve(address(liqRouter), type(uint256).max);
        tokenB.approve(address(liqRouter), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);

        (c0, c1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        // the live hooked pool's real price, so the tick distance to the bounds is
        // the REAL distance our pools face, not a synthetic one
        (uint160 liveSqrtPrice,,,) = IStateView(STATE_VIEW).getSlot0(PoolId.wrap(LIVE_CASHCAT_POOL_ID));
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(0))});
        pm.initialize(key, liveSqrtPrice);

        // the beacon: liquidityDelta == 1, one tickSpacing wide, above the current tick
        int24 tick = TickMath.getTickAtSqrtPrice(liveSqrtPrice);
        int24 lower = ((tick / 60) + 1) * 60;
        liqRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: lower + 60, liquidityDelta: 1, salt: 0}), ""
        );
        emit log_named_int("current tick", tick);
        emit log_named_int("beacon lower", lower);
    }

    /// @dev The measurement. An exact-INPUT swap of 5,000 units with no price limit,
    ///      against a pool holding only the beacon. If the core charges the full input
    ///      for ~nothing, partial fill is unsafe and JUP-559 must be abandoned in this
    ///      shape. If the input is left unconsumed, partial fill is representable.
    function test_fallthrough_zeroForOne() public {
        _measure(true, 5_000e6);
    }

    function test_fallthrough_oneForZero() public {
        _measure(false, 5_000e6);
    }

    function _measure(bool zeroForOne, uint256 amountIn) internal {
        Currency inC = zeroForOne ? c0 : c1;
        Currency outC = zeroForOne ? c1 : c0;

        uint256 inBefore = _bal(inC);
        uint256 outBefore = _bal(outC);

        uint256 g0 = gasleft();
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn), // negative == exact input
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 gasUsed = g0 - gasleft();

        uint256 consumed = inBefore - _bal(inC);
        uint256 received = _bal(outC) - outBefore;

        emit log_named_string("direction", zeroForOne ? "zeroForOne" : "oneForZero");
        emit log_named_uint("input specified", amountIn);
        emit log_named_uint("input ACTUALLY consumed", consumed);
        emit log_named_uint("output received", received);
        emit log_named_uint("GAS USED (tick walk to limit)", gasUsed);
        emit log_named_int("delta amount0", delta.amount0());
        emit log_named_int("delta amount1", delta.amount1());

        // The claim under test: core must NOT charge input it did not swap.
        assertLt(consumed, amountIn, "core consumed the FULL input against an empty pool");
    }

    /// @dev Robin (independent cross-vendor review, 2026-08-18) flagged a failure mode
    ///      the fall-through measurement above does NOT cover: the residual swap moves
    ///      slot0 and PERSISTS it. Today the hook fully offsets amountSpecified, so
    ///      Pool.swap sees amountToSwap == 0 and returns BEFORE the price-limit checks.
    ///      A partial delta removes that early return. If the residual parks the price
    ///      at the limit, and the hook refuses the sell direction so nothing can push it
    ///      back, then every later swap reverts PriceLimitAlreadyExceeded and the pool
    ///      is bricked after exactly one partial fill.
    ///
    ///      This measures whether that actually happens.
    function test_residualParksPriceAndBricksTheNextSwap() public {
        (uint160 before_,,,) = IStateView(STATE_VIEW).getSlot0(_id());
        emit log_named_uint("slot0 sqrtPrice BEFORE", before_);

        _rawSwap(true, 5_000e6, TickMath.MIN_SQRT_PRICE + 1);

        (uint160 after_,,,) = IStateView(STATE_VIEW).getSlot0(_id());
        emit log_named_uint("slot0 sqrtPrice AFTER ", after_);
        emit log_named_uint("MIN_SQRT_PRICE + 1     ", uint256(TickMath.MIN_SQRT_PRICE) + 1);
        emit log_named_string("price PARKED at limit", after_ == TickMath.MIN_SQRT_PRICE + 1 ? "YES" : "no");

        // the decisive question: can a second buy still happen?
        try this.rawSwapExternal(true, 1_000e6, TickMath.MIN_SQRT_PRICE + 1) {
            emit log_named_string("second swap", "SUCCEEDED - pool not bricked");
        } catch {
            emit log_named_string("second swap", "REVERTED - POOL BRICKED");
        }
    }

    /// @dev Robin's other case: a router passing the LITERAL MIN/MAX constants (not
    ///      +/-1). Today that is survivable because amountToSwap == 0 short-circuits
    ///      before validation. With a residual it should hit PriceLimitOutOfBounds.
    function test_literalMinMaxLimit_isRejectedOnceAResidualExists() public {
        try this.rawSwapExternal(true, 5_000e6, TickMath.MIN_SQRT_PRICE) {
            emit log_named_string("literal MIN_SQRT_PRICE", "accepted");
        } catch {
            emit log_named_string("literal MIN_SQRT_PRICE", "REVERTED (PriceLimitOutOfBounds)");
        }
    }

    /// @dev OPTION B feasibility. If a partial fill parks the price, can the hook walk it
    ///      back inside afterSwap by swapping its OWN pool in reverse with the limit set
    ///      to the pre-swap price? v4-core's Hooks.beforeSwap/afterSwap both begin
    ///      `if (msg.sender == address(self)) return`, so a hook self-swap skips its own
    ///      logic and cannot recurse, and PoolManager.swap needs only onlyWhenUnlocked,
    ///      which already holds inside a hook callback. This measures whether the repair
    ///      leg actually restores slot0 with only the 1-wei beacon present, what it
    ///      costs, and whether the pool is usable again afterwards.
    function test_optionB_reverseSwapRepairsTheParkedPrice() public {
        (uint160 orig,,,) = IStateView(STATE_VIEW).getSlot0(_id());

        _rawSwap(true, 5_000e6, TickMath.MIN_SQRT_PRICE + 1); // park it
        (uint160 parked,,,) = IStateView(STATE_VIEW).getSlot0(_id());
        emit log_named_uint("parked at", parked);

        // the repair leg: reverse direction, limit = the ORIGINAL price
        uint256 g0 = gasleft();
        try this.rawSwapExternal(false, 5_000e6, orig) {
            emit log_named_uint("repair gas", g0 - gasleft());
            (uint160 repaired,,,) = IStateView(STATE_VIEW).getSlot0(_id());
            emit log_named_uint("original ", orig);
            emit log_named_uint("repaired ", repaired);
            emit log_named_string("price RESTORED exactly", repaired == orig ? "YES" : "NO");

            try this.rawSwapExternal(true, 1_000e6, TickMath.MIN_SQRT_PRICE + 1) {
                emit log_named_string("buy direction usable again", "YES - option B viable");
            } catch {
                emit log_named_string("buy direction usable again", "NO - still bricked");
            }
        } catch {
            emit log_named_string("repair leg", "REVERTED - option B dead");
        }
    }

    function rawSwapExternal(bool zeroForOne, uint256 amountIn, uint160 limit) external {
        _rawSwap(zeroForOne, amountIn, limit);
    }

    function _rawSwap(bool zeroForOne, uint256 amountIn, uint160 limit) internal {
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _id() internal view returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }

    function _bal(Currency c) internal view returns (uint256) {
        return MockInventoryToken(Currency.unwrap(c)).balanceOf(address(this));
    }
}
