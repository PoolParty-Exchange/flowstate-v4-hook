// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice JUP-559 verification, option D'. Routes a buy that EXCEEDS pool inventory
///         through the REAL canonical UniversalRouter deployed on Robinhood Chain, and
///         asserts the swapper is charged only for what we actually filled.
///
///         Why this is the decisive test rather than a PoolSwapTest one: the whole
///         mechanism depends on the router settling its LIVE open debt rather than the
///         amount it originally specified. v4-periphery's SETTLE_ALL calls
///         `_getFullDebt(currency)`, which reads `poolManager.currencyDelta(...)`, and
///         treats its `maxAmount` as an upper bound. Reading that source is suggestive;
///         running the real deployed bytecode is proof.
///
///         The hook fully offsets amountSpecified (so amountToSwap == 0 and no residual
///         ever reaches the core AMM, which is what avoids the measured price-parking
///         brick in PartialFillFallthrough.t.sol) and hands the unfilled remainder back
///         with settleFor(sender).
contract UniversalRouterPartialFillTest is ForkTestBase {
    using PoolIdLibrary for PoolKey;
    // canonical, verified deployment on chain 4663 (router-share attribution table)
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 constant V4_SWAP = 0x10;

    function setUp() public override {
        super.setUp();

        // swapper pays the router through Permit2, exactly as a real user would
        vm.startPrank(swapper);
        IERC20(USDG).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(USDG, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @dev Inventory is left covering only PART of the ask. Rate is 5e5, i.e. 1 token
    ///      costs 0.5 USDG, so 1,000 tokens of inventory is worth 500 USDG. We ask to
    ///      spend 5,000 USDG, which is ten times what the pool can serve.
    function test_realUniversalRouter_chargesOnlyForWhatWeFilled() public {
        vm.prank(lister);
        market.withdrawTokens(pool, 0); // empty it
        _contributeInventory(1_000e18); // 1,000 tokens == 500 USDG of depth

        uint128 amountIn = 5_000e6; // ten times available depth

        uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);
        uint256 tokBefore = token.balanceOf(swapper);

        _routeThroughUniversalRouter(amountIn);

        uint256 spent = usdgBefore - IERC20(USDG).balanceOf(swapper);
        uint256 received = token.balanceOf(swapper) - tokBefore;

        emit log_named_uint("amountIn specified ", amountIn);
        emit log_named_uint("USDG actually spent", spent);
        emit log_named_uint("tokens received    ", received);
        emit log_named_uint("pool inventory left", poolContract.tokenBalance());

        // THE CLAIM: the real router settled its live open debt, not the 5,000 it asked
        // for. If this fails, option D' is dead and the router pre-pays the full amount.
        assertLt(spent, amountIn, "router charged the FULL specified input");
        assertEq(received, 1_000e18, "should have filled the entire remaining inventory");
        assertEq(poolContract.tokenBalance(), 0, "inventory should be fully consumed");

        // and the swapper must not have overpaid for what it got: at rate 5e5, 1,000
        // tokens cost 500 USDG, plus the hook spread (zero by ship default here).
        assertEq(spent, 500e6, "charged exactly the oracle cost of the tokens delivered");
    }

    /// @dev The load-bearing safety property of option D'. The earlier partial-delta
    ///      design was abandoned because the unconsumed remainder walked the pool price
    ///      to the router's limit and PARKED it there, and since the hook refuses the
    ///      sell direction nothing could move it back, so one partial fill bricked the
    ///      pool permanently (measured in PartialFillFallthrough.t.sol).
    ///
    ///      D' is supposed to make that unreachable by construction: the hook offsets
    ///      the ENTIRE specified amount, so amountToSwap == 0 and Pool.swap takes its
    ///      zero-amount early return before any swap loop or price-limit check runs.
    ///      Asserting "we charged less" does NOT prove that. Asserting the price never
    ///      moved does. A SHORT fill is the case that would leave a residual, so it is
    ///      the case that has to be pinned.
    function test_partialFill_doesNotMoveThePoolPriceAtAll() public {
        vm.prank(lister);
        market.withdrawTokens(pool, 0);
        _contributeInventory(1_000e18); // 500 USDG of depth

        (uint160 before_,,,) = IStateView(STATE_VIEW).getSlot0(poolKey.toId());

        _routeThroughUniversalRouter(5_000e6); // ten times available depth: a SHORT fill

        (uint160 after_,,,) = IStateView(STATE_VIEW).getSlot0(poolKey.toId());
        emit log_named_uint("slot0 before", before_);
        emit log_named_uint("slot0 after ", after_);

        assertEq(after_, before_, "a short fill moved the pool price: a residual reached the core AMM");

        // and the pool must still be usable afterwards, which is what bricking destroyed
        _contributeInventory(1_000e18);
        uint256 tokBefore = token.balanceOf(swapper);
        _routeThroughUniversalRouter(200e6);
        assertEq(token.balanceOf(swapper) - tokBefore, 400e18, "pool unusable after a partial fill");
    }

    /// @dev REGRESSION. The short-fill discriminator must compare the unspent NET quote
    ///      against the one-token-wei inversion residue, and nothing else. An earlier
    ///      revision compared `leftover` against `quoteIn - netQuote + inversionBound`,
    ///      which cancels to `netQuote - quotePaid > spreadAccrued + inversionBound`: a
    ///      genuine shortfall of up to the whole spread was therefore classified as
    ///      ordinary dust and SILENTLY KEPT by the hook.
    ///
    ///      The window only opens when the spread is non-zero AND the rate is high enough
    ///      that one token-wei costs many quote-wei, which is why the default fixture
    ///      never revealed it. Both conditions are forced here.
    ///
    ///      Disabling the fix (restoring the `quoteIn - netQuote + inversionBound` form)
    ///      makes this test fail on the `spent < amountIn` assertion, because the hook
    ///      charges the full input and books the difference as sweepable margin.
    function test_shortFill_isNotMisreadAsDust_whenSpreadAndRateAreHigh() public {
        // one token-wei costs many quote-wei: the regime where the floor inversion
        // discards more than a wei, and where the old bound was too generous
        _setOracleRate(DUST_ORACLE_RATE);
        hook.setBaseSpread(Currency.wrap(USDG), Currency.wrap(address(token)), 30);
        _expireRateCache();

        vm.prank(lister);
        market.withdrawTokens(pool, 0);
        // Sized INTO the false-FULL band, which is the whole point. At this rate a
        // 5,000 USDG ask inverts to 498,504,486 token-wei. With 498,000,000 of inventory
        // the unspent net quote is 5,044,864: above the one-token-wei inversion bound of
        // 11 (so genuinely SHORT), but below spreadAccrued + bound = 14,940,012, which is
        // exactly the window the old comparison misclassified as dust. A larger shortfall
        // clears both thresholds and would NOT catch the regression.
        _contributeInventory(498_000_000);

        uint128 amountIn = 5_000e6;
        uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);
        uint256 tokBefore = token.balanceOf(swapper);

        _routeThroughUniversalRouter(amountIn);

        uint256 spent = usdgBefore - IERC20(USDG).balanceOf(swapper);
        uint256 received = token.balanceOf(swapper) - tokBefore;
        emit log_named_uint("amountIn      ", amountIn);
        emit log_named_uint("spent         ", spent);
        emit log_named_uint("received      ", received);
        emit log_named_uint("hook dust held", hook.accruedDust(Currency.wrap(USDG)));

        // inventory ran out, so this IS short and the remainder belongs to the swapper
        assertEq(poolContract.tokenBalance(), 0, "inventory should be exhausted");
        assertEq(received, 498_000_000, "delivered exactly the available inventory");
        assertLt(spent, amountIn, "SHORT fill was misread as dust and the hook kept the remainder");

        // and what it kept must be spread on what it sold, not the unfilled remainder
        assertEq(hook.accruedDust(Currency.wrap(USDG)), 0, "hook kept the unfilled remainder as dust");
    }

    /// @dev Control: the same route with an ask INSIDE inventory must be unaffected, so
    ///      we know the partial path did not disturb ordinary full fills.
    function test_realUniversalRouter_fullFillUnchanged() public {
        vm.prank(lister);
        market.withdrawTokens(pool, 0);
        _contributeInventory(1_000e18); // 500 USDG of depth

        uint128 amountIn = 200e6; // comfortably inside inventory
        uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);
        uint256 tokBefore = token.balanceOf(swapper);

        _routeThroughUniversalRouter(amountIn);

        uint256 spent = usdgBefore - IERC20(USDG).balanceOf(swapper);
        uint256 received = token.balanceOf(swapper) - tokBefore;
        emit log_named_uint("full-fill spent   ", spent);
        emit log_named_uint("full-fill received", received);

        assertEq(spent, amountIn, "a full fill must still charge the whole input");
        assertEq(received, 400e18, "200 USDG at rate 5e5 buys 400 tokens");
    }

    // -------------------------------------------------------------------------

    function _routeThroughUniversalRouter(uint128 amountIn) internal {
        bool zeroForOne = _buyZeroForOne();
        Currency inC = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency outC = zeroForOne ? poolKey.currency1 : poolKey.currency0;

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        // SETTLE_ALL's second arg is a MAXIMUM. The router pays _getFullDebt, so a short
        // fill settles less than this and must not revert.
        params[1] = abi.encode(inC, uint256(amountIn));
        params[2] = abi.encode(outC, uint256(0));

        bytes memory commands = abi.encodePacked(uint8(V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.prank(swapper);
        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, block.timestamp + 300);
    }
}
