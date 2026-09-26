// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {MockInventoryToken} from "../mocks/MockInventoryToken.sol";
import {RealStackDeployer, IFlowstateMarketTest, IFlowstatePoolTest, ITestSpotOracle, AnchorFloorInput} from "./RealStackDeployer.sol";

/// @notice Base for all RH-mainnet-fork tests.
///
///         Phase 1 final: the hook is wired to the REAL FlowstateMarket + FlowstatePool
///         (vendored from PoolParty_Contracts origin/main @ 959e867 into `test/real/`),
///         deployed fresh inside the fork by `RealStackDeployer`. The Phase 0
///         `MockFlowstateMarket` is gone — there is no second implementation of the
///         market interface left in this repo to drift.
///
///         What is still not production here: the price oracle. RH's live 1inch-style
///         aggregator cannot price a freshly minted test inventory token, and the slim
///         RH oracle is Phase 3. So the default stack runs on `TestSpotOracle` (one
///         SLOAD per read, rate settable) and the TRUE end-to-end oracle cost is
///         measured separately against RH's live aggregator in `LiveOracleGas.t.sol`.
///
///         Fixture shape: inventory token FLOWMOCK (18d), quote asset real USDG (6d),
///         oracle rate 5e5 => 1 FLOWMOCK costs 0.5 USDG, i.e. 1 USDG buys 2 FLOWMOCK —
///         arithmetically IDENTICAL to the Phase 0 mock's 2e12/1 rate, so every existing
///         size expectation carries over unchanged.
interface IOracleRate {
    function getRate(address src, address dst, bool useWrappers) external view returns (uint256);
}

interface IPoolAnchors {
    function seededAssets() external view returns (address[] memory);
    function anchorOf(address asset) external view returns (uint192 rate, uint64 blockNumber, uint32 epoch);
}

abstract contract ForkTestBase is RealStackDeployer {
    // -- Robinhood Chain (4663) canonical addresses, verified 2026-07-28 ------
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 decimals
    address constant AEWETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // 18 decimals
    /// JUP-621: Uniswap's TokenJar on Robinhood Chain (protocol-fees deployments table) and the
    /// immutable fee the hook pays it on every fill, out of the spread (Hamish, 4 Sep 2026: 8 bps).
    address constant TOKEN_JAR = 0x2aC03e14Cfe755426DaAEe0a4994184Ce81482F8;
    uint16 constant JAR_FEE_BPS = 8; // the production value (DeployHook JAR_FEE_BPS), Hamish 4 Sep 2026

    /// @dev The shared fixture builds its hook with NO jar fee and a zero spread so the
    ///      exact-amount expectations across the suite stay as they were; suites that
    ///      exercise the fee (TokenJarFee.t.sol) override these two to the production
    ///      values and get their own hook instance.
    function _jarFeeBps() internal pure virtual returns (uint16) {
        return 0;
    }

    function _fixtureSpreadBps() internal pure virtual returns (uint16) {
        return 0;
    }

    /// @notice The 1inch-shaped spot aggregator the RH Flowstate deployment is wired to
    ///         (`deploy/out.rh.json`). Live and answering: getRate(aeWETH, USDG) returns
    ///         a real rate. Used by `LiveOracleGas.t.sol` for the true oracle cost.
    address constant RH_LIVE_ORACLE = 0x000000000149d2C5F921960977e8a2b6F8b972c7;

    // -- Arbitrum Orbit fixture: ArbSys precompile mock (returns block.number) --
    // The V4Quoter path does NOT need this (verified 2026-07-28); kept for any
    // future test touching ArbSys-reading contracts.
    address constant ARBSYS = 0x0000000000000000000000000000000000000064;
    bytes constant ARBSYS_MOCK_CODE = hex"4360005260206000f3";

    // -- Hook flags: 0x28cc ---------------------------------------------------
    uint160 constant HOOK_FLAGS = uint160(
        (1 << 13) // BEFORE_INITIALIZE
            | (1 << 11) // BEFORE_ADD_LIQUIDITY
            | (1 << 7) // BEFORE_SWAP
            | (1 << 6) // AFTER_SWAP
            | (1 << 3) // BEFORE_SWAP_RETURNS_DELTA
            | (1 << 2) // AFTER_SWAP_RETURNS_DELTA
    );

    // -- Market pricing fixture -----------------------------------------------

    /// @dev FlowstatePool prices `quoteCost = ceil(tokens * rate / 1e18)`. rate = 5e5
    ///      with an 18d token and a 6d quote asset means 1 token = 0.5 USDG.
    uint256 constant ORACLE_RATE = 5e5;
    /// @dev A rate that does not divide 1e18 evenly, so every ceil in the cost direction
    ///      actually rounds. Same order of magnitude as the Phase 0 mock's awkward
    ///      3e12/7 rate, so the rounding suite's sizes carry over unchanged.
    uint256 constant AWKWARD_ORACLE_RATE = 2_333_333;

    /// @dev A rate well ABOVE RATE_SCALE (1e18), the only regime in which
    ///      FlowstatePool's floor-then-ceil inversion can leave market-side dust
    ///      (`rate > 1e18` means one RAW inventory-token unit is worth more than one RAW
    ///      quote-asset unit, i.e. the inventory token has fewer decimals than the quote
    ///      asset — the aeWETH-quoted long-tail shape in the scope's v1 quote-asset set,
    ///      §7). See `RealStackFeeForkTest.test_MarketInversion*`.
    uint256 constant DUST_ORACLE_RATE = 1e19 + 3;

    /// @dev Convenience equivalences at ORACLE_RATE, kept so Phase 0 expectations read
    ///      unchanged: tokensOut = quoteIn * RATE_NUM / RATE_DEN.
    uint256 constant RATE_NUM = 2e12;
    uint256 constant RATE_DEN = 1;

    /// @dev FlowstateMarket.DEFAULT_FEE_BPS — the long-tail tier every new token lands
    ///      on. Carved from the SELLER leg inside settleBuy; the buyer still pays raw
    ///      oracle cost, which is why it never moves a hook quote.
    uint16 constant MARKET_FEE_BPS = 100;

    uint256 constant INITIAL_INVENTORY = 1_000_000e18;

    IPoolManager manager = IPoolManager(POOL_MANAGER);
    IV4Quoter quoter = IV4Quoter(V4_QUOTER);

    FlowstateC1Hook hook;
    RealStack stack;
    IFlowstateMarketTest market;
    IFlowstatePoolTest poolContract;
    address pool;
    ITestSpotOracle oracle;
    MockInventoryToken token;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey poolKey;
    bool usdgIsCurrency0;

    address swapper = makeAddr("swapper");
    /// @dev The C1 contributor whose inventory backs every fill, and who therefore holds
    ///      the claimable proceeds. Never the hook: the hook holds no user funds.
    address lister = makeAddr("inventory-lister");
    address keeper = makeAddr("keeper");

    function setUp() public virtual {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(vm.rpcUrl("robinhood"));
        else vm.createSelectFork(vm.rpcUrl("robinhood"), forkBlock);

        token = new MockInventoryToken();

        // 1. the real Flowstate stack, deploy-script order, admin = this test contract
        oracle = _deployTestOracle();
        oracle.setRate(address(token), USDG, ORACLE_RATE);
        stack = _deployRealFlowstateStack(address(this), keeper, address(oracle));
        market = stack.market;
        market.setQuoteAsset(USDG, true);

        // 2. a real C1 pool with real holder-funded inventory (no protocol capital)
        pool = _createPoolWithInventory(INITIAL_INVENTORY);
        poolContract = IFlowstatePoolTest(pool);

        // 3. the hook, mined to 0x28cc against the real market address
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(FlowstateC1Hook).creationCode,
            abi.encode(POOL_MANAGER, address(market), address(this), AEWETH, TOKEN_JAR, _jarFeeBps(), address(0), address(0))
        );
        hook = new FlowstateC1Hook{salt: salt}(
            POOL_MANAGER, address(market), address(this), AEWETH, TOKEN_JAR, _jarFeeBps(), address(0), address(0)
        );
        assertEq(address(hook), hookAddress, "CREATE2 address mismatch");

        // Conservative ship default: zero base spread, no rung schedule (the spread
        // suite configures spreads per test; the floor is 0 until set).
        hook.registerPair(Currency.wrap(USDG), Currency.wrap(address(token)), pool, _fixtureSpreadBps());

        usdgIsCurrency0 = USDG < address(token);
        (Currency c0, Currency c1) = usdgIsCurrency0
            ? (Currency.wrap(USDG), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(USDG));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(poolKey, _sqrtPriceForMockRate());

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        deal(USDG, swapper, 1_000_000e6);
        vm.startPrank(swapper);
        IERC20(USDG).approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // 4. leave the pool's anchor STALE so the next trade takes a fresh oracle read.
        //    Without this every measurement would silently ride FlowstatePool's
        //    same-timestamp cache (createPool seeds lastRateTime = now), which the mock
        //    market had no equivalent of.
        _expireRateCache();
    }

    // -- real-stack helpers ---------------------------------------------------

    /// @dev Creates the (token, USDG) C1 pool with holder-funded inventory. The lister
    ///      pays; the market pulls into the pool; the pool credits the FIFO ledger.
    function _createPoolWithInventory(uint256 amount) internal returns (address created) {
        token.mint(lister, amount);
        vm.startPrank(lister);
        token.approve(address(market), type(uint256).max);
        created = market.createPool(address(token), amount, 0, _seedFloors(address(token)));
        vm.stopPrank();
    }

    /// @dev JUP-611 consent floors for a fresh listing: the oracle's current rate per
    ///      approved asset it can price (the seed rate is the natural floor).
    function _seedFloors(address inventoryToken) internal view returns (AnchorFloorInput[] memory floors) {
        floors = new AnchorFloorInput[](1);
        uint256 r = IOracleRate(market.priceOracle()).getRate(inventoryToken, USDG, false);
        floors[0] = AnchorFloorInput({asset: USDG, minRate: uint192(r)});
    }

    /// @dev JUP-611 consent floors for a top-up: the pool's current durable anchors.
    function _consentFloors(address marketPool) internal view returns (AnchorFloorInput[] memory floors) {
        address[] memory assets = IPoolAnchors(marketPool).seededAssets();
        floors = new AnchorFloorInput[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            (uint192 rate,,) = IPoolAnchors(marketPool).anchorOf(assets[i]);
            floors[i] = AnchorFloorInput({asset: assets[i], minRate: rate});
        }
    }

    /// @dev Top up the SAME lister's position (FlowstatePool merges repeat deposits from
    ///      one owner into a single FIFO node, so this never grows the node walk).
    function _contributeInventory(uint256 amount) internal {
        token.mint(lister, amount);
        AnchorFloorInput[] memory floors = _consentFloors(pool); // before the prank: the view calls would consume it
        vm.prank(lister);
        market.contributeTokens(pool, amount, lister, floors);
    }

    /// @dev Move the oracle and re-anchor the pool. A bare rate change would trip the
    ///      pool's anchor band (`RateOutOfBand`) — the escape hatch the real market
    ///      exposes for exactly this is the admin `resetAnchor`.
    function _setOracleRate(uint256 newRate) internal {
        oracle.setRate(address(token), USDG, newRate);
        vm.prank(address(stack.tl48)); // JUP-611 (#40): resetAnchor is behind the 48h TIMELOCK_ROLE
        market.resetAnchor(pool, USDG);
        _expireRateCache();
    }

    /// @dev Advance past FlowstatePool's same-timestamp rate cache so the next trade
    ///      performs a genuine oracle read + band check. 120s also widens the band to
    ///      3x, which is irrelevant at a constant rate but keeps the fixture honest.
    /// @dev The rate cache is keyed on the BLOCK the anchor was accepted in, not on a
    ///      timestamp (anchor redesign, PR #22). Warping time alone therefore expires
    ///      nothing: RH produces many blocks per second, so timestamp and block moved
    ///      apart. Roll the block as well, and keep the warp so any genuinely
    ///      time-based staleness also advances.
    function _expireRateCache() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 120);
    }

    function _rate() internal view returns (uint256) {
        return oracle.getRate(address(token), USDG, false);
    }

    /// @dev FlowstatePool.priceBuyExactQuote's inversion: floor, against the buyer.
    function _marketTokensFor(uint256 quoteIn) internal view returns (uint256) {
        return quoteIn * 1e18 / _rate();
    }

    /// @dev FlowstatePool.priceBuy's cost: ceil, against the buyer.
    function _marketCostFor(uint256 tokens) internal view returns (uint256) {
        return (tokens * _rate() + 1e18 - 1) / 1e18;
    }

    /// @dev The seller-leg fee the pool carves inside settleBuy. Buyers never pay it —
    ///      it is deducted from what contributors are credited — so it never appears in
    ///      a hook quote. It DOES move where the quote asset ends up.
    function _feeOn(uint256 quotePaid) internal pure returns (uint256) {
        return quotePaid * MARKET_FEE_BPS / 10_000;
    }

    /// @dev Where a buyer's payment lands under the REAL market: the pool keeps
    ///      `quotePaid - fee` (held against the contributor's claim ledger) and the
    ///      buyback receiver takes the fee. The Phase 0 mock kept 100% in one contract;
    ///      this pair is the conservation unit now.
    function _quoteReceived() internal view returns (uint256) {
        return IERC20(USDG).balanceOf(pool) + IERC20(USDG).balanceOf(stack.receiver);
    }

    // -- helpers --------------------------------------------------------------

    function mockArbSys() internal {
        vm.etch(ARBSYS, ARBSYS_MOCK_CODE);
    }

    /// @dev sqrtPriceX96 = sqrt((raw1 << 192) / raw0) for the fixture rate
    ///      1 USDG (1e6 raw) = 2 FLOWMOCK (2e18 raw). Cosmetic slot0 seed only;
    ///      the hook overrides all pricing.
    function _sqrtPriceForMockRate() internal view returns (uint160) {
        (uint256 raw0, uint256 raw1) = usdgIsCurrency0 ? (uint256(1e6), uint256(2e18)) : (uint256(2e18), uint256(1e6));
        uint256 ratioX192 = (raw1 << 192) / raw0;
        uint256 sqrtPrice = FixedPointMathLib.sqrt(ratioX192);
        require(sqrtPrice > TickMath.MIN_SQRT_PRICE && sqrtPrice < TickMath.MAX_SQRT_PRICE, "seed out of range");
        return uint160(sqrtPrice);
    }

    /// @dev BUY = USDG in, FLOWMOCK out. zeroForOne depends on currency ordering.
    function _buyZeroForOne() internal view returns (bool) {
        return usdgIsCurrency0;
    }

    function _swapBuy(int256 amountSpecified, bytes memory hookData) internal returns (BalanceDelta) {
        bool zeroForOne = _buyZeroForOne();
        return swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _swapSell(int256 amountSpecified) internal returns (BalanceDelta) {
        bool zeroForOne = !_buyZeroForOne();
        return swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Hook reverts bubble up wrapped (PoolManager Wrap__FailedHookCall, quoter
    ///      UnexpectedRevertBytes); asserting on the embedded selector is the robust
    ///      cross-wrapper check.
    function _containsSelector(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i <= data.length - 4; i++) {
            if (data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                && data[i + 3] == selector[3]) {
                return true;
            }
        }
        return false;
    }
}
