// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {Vm} from "forge-std/Vm.sol";

/// JUP-621: the hook pays Uniswap's TokenJar an immutable fee on every fill, carved
/// out of the spread so the buyer's price is unchanged. These tests pin the four
/// properties Uniswap Labs asked for: paid on every fill shape, in the same
/// transaction, from the spread (never from inventory or the buyer), and impossible
/// to configure away.
contract TokenJarFeeForkTest is ForkTestBase {
    /// Production values: 10 bps to the jar out of a 16 bps spread.
    function _jarFeeBps() internal pure override returns (uint16) {
        return JAR_FEE_BPS;
    }

    function _fixtureSpreadBps() internal pure override returns (uint16) {
        return 16;
    }

    function _ceilBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (bps == 0) return 0;
        return (amount * bps + 10_000 - 1) / 10_000;
    }

    function test_Immutables_WiredFromConstructor() public view {
        assertEq(hook.tokenJar(), TOKEN_JAR, "jar");
        assertEq(hook.jarFeeBps(), JAR_FEE_BPS, "bps");
    }

    /// Exact-input fill: jar receives ceil(quotePaid * jarFeeBps / 10_000) inside the
    /// swap; the spread margin the hook keeps is the full spread minus that; the buyer
    /// is charged exactly what the same swap charged before the fee existed
    /// (cost + spread + dust), i.e. quoteIn.
    function test_ExactIn_JarPaidFromSpread_BuyerPriceUnchanged() public {
        uint256 quoteIn = 1_000e6;
        uint256 jarBefore = IERC20(USDG).balanceOf(TOKEN_JAR);
        uint256 marginBefore = hook.accruedSpreadMargin(Currency.wrap(USDG));
        uint256 buyerBefore = IERC20(USDG).balanceOf(swapper);

        vm.prank(swapper);
        BalanceDelta d = _swapBuy(-int256(quoteIn), "");

        uint256 jarFee = IERC20(USDG).balanceOf(TOKEN_JAR) - jarBefore;
        uint256 marginKept = hook.accruedSpreadMargin(Currency.wrap(USDG)) - marginBefore;
        assertGt(jarFee, 0, "jar was paid");
        // spread is computed on the recomputed cost the market charged; recover that cost
        // from the buyer's charge: quoteIn = cost + spread + dust with spread = ceil(cost*bps)
        uint256 spreadBps = hook.spreadBpsFor(Currency.wrap(USDG), Currency.wrap(address(token)), quoteIn);
        uint256 netQuote = quoteIn * 10_000 / (10_000 + spreadBps);
        // the fee base is <= netQuote (the market may charge slightly less than asked);
        // exact accounting: jar + margin kept == full spread on that base, and
        // jar == ceil(base * jarFeeBps / 10_000) for base = margin-implied cost
        uint256 fullSpread = jarFee + marginKept;
        assertLe(jarFee, fullSpread, "fee never exceeds the spread");
        assertLe(jarFee, _ceilBps(netQuote, JAR_FEE_BPS), "fee <= fee on the asked notional");
        assertGe(jarFee, _ceilBps(netQuote - netQuote / 1000, JAR_FEE_BPS), "fee ~ 10 bps of cost");
        // buyer charged the specified input exactly, nothing more
        assertEq(buyerBefore - IERC20(USDG).balanceOf(swapper), quoteIn, "buyer paid quoteIn");
        assertEq(uint256(int256(-d.amount0() > 0 ? -d.amount0() : -d.amount1())), quoteIn, "delta == quoteIn");
        // hook holds only what it booked (margin + dust): the jar's share has left
        assertEq(
            IERC20(USDG).balanceOf(address(hook)),
            hook.accruedSpreadMargin(Currency.wrap(USDG)) + hook.accruedDust(Currency.wrap(USDG)),
            "hook balance == booked margin + dust"
        );
    }

    /// Exact-output fill: cost is exact, spread = ceil(cost * spreadBps), jar gets
    /// ceil(cost * jarFeeBps) and the buyer pays cost + spread as before.
    function test_ExactOut_JarPaidFromSpread_BuyerPriceUnchanged() public {
        uint256 tokensOut = 1_000e18;
        uint256 jarBefore = IERC20(USDG).balanceOf(TOKEN_JAR);
        uint256 marginBefore = hook.accruedSpreadMargin(Currency.wrap(USDG));
        uint256 buyerBefore = IERC20(USDG).balanceOf(swapper);

        vm.prank(swapper);
        _swapBuy(int256(tokensOut), "");

        uint256 jarFee = IERC20(USDG).balanceOf(TOKEN_JAR) - jarBefore;
        uint256 marginKept = hook.accruedSpreadMargin(Currency.wrap(USDG)) - marginBefore;
        uint256 charged = buyerBefore - IERC20(USDG).balanceOf(swapper);
        uint256 fullSpread = jarFee + marginKept;
        uint256 cost = charged - fullSpread; // exact-output: charge = cost + spread, no dust
        assertEq(jarFee, _ceilBps(cost, JAR_FEE_BPS), "jar == ceil(cost * jarFeeBps)");
        uint256 spreadBps = hook.spreadBpsFor(Currency.wrap(USDG), Currency.wrap(address(token)), cost);
        assertEq(fullSpread, _ceilBps(cost, spreadBps), "jar + margin == full spread on cost");
        assertEq(charged, cost + _ceilBps(cost, spreadBps), "buyer pays cost + spread, unchanged");
    }

    /// The fee is paid on every fill: two consecutive fills, jar grows twice, and an
    /// event is emitted each time.
    function test_PaidOnEveryFill_EventEmitted() public {
        uint256 jar0 = IERC20(USDG).balanceOf(TOKEN_JAR);
        vm.recordLogs();
        vm.prank(swapper);
        _swapBuy(-int256(200e6), "");
        uint256 jar1 = IERC20(USDG).balanceOf(TOKEN_JAR);
        vm.prank(swapper);
        _swapBuy(-int256(300e6), "");
        uint256 jar2 = IERC20(USDG).balanceOf(TOKEN_JAR);
        assertGt(jar1, jar0, "first fill paid");
        assertGt(jar2, jar1, "second fill paid");
        bytes32 sig = keccak256("ProtocolFeePaid(bytes32,address,uint256)");
        uint256 n;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) n++;
        }
        assertEq(n, 2, "one ProtocolFeePaid per fill");
    }

    /// No configuration can push a spread below the jar fee: base spread, floor and
    /// registration default all refuse, so the fee can always be carved from the spread.
    function test_SpreadSettersCannotDropBelowJarFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, JAR_FEE_BPS - 1, JAR_FEE_BPS, hook.MAX_SPREAD_BPS())
        );
        hook.setBaseSpread(Currency.wrap(USDG), Currency.wrap(address(token)), JAR_FEE_BPS - 1);
        vm.expectRevert(
            abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, JAR_FEE_BPS - 1, JAR_FEE_BPS, hook.MAX_SPREAD_BPS())
        );
        hook.setBaseSpreadFloor(JAR_FEE_BPS - 1);
        vm.expectRevert(
            abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, JAR_FEE_BPS - 1, JAR_FEE_BPS, hook.MAX_SPREAD_BPS())
        );
        hook.setMarketRegistrationSpread(JAR_FEE_BPS - 1);
        // exactly the jar fee is the lowest legal spread: the hook then keeps nothing
        hook.setBaseSpread(Currency.wrap(USDG), Currency.wrap(address(token)), JAR_FEE_BPS);
        uint256 marginBefore = hook.accruedSpreadMargin(Currency.wrap(USDG));
        uint256 jarBefore = IERC20(USDG).balanceOf(TOKEN_JAR);
        vm.prank(swapper);
        _swapBuy(int256(500e18), "");
        assertEq(hook.accruedSpreadMargin(Currency.wrap(USDG)), marginBefore, "spread == fee: hook keeps 0");
        assertGt(IERC20(USDG).balanceOf(TOKEN_JAR), jarBefore, "jar still paid");
    }

    /// Constructor refuses a zero jar and a fee above the registration default.
    function test_Constructor_Guards() public {
        (, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(FlowstateC1Hook).creationCode,
            abi.encode(POOL_MANAGER, address(market), address(this), AEWETH, address(0), JAR_FEE_BPS)
        );
        vm.expectRevert(FlowstateC1Hook.ZeroAddress.selector);
        new FlowstateC1Hook{salt: salt}(POOL_MANAGER, address(market), address(this), AEWETH, address(0), JAR_FEE_BPS);
        (, bytes32 salt2) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(FlowstateC1Hook).creationCode,
            abi.encode(POOL_MANAGER, address(market), address(this), AEWETH, TOKEN_JAR, uint16(17))
        );
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.SpreadOutOfRange.selector, 16, 17, hook.MAX_SPREAD_BPS()));
        new FlowstateC1Hook{salt: salt2}(POOL_MANAGER, address(market), address(this), AEWETH, TOKEN_JAR, uint16(17));
    }
}
