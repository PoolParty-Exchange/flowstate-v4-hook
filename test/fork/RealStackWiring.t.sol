// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {IFlowstateMarketTest, IFlowstatePoolTest} from "./RealStackDeployer.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @notice Everything that only becomes testable once the hook is wired to the REAL
///         FlowstateMarket + FlowstatePool: the deploy-script governance wiring, the
///         seller-side fee incidence, the anchor band, the same-timestamp rate cache,
///         the FIFO node cap, and every decline state's quoter-vs-swap revert parity.
///
///         These are the behaviours the Phase 0 `MockFlowstateMarket` did not have, so
///         every one of them is a place the hook could have been silently wrong.
/// @dev 29 Sep 2026: every test here that swapped or quoted through the hook ran the deleted
///      Gen-3 path against this older vendored market (no listings) and is retired: the fee
///      incidence, market inversion, anchor band, rate cache and unreadable-oracle suites, the
///      decline states (empty, partial, 50-node cap, paused market and pool, frozen hook) and
///      the V4-vs-market quote agreement. Gen-4 swaps are tested against the current market in
///      test/stack/gen4-stack.test.cjs. What stays is the deployment and governance wiring and
///      the registration check, none of which swaps.
abstract contract RealStackTestBase is ForkTestBase {}

// ---------------------------------------------------------------------------
// Deployment + governance wiring (deploy/flowstate-testnet.js, PR #9 shape)
// ---------------------------------------------------------------------------

contract RealStackWiringForkTest is RealStackTestBase {
    function test_Deploy_MarketIsAProxyWiredToTheRealPoolAndOracle() public view {
        assertEq(market.poolBeacon(), address(stack.beacon), "beacon");
        assertEq(market.priceOracle(), address(oracle), "oracle");
        assertEq(market.buybackReceiver(), stack.receiver, "receiver");
        assertEq(market.oracleEpoch(), 1, "epoch seeded at 1");
        assertEq(market.poolByPair(address(token), USDG), pool, "pair registry");
        assertEq(poolContract.factory(), address(market), "pool points back at the market");
        assertEq(poolContract.inventoryToken(), address(token));
        (uint192 seededRate,,) = poolContract.anchorOf(USDG);
        assertEq(uint256(seededRate), ORACLE_RATE, "USDG anchor seeded at creation (multi-asset)");
        assertEq(poolContract.tokenBalance(), INITIAL_INVENTORY, "holder-funded inventory");
        assertTrue(address(market) != stack.marketImpl, "market is behind a UUPS proxy");
    }

    /// @dev The eight-argument `initialize` after PR #9: the 12h emergency lane is its
    ///      own role holder, and the role-admin chain must be closed or every delay is
    ///      advisory.
    function test_Governance_EightLaneInitializeWiredRolesCorrectly() public view {
        assertTrue(market.hasRole(bytes32(0), address(this)), "DEFAULT_ADMIN -> admin");
        assertTrue(market.hasRole(PAUSER_ROLE, address(this)), "PAUSER -> admin");
        assertTrue(market.hasRole(UPGRADER_ROLE, address(stack.tl48)), "UPGRADER -> 48h");
        assertTrue(market.hasRole(TIMELOCK_ROLE, address(stack.tl48)), "TIMELOCK -> 48h");
        assertTrue(market.hasRole(FREEZE_ADMIN_ROLE, address(stack.tl24)), "FREEZE_ADMIN -> 24h");
        assertTrue(market.hasRole(EMERGENCY_UPGRADER_ROLE, address(stack.tl12)), "EMERGENCY_UPGRADER -> 12h");

        // the chain that makes the delays real
        assertEq(market.getRoleAdmin(UPGRADER_ROLE), TIMELOCK_ROLE);
        assertEq(market.getRoleAdmin(EMERGENCY_UPGRADER_ROLE), TIMELOCK_ROLE);
        assertEq(market.getRoleAdmin(TIMELOCK_ROLE), TIMELOCK_ROLE);
        assertEq(market.getRoleAdmin(FREEZE_ADMIN_ROLE), FREEZE_ADMIN_ROLE);
        assertEq(market.getRoleAdmin(PAUSER_ROLE), bytes32(0), "PAUSER stays instant by design");

        // DEFAULT_ADMIN can neither grant nor revoke a delayed lane
        assertFalse(market.hasRole(UPGRADER_ROLE, address(this)));
    }

    /// @dev The deployment requirement called out in FlowstateMarket's natspec: the
    ///      beacon's owner must be the MARKET PROXY, or `upgradePoolImplementation`
    ///      reverts inside the beacon's Ownable check. Proven end to end, not asserted
    ///      from the deploy script's sanity probe alone.
    function test_Governance_BeaconOwnedByMarket_SoPoolUpgradeActuallyWorks() public {
        assertEq(stack.beacon.owner(), address(market), "beacon owner is the market proxy");

        address newImpl = deployCode("FlowstatePool.sol:FlowstatePool", abi.encode(true));
        vm.prank(address(stack.tl48));
        market.upgradePoolImplementation(newImpl);
        assertEq(stack.beacon.implementation(), newImpl, "live pools follow the beacon");

        // and the pool still serves afterwards. Until 29 Sep 2026 this was a swap through the hook's
        // deleted Gen-3 path; this fork's hook (wired to ListingStandIn) cannot swap, so the upgraded
        // pool is asked through the market's own quoter instead.
        IFlowstateMarketTest.Quote memory q = market.quoteBuyFromPool(pool, USDG, 2_000e18);
        assertTrue(q.available, "the upgraded pool still offers its inventory");
        assertEq(q.fillableAmount, 2_000e18, "in full");
        assertEq(q.quoteAmount, _marketCostFor(2_000e18), "at the oracle cost");
    }

    function test_Governance_PoolUpgradeRejectsAnUnauthorisedCaller() public {
        address newImpl = deployCode("FlowstatePool.sol:FlowstatePool", abi.encode(true));
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        market.upgradePoolImplementation(newImpl);
    }
}

// ---------------------------------------------------------------------------
// Decline states: registration
// ---------------------------------------------------------------------------

contract RealStackDeclineForkTest is RealStackTestBase {
    /// @dev JUP-609 rejects an unknown Market pool at registration instead of storing
    ///      a route that can only decline later during quote/swap execution.
    function test_UnregisteredMarketPool_IsRejectedAtRegistration() public {
        address unknownPool = makeAddr("not-a-pool");
        vm.expectRevert(abi.encodeWithSelector(FlowstateC1Hook.MarketPoolNotRecognized.selector, unknownPool));
        hook.registerPair(Currency.wrap(USDG), Currency.wrap(address(token)), unknownPool, 0);
    }
}
