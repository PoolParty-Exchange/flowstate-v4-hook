// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FlowstateSlimOracle} from "../real/poolparty/oracle/FlowstateSlimOracle.sol";
import {IOracle} from "../real/poolparty/interface/IOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * Phase 3 fork validation: the slim oracle reading a LIVE RH V4 book, cross-checked
 * against the live aggregator oracle (the price source C1 uses today), plus the gas
 * number on real chain state. Complements the unit suite in PoolParty_Contracts
 * (exact math on mocks); this file answers "does it agree with reality, and what
 * does reality cost".
 *
 * Venue discovery is done ON-FORK: the canonical hookless aeWETH/USDG V4 pools are
 * probed across the standard fee tiers and the deepest one becomes the feed — the
 * same decision the registry runbook makes, executed mechanically.
 */
interface IStateViewProbe {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

contract SlimOracleLiveForkTest is Test {
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 decimals
    address constant AEWETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // 18 decimals
    address constant RH_LIVE_ORACLE = 0x000000000149d2C5F921960977e8a2b6F8b972c7;

    FlowstateSlimOracle oracle;

    function setUp() public {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(vm.rpcUrl("robinhood"));
        else vm.createSelectFork(vm.rpcUrl("robinhood"), forkBlock);
        // the live aggregator IS the fallback: unregistered pairs read it verbatim
        oracle = new FlowstateSlimOracle(address(this), RH_LIVE_ORACLE);
    }

    /// @dev poolId for a hookless (currency0, currency1, fee, tickSpacing) V4 key —
    ///      keccak of the abi-encoded PoolKey, mirroring v4-core's PoolId.toId().
    function _poolId(address c0, address c1, uint24 fee, int24 spacing) internal pure returns (bytes32) {
        return keccak256(abi.encode(c0, c1, fee, spacing, address(0)));
    }

    /// @dev The runbook's venue decision, mechanically: deepest initialized hookless
    ///      pool across the standard tiers.
    /// @dev Returns the two DEEPEST initialized tiers by liquidity, and their PoolKey
    ///      fields. The slim oracle derives venue identity from the PoolKey (JUP-547)
    ///      rather than accepting a poolId, and MIN_VENUES == MAX_VENUES == 2, so a feed
    ///      needs exactly two venues.
    ///
    ///      Review fix (Wilko): an earlier version claimed "two deepest" while actually
    ///      taking the FIRST two initialized tiers it walked past. That is a materially
    ///      different feed, and it would have quietly registered thin books whenever a
    ///      shallow tier happened to be initialized at a lower fee. Ranked properly now.
    function _findDeepest(address c0, address c1)
        internal
        view
        returns (bytes32 best, uint128 bestL, uint24[2] memory fee2, int24[2] memory sp2, uint256 found)
    {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        int24[4] memory spacings = [int24(1), 10, 60, 200];
        uint128 secondL;
        for (uint256 i = 0; i < 4; i++) {
            bytes32 id = _poolId(c0, c1, fees[i], spacings[i]);
            (bool s, bytes memory d) =
                STATE_VIEW.staticcall(abi.encodeWithSelector(IStateViewProbe.getSlot0.selector, id));
            if (!s || d.length < 32 || uint256(bytes32(d)) == 0) continue;
            (bool s2, bytes memory d2) =
                STATE_VIEW.staticcall(abi.encodeWithSelector(IStateViewProbe.getLiquidity.selector, id));
            if (!s2 || d2.length < 32) continue;
            uint128 liq = uint128(uint256(bytes32(d2)));
            if (liq == 0) continue;
            if (found < 2) ++found;

            if (liq > bestL) {
                // previous best is demoted to second
                secondL = bestL;
                fee2[1] = fee2[0];
                sp2[1] = sp2[0];
                bestL = liq;
                best = id;
                fee2[0] = fees[i];
                sp2[0] = spacings[i];
            } else if (liq > secondL) {
                secondL = liq;
                fee2[1] = fees[i];
                sp2[1] = spacings[i];
            }
        }
    }

    function test_LiveV4Feed_AgreesWithAggregatorAndMeetsGasTarget() public {
        // aeWETH < USDG by address, so aeWETH is currency0 and src (aeWETH) is token0
        (bytes32 poolId, uint128 depth, uint24[2] memory fee2, int24[2] memory sp2, uint256 found) = _findDeepest(AEWETH, USDG);
        if (poolId == bytes32(0) || found < 2) {
            emit log_string("fewer than MIN_VENUES hookless aeWETH/USDG V4 pools at standard tiers, skipping");
            vm.skip(true);
        }
        emit log_named_uint("discovered pool depth (L)", depth);

        FlowstateSlimOracle.VenueInput[] memory venues = new FlowstateSlimOracle.VenueInput[](2);
        for (uint256 i = 0; i < 2; i++) {
            venues[i] = FlowstateSlimOracle.VenueInput({
                kind: 2, // KIND_V4
                target: STATE_VIEW,
                fee: fee2[i],
                tickSpacing: sp2[i],
                hooks: address(0) // hookless pools only
            });
        }
        oracle.setFeed(AEWETH, USDG, venues);

        uint256 g = gasleft();
        uint256 slim = oracle.getRate(IERC20(AEWETH), IERC20(USDG), false);
        uint256 gasUsed = g - gasleft();
        assertGt(slim, 0, "slim oracle answered");

        uint256 live = IOracle(RH_LIVE_ORACLE).getRate(IERC20(AEWETH), IERC20(USDG), false);
        assertGt(live, 0, "aggregator answered");

        uint256 diff = slim > live ? slim - live : live - slim;
        uint256 deltaBps = diff * 10_000 / live;
        emit log_named_uint("slim rate", slim);
        emit log_named_uint("aggregator rate", live);
        emit log_named_uint("delta (bps)", deltaBps);
        emit log_named_uint("slim gas on LIVE state", gasUsed);

        // the aggregator blends venues (the measured source of its own error), so the
        // deep single book sitting within 1.5% of it validates both directions
        assertLt(deltaBps, 150, "slim within 1.5% of the aggregator on the deep pair");
        assertLt(gasUsed, 80_000, "Phase 3 gas target holds on live state");

        // the permissionless fallback, live: an unregistered pair answers exactly
        // what the aggregator answers (any token prices with nobody's approval)
        uint256 viaFallback = oracle.getRate(IERC20(USDG), IERC20(AEWETH), false);
        uint256 aggDirect = IOracle(RH_LIVE_ORACLE).getRate(IERC20(USDG), IERC20(AEWETH), false);
        assertEq(viaFallback, aggDirect, "unregistered pair passes through verbatim");
    }
}
