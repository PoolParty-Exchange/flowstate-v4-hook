// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
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

    /// @dev WSR F5 (27 Sep 2026): a slice larger than our stock REVERTS. Until then (JUP-559) the hook
    ///      handed the unfilled remainder back to the router with settleFor; on this router's native and
    ///      router-custody plans that left the buyer's change for anyone's SWEEP. Now nothing moves: the
    ///      buyer, the router and the stock are all unchanged, and the hook's typed error names the cause.
    ///      Inventory is 1,000 tokens (500 USDG at rate 5e5); the ask is 5,000 USDG.
    function test_realUniversalRouter_shortFillRevertsAndChargesNothing() public {
        vm.prank(lister);
        market.withdrawTokens(pool, 0); // empty it
        _contributeInventory(1_000e18); // 1,000 tokens == 500 USDG of depth
        uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);
        uint256 tokBefore = token.balanceOf(swapper);
        uint256 routerBefore = IERC20(USDG).balanceOf(UNIVERSAL_ROUTER);
        bytes memory err = _routeExpectingRevert(5_000e6);
        assertTrue(_contains(err, abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 1_000e18)), "hook shortfall named");
        assertEq(IERC20(USDG).balanceOf(swapper), usdgBefore, "buyer charged nothing");
        assertEq(token.balanceOf(swapper), tokBefore, "buyer received nothing");
        assertEq(IERC20(USDG).balanceOf(UNIVERSAL_ROUTER), routerBefore, "nothing left in the router");
        assertEq(poolContract.tokenBalance(), 1_000e18, "stock untouched");
    }

    /// @dev The exact-depth slice: an aggregator that sizes our leg to our stock gets a complete fill.
    function test_realUniversalRouter_exactDepthFillsCompletely() public {
        vm.prank(lister);
        market.withdrawTokens(pool, 0);
        _contributeInventory(1_000e18); // 500 USDG of depth
        uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);
        uint256 tokBefore = token.balanceOf(swapper);
        _routeThroughUniversalRouter(500e6);
        assertEq(usdgBefore - IERC20(USDG).balanceOf(swapper), 500e6, "charged exactly the slice");
        assertEq(token.balanceOf(swapper) - tokBefore, 1_000e18, "the whole stock delivered");
        assertEq(poolContract.tokenBalance(), 0);
    }

    /// @dev The price-parking brick (PartialFillFallthrough.t.sol) stays unreachable: a short fill now
    ///      reverts, the pool price does not move, and the pool is still usable afterwards.
    function test_shortFill_doesNotMoveThePoolPriceAtAll() public {
        vm.prank(lister);
        market.withdrawTokens(pool, 0);
        _contributeInventory(1_000e18); // 500 USDG of depth
        (uint160 before_,,,) = IStateView(STATE_VIEW).getSlot0(poolKey.toId());
        _routeExpectingRevert(5_000e6); // ten times available depth: a SHORT fill
        (uint160 after_,,,) = IStateView(STATE_VIEW).getSlot0(poolKey.toId());
        assertEq(after_, before_, "the pool price moved");
        uint256 tokBefore = token.balanceOf(swapper);
        _routeThroughUniversalRouter(200e6);
        assertEq(token.balanceOf(swapper) - tokBefore, 400e18, "pool unusable after a short fill");
    }

    /// @dev REGRESSION (kept from JUP-559): a genuine shortfall inside the old "false dust" band
    ///      (unspent net quote above the one-token-wei bound but below spread + bound) must be treated
    ///      as SHORT. It now reverts; the hook must never keep it as dust.
    function test_shortFill_isNotMisreadAsDust_whenSpreadAndRateAreHigh() public {
        _setOracleRate(DUST_ORACLE_RATE);
        hook.setBaseSpread(Currency.wrap(USDG), Currency.wrap(address(token)), 30);
        _expireRateCache();
        vm.prank(lister);
        market.withdrawTokens(pool, 0);
        _contributeInventory(498_000_000); // sized into the old false-FULL band (see git history)
        uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);
        bytes memory err = _routeExpectingRevert(5_000e6);
        assertTrue(_contains(err, abi.encodeWithSelector(FlowstateC1Hook.ExactInputShortfall.selector, 498_000_000)), "treated as short");
        assertEq(IERC20(USDG).balanceOf(swapper), usdgBefore, "buyer charged nothing");
        assertEq(hook.accruedDust(Currency.wrap(USDG)), 0, "hook kept nothing as dust");
        assertEq(poolContract.tokenBalance(), 498_000_000, "stock untouched");
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

    function _routeExpectingRevert(uint128 amountIn) internal returns (bytes memory err) {
        (bytes memory commands, bytes[] memory inputs) = _plan(amountIn);
        vm.prank(swapper);
        try IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, block.timestamp + 300) {
            revert("a short fill must revert");
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool hit = true;
            for (uint256 j; j < needle.length; ++j) if (hay[i + j] != needle[j]) { hit = false; break; }
            if (hit) return true;
        }
        return false;
    }

    function _routeThroughUniversalRouter(uint128 amountIn) internal {
        (bytes memory commands, bytes[] memory inputs) = _plan(amountIn);
        vm.prank(swapper);
        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, block.timestamp + 300);
    }

    function _plan(uint128 amountIn) internal view returns (bytes memory commands, bytes[] memory inputs) {
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

        commands = abi.encodePacked(uint8(V4_SWAP));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }
}
