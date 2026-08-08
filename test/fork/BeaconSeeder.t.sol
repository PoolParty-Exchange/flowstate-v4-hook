// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateBeaconSeeder} from "../../src/FlowstateBeaconSeeder.sol";
import {MockInventoryToken} from "../mocks/MockInventoryToken.sol";

/// @notice The GMGN-visibility beacon (JUP-516): the hook admits exactly ONE
///         liquidityDelta == 1 dust add per pool from any caller, and the seeder
///         periphery bundles that add with a first deposit in one transaction.
///         Invariants under test, in order of blast radius:
///           1. no position of real size can EVER be created (gate fuzz);
///           2. the dust never affects pricing (quote invariance to the wei);
///           3. one approval + one transaction gives deposit + beacon, with a
///              beacon failure never blocking the deposit;
///           4. once-per-pool semantics are per poolId, not global.
contract BeaconSeederForkTest is ForkTestBase {
    FlowstateBeaconSeeder seeder;
    address depositor = makeAddr("first-depositor");

    function setUp() public override {
        super.setUp();
        seeder = new FlowstateBeaconSeeder(POOL_MANAGER, address(market));
        token.mint(depositor, 1_000e18);
        vm.prank(depositor);
        token.approve(address(seeder), type(uint256).max);
    }

    // -- 1. gate: nothing of real size, ever ----------------------------------

    function test_Gate_RejectsRealSizeAdds(int256 liquidityDelta) public {
        liquidityDelta = bound(liquidityDelta, 2, int256(uint256(type(uint128).max)));
        token.mint(address(this), 1_000_000e18);
        deal(USDG, address(this), 1_000_000e6);
        token.approve(address(lpRouter), type(uint256).max);
        IERC20(USDG).approve(address(lpRouter), type(uint256).max);

        vm.expectRevert();
        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: liquidityDelta, salt: 0}),
            ""
        );
    }

    function test_Gate_AllowsExactlyOneDustAdd_AnyCaller_ThenCloses() public {
        // any caller, no seeder involved: the invariant lives in the hook
        token.mint(address(this), 10e18);
        deal(USDG, address(this), 10e6);
        token.approve(address(lpRouter), type(uint256).max);
        IERC20(USDG).approve(address(lpRouter), type(uint256).max);

        assertFalse(hook.beaconSeeded(poolKey.toId()), "unlit before");
        lpRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1, salt: 0}), ""
        );
        assertTrue(hook.beaconSeeded(poolKey.toId()), "lit after");

        // the very same 1-wei add is now refused forever
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1, salt: bytes32(uint256(1))}), ""
        );
    }

    // -- 2. dust never prices -------------------------------------------------

    function test_PricingInvariance_QuotesIdenticalBeforeAndAfterSeed() public {
        uint128[3] memory sizes = [uint128(10e6), uint128(1_000e6), uint128(25_000e6)];
        uint256[3] memory before_;
        for (uint256 i; i < 3; i++) {
            (before_[i],) = _quoteExactIn(sizes[i]);
        }

        vm.prank(depositor);
        seeder.seed(poolKey, address(token));
        assertTrue(hook.beaconSeeded(poolKey.toId()), "beacon lit");

        for (uint256 i; i < 3; i++) {
            (uint256 after_,) = _quoteExactIn(sizes[i]);
            assertEq(after_, before_[i], "dust changed a quote");
        }
    }

    // -- 3. one approval, one transaction; failure isolation ------------------

    function test_SeedAndDeposit_OneTx_DepositCreditedAndBeaconLit() public {
        uint256 amount = 500e18;
        uint256 balBefore = token.balanceOf(depositor);

        vm.prank(depositor);
        seeder.seedAndDeposit(poolKey, pool, address(token), amount);

        (uint256 tokenPosition,,) = poolContract.positions(depositor);
        assertEq(tokenPosition, amount, "deposit credited to depositor, not periphery");
        assertTrue(hook.beaconSeeded(poolKey.toId()), "beacon lit in same tx");
        // cost to the depositor beyond the deposit: the dust settle. Its unit count is
        // price-dependent (1 wei at the live CASHCAT price; ~4.2k wei of an 18d token
        // at this fixture's price) but always value-negligible: bounded here at 1e6
        // wei = 1e-12 tokens.
        uint256 dust = balBefore - token.balanceOf(depositor) - amount;
        assertGt(dust, 0, "dust was paid");
        assertLt(dust, 1e6, "dust stays value-negligible");
        // periphery holds nothing between transactions
        assertEq(token.balanceOf(address(seeder)), 0, "seeder drained");
    }

    function test_SeedAndDeposit_BeaconFailureNeverBlocksDeposit() public {
        // same pair and hook, different tickSpacing => different (uninitialized) poolId:
        // the seed leg reverts inside try/catch, the deposit must still land.
        PoolKey memory badKey = PoolKey({
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            fee: 0,
            tickSpacing: 120,
            hooks: poolKey.hooks
        });
        uint256 amount = 250e18;

        vm.prank(depositor);
        seeder.seedAndDeposit(badKey, pool, address(token), amount);

        (uint256 tokenPosition,,) = poolContract.positions(depositor);
        assertEq(tokenPosition, amount, "deposit landed despite beacon failure");
        assertFalse(hook.beaconSeeded(badKey.toId()), "bad pool stays unlit");
    }

    function test_SeedAndDeposit_SecondDepositSkipsSeeding() public {
        vm.startPrank(depositor);
        seeder.seedAndDeposit(poolKey, pool, address(token), 100e18);
        uint256 balAfterFirst = token.balanceOf(depositor);
        seeder.seedAndDeposit(poolKey, pool, address(token), 100e18);
        vm.stopPrank();

        (uint256 tokenPosition,,) = poolContract.positions(depositor);
        assertEq(tokenPosition, 200e18, "both deposits credited");
        assertEq(balAfterFirst - token.balanceOf(depositor), 100e18, "no second wei taken");
    }

    // -- 4. per-pool semantics ------------------------------------------------

    function test_Beacon_IsPerPool_NotGlobal() public {
        // second pair on the same C1 pool: aeWETH quote (multi-asset), same hook
        hook.registerPair(Currency.wrap(AEWETH), Currency.wrap(address(token)), pool, 0);
        (Currency c0, Currency c1) = AEWETH < address(token)
            ? (Currency.wrap(AEWETH), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(AEWETH));
        PoolKey memory key2 =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(key2, _sqrtPriceForMockRate());

        vm.startPrank(depositor);
        seeder.seed(poolKey, address(token));
        assertTrue(hook.beaconSeeded(poolKey.toId()), "pool 1 lit");
        assertFalse(hook.beaconSeeded(key2.toId()), "pool 2 independent");
        seeder.seed(key2, address(token));
        vm.stopPrank();
        assertTrue(hook.beaconSeeded(key2.toId()), "pool 2 lit independently");
    }

    // -- seeder input hygiene -------------------------------------------------

    function test_Seed_RejectsPayTokenOutsidePool() public {
        MockInventoryToken stranger = new MockInventoryToken();
        vm.prank(depositor);
        vm.expectRevert(FlowstateBeaconSeeder.PayCurrencyNotInPool.selector);
        seeder.seed(poolKey, address(stranger));
    }

    function test_SeedFor_OnlySelfOrPayer() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FlowstateBeaconSeeder.NotPayer.selector);
        seeder.seedFor(poolKey, address(token), depositor);
    }

    // -- helper ---------------------------------------------------------------

    function _quoteExactIn(uint128 quoteIn) internal returns (uint256 amountOut, uint256 gasEst) {
        vm.prank(makeAddr("fresh-quoter"));
        return quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: _buyZeroForOne(),
                exactAmount: quoteIn,
                hookData: ""
            })
        );
    }
}
