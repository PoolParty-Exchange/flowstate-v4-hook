// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {ListingStandIn} from "./ListingStandIn.sol";
import {ITestSpotOracle, AnchorFloorInput} from "./RealStackDeployer.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
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
/// @dev 29 Sep 2026: the swap, quoter and conservation tests here (and the seasoned variant)
///      ran the deleted Gen-3 path, whose price came from this oracle through the old
///      vendored market; they are retired with GasColdWarm.t.sol. Gen-4 prices from the
///      listing settlement's passive rule; its gas is measured on the real stack
///      (test/stack/gen4-stack.test.cjs gas matrix and gate 2, test/stack/fork-rh-gen4.cjs).
///      What is left is the isolated oracle read, which never touched the hook.
contract LiveOracleGasForkTest is ForkTestBase {
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
        {
            AnchorFloorInput[] memory floors = new AnchorFloorInput[](1);
            floors[0] = AnchorFloorInput({asset: USDG, minRate: 1}); // live listing: any positive seed rate consents
            pool = market.createPool(AEWETH, LIVE_INVENTORY, 0, floors);
        }
        vm.stopPrank();

        (address standInRegistry, address standInSettlement) = ListingStandIn.deploy(address(market));
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(FlowstateC1Hook).creationCode,
            abi.encode(POOL_MANAGER, address(market), address(this), AEWETH, TOKEN_JAR, 0, standInRegistry, standInSettlement)
        );
        hook = new FlowstateC1Hook{salt: salt}(
            POOL_MANAGER, address(market), address(this), AEWETH, TOKEN_JAR, 0, standInRegistry, standInSettlement
        );
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
}
