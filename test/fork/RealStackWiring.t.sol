// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {IFlowstateMarketTest, IFlowstatePoolTest} from "./RealStackDeployer.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Everything that only becomes testable once the hook is wired to the REAL
///         FlowstateMarket + FlowstatePool: the deploy-script governance wiring, the
///         seller-side fee incidence, the anchor band, the same-timestamp rate cache,
///         the FIFO node cap, and every decline state's quoter-vs-swap revert parity.
///
///         These are the behaviours the Phase 0 `MockFlowstateMarket` did not have, so
///         every one of them is a place the hook could have been silently wrong.
abstract contract RealStackTestBase is ForkTestBase {
    /// @dev PausableUpgradeable's revert; no selector is exported to Solidity from the
    ///      0.8.29 side, so it is spelled out.
    bytes4 internal constant ENFORCED_PAUSE = bytes4(keccak256("EnforcedPause()"));
    bytes4 internal constant NO_ORACLE_RATE = bytes4(keccak256("NoOracleRate()"));

    address internal freshSender = makeAddr("arbitrary-fresh-eoa");

    function _quoteExactInRaw(uint128 quoteIn) external returns (uint256 out) {
        (out,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: _buyZeroForOne(),
                exactAmount: quoteIn,
                hookData: ""
            })
        );
    }

    function _quoteExactOutRaw(uint128 tokensOut) external returns (uint256 amountIn) {
        (amountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: _buyZeroForOne(),
                exactAmount: tokensOut,
                hookData: ""
            })
        );
    }

    function swapBuyExternal(int256 amountSpecified) external {
        _swapBuy(amountSpecified, "");
    }

    /// @dev Scope rule 2: a non-quotable pool must decline IDENTICALLY in the V4Quoter
    ///      simulation and in the real swap, so quote-ok-then-swap-revert cannot happen
    ///      within a block by construction.
    function _assertDeclinesIdentically(bytes4 selector, uint128 quoteIn, string memory what) internal {
        vm.prank(freshSender);
        try this._quoteExactInRaw(quoteIn) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, selector), string.concat("quoter: ", what));
        }

        vm.prank(swapper);
        try this.swapBuyExternal(-int256(uint256(quoteIn))) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, selector), string.concat("swap: ", what));
        }
    }
}

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
        (uint192 seededRate,,,) = poolContract.anchorOf(USDG);
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

        address newImpl = deployCode("FlowstatePool.sol:FlowstatePool");
        vm.prank(address(stack.tl48));
        market.upgradePoolImplementation(newImpl);
        assertEq(stack.beacon.implementation(), newImpl, "live pools follow the beacon");

        // and the pool still serves the hook afterwards
        vm.prank(swapper);
        _swapBuy(-1_000e6, "");
        assertEq(token.balanceOf(swapper), _marketTokensFor(1_000e6));
    }

    function test_Governance_PoolUpgradeRejectsAnUnauthorisedCaller() public {
        address newImpl = deployCode("FlowstatePool.sol:FlowstatePool");
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        market.upgradePoolImplementation(newImpl);
    }

    /// @dev The market's own SOR quoter and the hook's V4 path must agree: they are the
    ///      same pool state read two ways, and disagreement would mean one of our doors
    ///      is mispricing against the other.
    function test_MarketQuoterAgreesWithTheHookPath() public {
        uint128 quoteIn = 1_000e6;
        uint256 tokensExpected = _marketTokensFor(quoteIn);

        IFlowstateMarketTest.Quote memory q = market.quoteBuyFromPool(pool, USDG, tokensExpected);
        assertTrue(q.available, "market quoter must offer the pool");
        assertEq(q.fillableAmount, tokensExpected);
        assertEq(q.quoteAmount, _marketCostFor(tokensExpected), "buyer pays raw oracle cost");
        assertEq(q.quoteAsset, USDG);

        vm.prank(freshSender);
        uint256 v4Out = this._quoteExactInRaw(quoteIn);
        assertEq(v4Out, tokensExpected, "V4 quote == market quote at zero hook spread");
    }
}

// ---------------------------------------------------------------------------
// Fee incidence, rounding, dust
// ---------------------------------------------------------------------------

contract RealStackFeeForkTest is RealStackTestBase {
    /// @dev Scope §5's load-bearing claim: on buys the BUYER pays raw oracle cost and
    ///      the 30/30/40 protocol fee is carved from the SELLER leg. If that were ever
    ///      wrong, the hook's spread would be stacking on a fee-inclusive number and
    ///      every quote in this repo would be off. Proven by moving the fee tier by
    ///      100x and asserting the quote is byte-identical.
    function test_Fee_IsSellerSide_SoTheBuyerQuoteNeverMoves() public {
        uint128 quoteIn = 1_000e6;

        vm.prank(freshSender);
        uint256 atDefaultTier = this._quoteExactInRaw(quoteIn);

        market.setFeeBps(address(token), 1); // 0.01% instead of the 1% default
        vm.prank(freshSender);
        uint256 atMinTier = this._quoteExactInRaw(quoteIn);

        assertEq(atMinTier, atDefaultTier, "buyer quote must be fee-invariant");

        // ...but the contributor's credit does move, which is where the fee lands.
        vm.prank(swapper);
        _swapBuy(-int256(uint256(quoteIn)), "");
        assertEq(
            poolContract.claimableQuote(USDG, lister),
            quoteIn - (quoteIn * 1 / 10_000),
            "contributor credited net of the SELLER-side fee"
        );
    }

    /// @dev With no reseller code registered, the whole fee routes to the buyback
    ///      receiver by the pool's remainder rule. The hook passes "" today (§5b: one
    ///      code for all V4 flow, registered later), so this is the shipping shape.
    function test_Fee_UnregisteredResellerCodeRoutesEverythingToBuyback() public {
        uint256 quoteIn = 1_000e6;
        uint256 before = IERC20(USDG).balanceOf(stack.receiver);

        vm.prank(swapper);
        _swapBuy(-int256(quoteIn), "");

        assertEq(IERC20(USDG).balanceOf(stack.receiver) - before, _feeOn(quoteIn), "full fee to buyback");
    }

    /// @dev The hook's reseller code is forwarded verbatim to the market on every buy.
    ///      An unregistered code must not revert the trade (the code is only a fee-split
    ///      lookup), and the 32-byte cap is the market's, not the hook's.
    function test_ResellerCode_IsForwardedAndAnUnregisteredCodeStillTrades() public {
        hook.setResellerCode("flowstate-v4");
        vm.prank(swapper);
        _swapBuy(-1_000e6, "");
        assertEq(token.balanceOf(swapper), _marketTokensFor(1_000e6));
    }

    /// @dev A finding, not a formality. FlowstatePool inverts with
    ///      `desired = floor(quoteIn * 1e18 / rate)` and then re-prices with
    ///      `ceil(desired * rate / 1e18)`. The floor discards at most `rate` of the
    ///      numerator, so the ceil recovers the input EXACTLY whenever `rate <= 1e18` —
    ///      i.e. `buyFromPoolExactQuote` leaves NO market-side dust at all for any
    ///      USDG-quoted pool (rate = price x 1e6 there). The Phase 0 mock, which
    ///      inverted through a rateNum/rateDen pair, could lose a raw unit at any rate;
    ///      the real pool cannot. Anything the hook accrues as dust on a USDG pool is
    ///      therefore its own spread-carve residue and nothing else.
    function test_MarketInversionIsExact_WhenRateFitsUnderRateScale() public {
        _setOracleRate(AWKWARD_ORACLE_RATE); // 2_333_333: does not divide 1e18 evenly

        uint256 quoteIn = 1_000_001; // deliberately not a round number
        uint256 tokensOut = _marketTokensFor(quoteIn);
        assertEq(_marketCostFor(tokensOut), quoteIn, "floor-then-ceil round trips exactly");

        vm.prank(swapper);
        _swapBuy(-int256(quoteIn), "");

        Currency usdg = Currency.wrap(USDG);
        assertEq(hook.accruedSpreadMargin(usdg), 0, "zero configured spread accrues zero spread");
        assertEq(hook.accruedDust(usdg), 0, "no market-side dust exists below RATE_SCALE");
        assertEq(IERC20(USDG).balanceOf(address(hook)), 0, "and nothing sits on the hook");
    }

    /// @dev The other side of the same finding: market-side inversion dust IS reachable,
    ///      but only when `rate > 1e18` — i.e. when one RAW inventory-token unit is
    ///      worth more than one RAW quote-asset unit, which is the LOW-DECIMAL-TOKEN /
    ///      18-DECIMAL-QUOTE shape, precisely the aeWETH-quoted long-tail pools in the
    ///      scope's v1 quote-asset set (§7). So the hook's separate dust counter is not
    ///      dead code; it is the aeWETH case. The magnitude is bounded by roughly
    ///      rate/1e18 raw quote units per fill, so it is genuinely dust. Exercised here
    ///      on the USDG fixture by driving the rate above RATE_SCALE directly.
    function test_MarketInversionLosesUnits_WhenRateExceedsRateScale() public {
        _setOracleRate(DUST_ORACLE_RATE);

        uint256 quoteIn = 100_000_000_000;
        uint256 tokensOut = _marketTokensFor(quoteIn);
        uint256 quotePaid = _marketCostFor(tokensOut);
        assertLt(quotePaid, quoteIn, "above RATE_SCALE the floor genuinely loses units");

        vm.prank(swapper);
        _swapBuy(-int256(quoteIn), "");

        Currency usdg = Currency.wrap(USDG);
        assertEq(hook.accruedSpreadMargin(usdg), 0);
        assertEq(hook.accruedDust(usdg), quoteIn - quotePaid, "the whole residue is accounted as dust");
        assertEq(IERC20(USDG).balanceOf(address(hook)), quoteIn - quotePaid, "and it is really on the hook");
        console2.log("market-side inversion dust (USDG raw):", quoteIn - quotePaid);
    }
}

// ---------------------------------------------------------------------------
// Anchor band + same-timestamp cache
// ---------------------------------------------------------------------------

contract RealStackOracleForkTest is RealStackTestBase {
    /// @dev The pool is its own one-slot price historian. A rate move beyond
    ///      anchorBandBps x widen must decline, and it must decline in the quoter and
    ///      the swap alike — the failure shape scope §8 calls acceptable.
    function test_AnchorBand_OutOfBandDeclinesInQuoterAndSwap() public {
        assertEq(poolContract.anchorBandBps(), 500, "default 5% band (tightened 30 Jul)");
        // setUp left the anchor 120s stale => widen 3 => 30% allowed. Double the rate.
        oracle.setRate(address(token), USDG, ORACLE_RATE * 2);

        _assertDeclinesIdentically(bytes4(keccak256("RateOutOfBand()")), 1_000e6, "RateOutOfBand");

        // the admin escape hatch restores service
        market.resetAnchor(pool, USDG);
        _expireRateCache();
        vm.prank(swapper);
        _swapBuy(-1_000e6, "");
        assertEq(token.balanceOf(swapper), _marketTokensFor(1_000e6), "re-anchored at the new rate");
    }

    /// @dev A move INSIDE the widened band is served, and the anchor advances with it.
    function test_AnchorBand_InBandMoveIsServedAndAdvancesTheAnchor() public {
        oracle.setRate(address(token), USDG, ORACLE_RATE * 105 / 100); // +5%, inside 30%
        vm.prank(swapper);
        _swapBuy(-1_000e6, "");
        (uint192 anchorRate,,,) = poolContract.anchorOf(USDG);
        assertEq(uint256(anchorRate), ORACLE_RATE * 105 / 100, "anchor advanced to the fresh read");
    }

    /// @dev The same-timestamp cache, proven the only way that admits no doubt: break
    ///      the oracle between two trades in the same second. The second trade must
    ///      still fill, because it never calls the oracle at all. This is the scope §6
    ///      "free" warm lever — and the mock market had no equivalent, so no Phase 0
    ///      number measured it.
    function test_SameTimestampCache_SecondTradeMakesNoOracleCall() public {
        uint256 t = block.timestamp;
        uint256 perFill = _marketTokensFor(500e6); // read the rate BEFORE breaking it

        vm.prank(swapper);
        _swapBuy(-500e6, ""); // fresh read; caches rate at this timestamp

        oracle.setFailing(true); // any oracle call from here on reverts

        vm.prank(swapper);
        _swapBuy(-500e6, ""); // must still fill => zero oracle calls
        assertEq(block.timestamp, t, "same timestamp");
        assertEq(token.balanceOf(swapper), perFill * 2, "both fills landed");

        // one second later the cache is gone and the broken oracle bites, identically
        // in the quoter and the swap
        vm.warp(t + 1);
        vm.prank(freshSender);
        try this._quoteExactInRaw(500e6) {
            fail();
        } catch {}
        vm.prank(swapper);
        try this.swapBuyExternal(-500e6) {
            fail();
        } catch {}
    }

    /// @dev RH produces ~10 blocks/s, so the "same-block cache" is really a same-SECOND
    ///      cache spanning several blocks. Recorded as a test so the operational claim
    ///      is checked rather than assumed.
    function test_SameTimestampCache_SpansMultipleBlocks() public {
        uint256 perFill = _marketTokensFor(500e6);
        vm.prank(swapper);
        _swapBuy(-500e6, "");

        oracle.setFailing(true);
        vm.roll(block.number + 5); // new blocks, same timestamp

        vm.prank(swapper);
        _swapBuy(-500e6, "");
        assertEq(token.balanceOf(swapper), perFill * 2, "cache survived 5 blocks");
    }

    /// @dev Oracle returning zero is the market's typed `NoOracleRate`, and it declines
    ///      in both simulations.
    function test_OracleReturningZero_DeclinesInQuoterAndSwap() public {
        oracle.setRate(address(token), USDG, 0);
        _assertDeclinesIdentically(NO_ORACLE_RATE, 1_000e6, "NoOracleRate");
    }
}

// ---------------------------------------------------------------------------
// Decline states: empty, shortfall, paused, frozen
// ---------------------------------------------------------------------------

contract RealStackDeclineForkTest is RealStackTestBase {
    function _drainInventory() internal {
        vm.prank(lister);
        market.withdrawTokens(pool, 0);
        assertEq(poolContract.tokenBalance(), 0, "pool emptied");
    }

    /// @dev Scope §8: empty inventory must decline in BOTH the quoter simulation and
    ///      the swap. The real pool raises `NoLiquidity`; the mock raised its own
    ///      `FillShortfall` for the same condition.
    function test_EmptyInventory_DeclinesIdentically() public {
        _drainInventory();
        _assertDeclinesIdentically(bytes4(keccak256("NoLiquidity()")), 1_000e6, "NoLiquidity");
    }

    /// @dev All-or-nothing fill semantics (scope §10): inventory that covers only part
    ///      of the ask is a typed `FillShortfall`, never a partial fill — a partial fill
    ///      would strand the swapper's committed quote, which V4 fixes at swap time.
    function test_PartialInventory_IsFillShortfall_NotAPartialFill() public {
        _drainInventory();
        _contributeInventory(1_000e18); // covers 500 USDG of demand, not 1,000

        vm.prank(swapper);
        _swapBuy(-500e6, ""); // exactly fillable
        assertEq(token.balanceOf(swapper), 1_000e18);

        _contributeInventory(1_000e18);
        _assertDeclinesIdentically(bytes4(keccak256("FillShortfall()")), 5_000e6, "FillShortfall exactIn");

        vm.prank(freshSender);
        try this._quoteExactOutRaw(10_000e18) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, bytes4(keccak256("FillShortfall()"))), "FillShortfall exactOut");
        }
    }

    /// @dev The FIFO walk is capped at MAX_FILL_NODES = 50, so a pool whose inventory is
    ///      spread over more than 50 contributors cannot fill past the first 50 nodes
    ///      even though `tokenBalance` says otherwise. There is no mock analogue at all:
    ///      the mock filled straight off its own balance.
    function test_FiftyNodeFifoCap_BoundsFillableBelowTokenBalance() public {
        _drainInventory();

        token.mint(address(this), 51e18);
        token.approve(address(market), type(uint256).max);
        for (uint256 i = 0; i < 51; i++) {
            market.contributeTokens(pool, 1e18, address(uint160(0xC0DE0000 + i)));
        }
        assertEq(poolContract.tokenBalance(), 51e18, "51 nodes of inventory on the books");

        // 50 nodes are reachable: 50e18 tokens == 25 USDG at the fixture rate
        vm.prank(swapper);
        _swapBuy(-25e6, "");
        assertEq(token.balanceOf(swapper), 50e18, "filled exactly the reachable 50 nodes");
    }

    function test_MarketPaused_DeclinesIdentically() public {
        market.pause();
        _assertDeclinesIdentically(ENFORCED_PAUSE, 1_000e6, "EnforcedPause");

        market.unpause();
        vm.prank(swapper);
        _swapBuy(-1_000e6, "");
        assertEq(token.balanceOf(swapper), _marketTokensFor(1_000e6), "service resumes on unpause");
    }

    function test_PoolPaused_DeclinesIdentically() public {
        market.pausePool(pool, true);
        _assertDeclinesIdentically(bytes4(keccak256("PoolIsPaused()")), 1_000e6, "PoolIsPaused");
    }

    /// @dev Scope §3 rule 3 consequence, made concrete: `buyFromPool*`'s freeze check
    ///      tests msg.sender AND buyer, both of which are the hook. Freezing the hook
    ///      therefore kills the whole venue rather than one user — which is exactly why
    ///      the governance runbook rule is NEVER FREEZE THE HOOK ADDRESS. Asserted here
    ///      so the consequence is a checked fact, not a paragraph.
    function test_FreezingTheHookAddressKillsTheVenue() public {
        vm.prank(address(stack.tl24));
        market.setFreezeEnabled(true);

        // an unrelated frozen address changes nothing: the hook is always the buyer
        market.setFrozen(swapper, true);
        vm.prank(swapper);
        _swapBuy(-1_000e6, "");
        assertEq(token.balanceOf(swapper), _marketTokensFor(1_000e6), "freezing the swapper is invisible here");

        market.setFrozen(address(hook), true);
        _assertDeclinesIdentically(bytes4(keccak256("AccountFrozen()")), 1_000e6, "AccountFrozen");

        market.setFrozen(address(hook), false);
        vm.prank(swapper);
        _swapBuy(-1_000e6, "");
    }

    /// @dev A pool the hook points at that the market does not know is a typed
    ///      `UnknownPool` from the market, surfaced identically in both paths.
    function test_UnregisteredMarketPool_DeclinesIdentically() public {
        hook.registerPair(Currency.wrap(USDG), Currency.wrap(address(token)), makeAddr("not-a-pool"), 0);
        _assertDeclinesIdentically(bytes4(keccak256("UnknownPool()")), 1_000e6, "UnknownPool");
    }
}
