// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Phase 1 slice 2: the fee-determination rungs (scope §5).
///
///         spreadBps = baseSpread[pair] + sizeAdjustment(quote notional); the buyer
///         pays market cost * (1 + spreadBps/10_000) in BOTH directions; the spread
///         accrues on the hook per quote asset. These tests hold the acceptance line
///         from rule 2 — quoter == execution to the wei — WITH spread applied, and
///         prove the rounding never undercollects.
/// @dev 29 Sep 2026: every test here that swapped or quoted ran the deleted Gen-3 path and is
///      retired (parity, rounding, accrual and sweep amounts); what stays is the configuration
///      surface, the spreadBpsFor view and the sweep access checks. The Gen-4 spread, rung,
///      parity and custody properties are in test/stack/gen4-stack.test.cjs.
abstract contract SpreadTestBase is ForkTestBase {
    Currency internal usdg = Currency.wrap(USDG);

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
}

/// @notice Parity to the wei WITH spread applied, both directions, three sizes,
///         across the four spread configurations that matter (zero, base-only,
///         base+rungs below a boundary, base+rungs above it).
/// @dev 29 Sep 2026: the parity tests (quoter == swap with spread and rungs) and the
///      hookData-with-spread test ran the deleted Gen-3 path and are retired; see
///      test/stack/gen4-stack.test.cjs ("quote parity", "spread rungs", "hookData is never
///      read"). The view-only top-rung test stays.
contract SpreadParityForkTest is SpreadTestBase {
    /// @dev Above the top ceiling the TOP rung applies (open-ended), so a huge trade
    ///      never pays fewer bps than a mid-size one.
    function test_RungAboveTopCeiling_UsesTopRung() public {
        _setBase(16);
        _setShipRungs();
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 100_000e6), 31);
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 500_000e6), 31, "open-ended top rung");
    }
}

/// @notice Accrual, sweep, and the custody invariant from scope §8: outside an unlock
///         the hook's ONLY balance is accrued margin + dust.
/// @dev 29 Sep 2026: the accrual, custody-invariant, sweep-amount, sweep-event, re-accrual,
///      donation-recovery and exact-output (fundBuy skip) tests accrued margin through swaps on
///      the deleted Gen-3 path and are retired; the Gen-4 versions are in
///      test/stack/gen4-stack.test.cjs ("margin custody and sweep"). The access checks stay.
contract SpreadSweepForkTest is SpreadTestBase {
    address sweepTo = makeAddr("margin-sweep-wallet");

    /// @dev A quote-asset balance on the hook for the access tests to try to take. Until 29 Sep
    ///      2026 it was accrued through swaps on the deleted Gen-3 path; the sweep takes the hook's
    ///      whole balance, so a force-sent balance is what an unauthorised sweep would steal.
    function _fundHook() internal {
        deal(USDG, address(hook), 1_000e6);
    }

    function test_Sweep_RevertsForNonOwner() public {
        _fundHook();
        hook.setSweepDestination(sweepTo);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        hook.sweepMargin(usdg);
    }

    function test_Sweep_RevertsWhenDestinationUnset() public {
        _fundHook();
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
        hook.registerPair(usdg, Currency.wrap(address(token)), pool, 0);
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
        hook.registerPair(usdg, Currency.wrap(AEWETH), pool, 0);
    }

    /// @dev Raising the floor leaves owner tuning untouched but lazily closes the route
    ///      until its stored spread is brought back into compliance.
    function test_RaisingFloor_MakesPairNonReadyUntilSpreadIsRetuned() public {
        hook.setBaseSpread(usdg, Currency.wrap(address(token)), 5);
        assertTrue(hook.isPairReady(usdg, Currency.wrap(address(token))));
        hook.setBaseSpreadFloor(50);

        assertFalse(hook.isPairReady(usdg, Currency.wrap(address(token))));
        bytes32 key = keccak256(abi.encode(poolKey.currency0, poolKey.currency1));
        (,,, uint16 storedSpread,) = hook.pairs(key);
        assertEq(storedSpread, 5, "floor raise must not silently mutate owner tuning");

        try this.swapBuyBelowRaisedFloor(-1_000e6) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.SpreadOutOfRange.selector));
        }

        hook.setBaseSpread(usdg, Currency.wrap(address(token)), 50);
        assertTrue(hook.isPairReady(usdg, Currency.wrap(address(token))));
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1e6), 50);
        // (until 29 Sep 2026 a swap here showed the retuned route fill and accrue; it ran the
        // deleted Gen-3 path. Filling and accruing at a configured spread is covered on the real
        // stack by test/stack/gen4-stack.test.cjs.)
    }

    function swapBuyBelowRaisedFloor(int256 amountSpecified) external {
        _swapBuy(amountSpecified, "");
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
        hook.registerPair(usdg, Currency.wrap(address(token)), pool, 42);
        assertEq(hook.spreadBpsFor(usdg, Currency.wrap(address(token)), 1e6), 42);
    }
}
