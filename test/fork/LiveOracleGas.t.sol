// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {ITestSpotOracle} from "./RealStackDeployer.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @notice THE TRUE END-TO-END GAS NUMBER.
///
///         Every other suite in this repo runs the real market/pool against
///         `TestSpotOracle` (one SLOAD), because RH's aggregator cannot price a freshly
///         minted test token. This one wires the whole stack to the ACTUAL oracle the
///         RH Flowstate deployment uses — the 1inch-shaped spot aggregator at
///         `RH_LIVE_ORACLE`, live on chain — and lists a REAL RH pair it can price:
///         aeWETH inventory quoted in USDG.
///
///         So: real PoolManager, real V4Quoter, real FlowstateMarket, real FlowstatePool,
///         real oracle, real ERC20s. The only thing on the fixture side is the swapper's
///         balance and the lister's inventory, both dealt.
///
/// @dev Subtracting the stub-oracle numbers in `GasColdWarm.t.sol` from these gives the
///      oracle's own contribution, which is what Phase 3's slim RH oracle replaces. The
///      isolated oracle read is also measured directly below so the decomposition does
///      not rest on cross-suite subtraction.
contract LiveOracleGasForkTest is ForkTestBase {
    uint128 constant QUOTE_IN = 1_000e6; // 1,000 USDG
    uint128 constant TOKENS_OUT = 0.25e18; // 0.25 aeWETH
    uint256 constant LIVE_INVENTORY = 200e18; // 200 aeWETH of holder inventory

    IERC20 constant inv = IERC20(AEWETH);
    uint256 liveRate;

    /// @dev Deliberately does NOT call `super.setUp()`: this fixture replaces the
    ///      FLOWMOCK/stub-oracle stack entirely rather than adding a second one.
    function setUp() public virtual override {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(vm.rpcUrl("robinhood"));
        else vm.createSelectFork(vm.rpcUrl("robinhood"), forkBlock);

        liveRate = ITestSpotOracle(RH_LIVE_ORACLE).getRate(AEWETH, USDG, false);
        require(liveRate != 0, "RH live oracle did not price aeWETH/USDG at this block");

        stack = _deployRealFlowstateStack(address(this), keeper, RH_LIVE_ORACLE);
        market = stack.market;
        market.setQuoteAsset(USDG, true);

        deal(AEWETH, lister, LIVE_INVENTORY);
        vm.startPrank(lister);
        inv.approve(address(market), type(uint256).max);
        pool = market.createPool(AEWETH, LIVE_INVENTORY, 0);
        vm.stopPrank();

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(FlowstateC1Hook).creationCode,
            abi.encode(POOL_MANAGER, address(market), address(this), AEWETH)
        );
        hook = new FlowstateC1Hook{salt: salt}(POOL_MANAGER, address(market), address(this), AEWETH);
        assertEq(address(hook), hookAddress, "CREATE2 address mismatch");
        hook.registerPair(Currency.wrap(USDG), Currency.wrap(AEWETH), pool, 0);

        usdgIsCurrency0 = USDG < AEWETH; // false on RH: aeWETH sorts first
        (Currency c0, Currency c1) = usdgIsCurrency0
            ? (Currency.wrap(USDG), Currency.wrap(AEWETH))
            : (Currency.wrap(AEWETH), Currency.wrap(USDG));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(poolKey, _sqrtPriceForLiveRate());

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        deal(USDG, swapper, 1_000_000e6);
        vm.startPrank(swapper);
        IERC20(USDG).approve(address(swapRouter), type(uint256).max);
        inv.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        _expireRateCache(); // createPool seeded the anchor: leave it stale for a real read
    }

    /// @dev Cosmetic slot0 seed at the live rate (1e18 raw aeWETH = liveRate raw USDG).
    function _sqrtPriceForLiveRate() internal view returns (uint160) {
        (uint256 raw0, uint256 raw1) = usdgIsCurrency0 ? (uint256(1e6), 1e24 / liveRate) : (uint256(1e18), liveRate);
        uint256 sqrtPrice = FixedPointMathLib.sqrt((raw1 << 192) / raw0);
        require(sqrtPrice > TickMath.MIN_SQRT_PRICE && sqrtPrice < TickMath.MAX_SQRT_PRICE, "seed out of range");
        return uint160(sqrtPrice);
    }

    function _liveTokensFor(uint256 quoteIn) internal view returns (uint256) {
        return quoteIn * 1e18 / liveRate;
    }

    function _liveCostFor(uint256 tokens) internal view returns (uint256) {
        return (tokens * liveRate + 1e18 - 1) / 1e18;
    }

    // -- the isolated oracle term ---------------------------------------------

    /// @dev The single most important number for Phase 3: what one cold read of RH's
    ///      live aggregator actually costs inside the swap path.
    function test_Gas_LiveOracleReadInIsolation() public view {
        uint256 g = gasleft();
        uint256 r = ITestSpotOracle(RH_LIVE_ORACLE).getRate(AEWETH, USDG, false);
        uint256 cold = g - gasleft();

        g = gasleft();
        ITestSpotOracle(RH_LIVE_ORACLE).getRate(AEWETH, USDG, false);
        uint256 warm = g - gasleft();

        console2.log("RH live oracle getRate(aeWETH,USDG) rate:", r);
        console2.log("RH live oracle read COLD (gas):", cold);
        console2.log("RH live oracle read WARM (gas):", warm);
    }

    // -- the end-to-end path --------------------------------------------------

    function test_LiveOracle_BuyExecutesAndQuoterMatchesToTheWei() public {
        uint256 expected = _liveTokensFor(QUOTE_IN);
        assertGt(expected, 0, "priced");

        vm.prank(makeAddr("arbitrary-fresh-eoa"));
        (uint256 quoted, uint256 gasEst) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: _buyZeroForOne(),
                exactAmount: QUOTE_IN,
                hookData: ""
            })
        );
        assertEq(quoted, expected, "quote != oracle-priced expectation");

        uint256 invBefore = inv.balanceOf(swapper);
        uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);
        vm.prank(swapper);
        _swapBuy(-int256(uint256(QUOTE_IN)), "");

        assertEq(inv.balanceOf(swapper) - invBefore, quoted, "delivered != quoted, against the LIVE oracle");
        assertEq(usdgBefore - IERC20(USDG).balanceOf(swapper), QUOTE_IN, "paid != specified");
        console2.log("live rate (USDG raw per 1e18 aeWETH raw):", liveRate);
        console2.log("quoter gasEstimate (live oracle):", gasEst);
    }

    function test_Gas_LiveOracle_SwapExactIn_ColdThenWarm() public {
        vm.prank(swapper);
        uint256 g = gasleft();
        _swapBuy(-int256(uint256(QUOTE_IN)), "");
        uint256 cold = g - gasleft();

        vm.prank(swapper);
        g = gasleft();
        _swapBuy(-int256(uint256(QUOTE_IN)), "");
        uint256 warm = g - gasleft();

        console2.log("LIVE swap exactIn COLD (fresh oracle read):", cold);
        console2.log("LIVE swap exactIn WARM (same-timestamp cache):", warm);
        assertLt(warm, cold);
    }

    function test_Gas_LiveOracle_SwapExactOut_ColdThenWarm() public {
        vm.prank(swapper);
        uint256 g = gasleft();
        _swapBuy(int256(uint256(TOKENS_OUT)), "");
        uint256 cold = g - gasleft();

        vm.prank(swapper);
        g = gasleft();
        _swapBuy(int256(uint256(TOKENS_OUT)), "");
        uint256 warm = g - gasleft();

        console2.log("LIVE swap exactOut COLD (fresh oracle read):", cold);
        console2.log("LIVE swap exactOut WARM (same-timestamp cache):", warm);
        assertLt(warm, cold);
    }

    function test_Gas_LiveOracle_QuoterColdThenWarm() public {
        IV4Quoter.QuoteExactSingleParams memory pIn = IV4Quoter.QuoteExactSingleParams({
            poolKey: poolKey,
            zeroForOne: _buyZeroForOne(),
            exactAmount: QUOTE_IN,
            hookData: ""
        });
        (, uint256 estCold) = quoter.quoteExactInputSingle(pIn);
        (, uint256 estWarm) = quoter.quoteExactInputSingle(pIn);
        console2.log("LIVE quoter exactIn gasEstimate COLD:", estCold);
        console2.log("LIVE quoter exactIn gasEstimate WARM:", estWarm);

        IV4Quoter.QuoteExactSingleParams memory pOut = IV4Quoter.QuoteExactSingleParams({
            poolKey: poolKey,
            zeroForOne: _buyZeroForOne(),
            exactAmount: TOKENS_OUT,
            hookData: ""
        });
        (, uint256 outCold) = quoter.quoteExactOutputSingle(pOut);
        console2.log("LIVE quoter exactOut gasEstimate COLD:", outCold);
    }

    /// @dev Conservation still holds with a live oracle and two real ERC20 legs.
    function test_LiveOracle_TakeSettleConservation() public {
        uint256 managerUsdg = IERC20(USDG).balanceOf(POOL_MANAGER);
        uint256 managerInv = inv.balanceOf(POOL_MANAGER);
        uint256 sunkBefore = _quoteReceived();

        uint256 tokensOut = _liveTokensFor(QUOTE_IN);
        uint256 quotePaid = _liveCostFor(tokensOut);

        vm.prank(swapper);
        _swapBuy(-int256(uint256(QUOTE_IN)), "");

        assertEq(IERC20(USDG).balanceOf(POOL_MANAGER), managerUsdg, "manager USDG nets zero");
        assertEq(inv.balanceOf(POOL_MANAGER), managerInv, "manager aeWETH nets zero");
        assertEq(_quoteReceived() - sunkBefore, quotePaid, "pool + receiver got the payment");
        assertEq(IERC20(USDG).balanceOf(address(hook)), quotePaid == QUOTE_IN ? 0 : QUOTE_IN - quotePaid, "dust only");
        assertEq(inv.balanceOf(address(hook)), 0, "no inventory residue on the hook");
    }
}

/// @notice The same live-oracle measurements against a SEASONED pool (routed steady
///         state: one fill already executed, so no path pays a one-time
///         zero-to-nonzero storage initialization), with the rate cache expired again
///         so COLD still means "fresh oracle read".
contract LiveOracleGasSeasonedForkTest is LiveOracleGasForkTest {
    function setUp() public override {
        super.setUp();
        vm.prank(swapper);
        _swapBuy(-int256(10e6), "");
        _expireRateCache();
    }
}
