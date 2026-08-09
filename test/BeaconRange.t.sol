// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FlowstateBeaconSeeder} from "../src/FlowstateBeaconSeeder.sol";

/// @notice Parametric coverage of the beacon range placement (PR #3 review concern 2):
///         Solidity's integer division truncates toward zero, which is exactly where a
///         future refactor could introduce an off-by-one that flips the range to the
///         wrong side of the current tick and makes the dust settle in the wrong
///         currency. Pure math, no fork.
contract BeaconRangeTest is Test {
    FlowstateBeaconSeeder seeder;
    int24 constant SPACING = 60;

    function setUp() public {
        // pure-function host; constructor args are irrelevant beyond non-zero
        seeder = new FlowstateBeaconSeeder(address(1), address(2));
    }

    function _checkAbove(int24 tick) internal view {
        (int24 lower, int24 upper) = seeder.computeBeaconRange(tick, SPACING, true);
        assertGt(lower, tick, "above-range must start strictly above the current tick");
        assertEq(upper, lower + SPACING, "one spacing wide");
        assertEq(lower % SPACING, 0, "aligned");
        // never more than two spacings away: adjacency, not drift
        assertLe(int256(lower) - int256(tick), int256(uint256(uint24(2 * SPACING))), "adjacent");
    }

    function _checkBelow(int24 tick) internal view {
        (int24 lower, int24 upper) = seeder.computeBeaconRange(tick, SPACING, false);
        assertLe(upper, tick, "below-range must end at or below the current tick");
        assertEq(upper, lower + SPACING, "one spacing wide");
        assertEq(lower % SPACING, 0, "aligned");
        assertLe(int256(tick) - int256(upper), int256(uint256(uint24(2 * SPACING))), "adjacent");
    }

    /// @dev The review's named cases plus the truncation-sensitive neighborhood.
    function test_PlacementAtNamedTicks() public view {
        int24[13] memory ticks =
            [int24(-600), -120, -61, -60, -59, -1, 0, 1, 59, 60, 61, 120, 600];
        for (uint256 i; i < ticks.length; i++) {
            _checkAbove(ticks[i]);
            _checkBelow(ticks[i]);
        }
    }

    function test_PlacementFuzz(int24 tick) public view {
        // stay a few spacings inside the usable band; the bound revert has its own test
        tick = int24(bound(int256(tick), int256(TickMath.MIN_TICK + 3 * SPACING), int256(TickMath.MAX_TICK - 3 * SPACING)));
        _checkAbove(tick);
        _checkBelow(tick);
    }

    function test_RevertsOutsideUsableBand() public {
        // within one spacing of MAX_TICK, no aligned above-range fits
        vm.expectRevert(
            abi.encodeWithSelector(
                FlowstateBeaconSeeder.BeaconRangeOutOfBounds.selector,
                ((TickMath.MAX_TICK / SPACING) + 1) * SPACING,
                ((TickMath.MAX_TICK / SPACING) + 1) * SPACING + SPACING
            )
        );
        seeder.computeBeaconRange(TickMath.MAX_TICK, SPACING, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                FlowstateBeaconSeeder.BeaconRangeOutOfBounds.selector,
                ((TickMath.MIN_TICK / SPACING) - 1) * SPACING - SPACING,
                ((TickMath.MIN_TICK / SPACING) - 1) * SPACING
            )
        );
        seeder.computeBeaconRange(TickMath.MIN_TICK, SPACING, false);
    }
}
