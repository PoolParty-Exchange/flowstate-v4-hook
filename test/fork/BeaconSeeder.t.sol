// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateBeaconSeeder, AnchorFloor} from "../../src/FlowstateBeaconSeeder.sol";
import {MockInventoryToken} from "../mocks/MockInventoryToken.sol";

/// @notice The GMGN-visibility beacon (JUP-516): the hook admits exactly ONE
///         liquidityDelta == 1 dust add per pool from any caller, and the seeder
///         periphery bundles that add with a first deposit in one transaction.
///         Invariants under test, in order of blast radius:
///           1. no position of real size can EVER be created (gate fuzz);
///           2. the dust never affects pricing (quote invariance to the wei): since 29 Sep
///              2026 in test/stack/gen4-stack.test.cjs (the quote runs a swap, and this fork's
///              hook, wired to test/fork/ListingStandIn.sol, cannot swap);
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

    // -- 3. one approval, one transaction; failure isolation ------------------

    function test_SeedAndDeposit_OneTx_DepositCreditedAndBeaconLit() public {
        uint256 amount = 500e18;
        uint256 balBefore = token.balanceOf(depositor);

        AnchorFloor[] memory signed = seeder.consentFloors(pool); // what the UI shows and the depositor signs
        vm.prank(depositor);
        seeder.seedAndDeposit(poolKey, pool, address(token), amount, signed);

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

        AnchorFloor[] memory signed = seeder.consentFloors(pool);
        vm.prank(depositor);
        seeder.seedAndDeposit(badKey, pool, address(token), amount, signed);

        (uint256 tokenPosition,,) = poolContract.positions(depositor);
        assertEq(tokenPosition, amount, "deposit landed despite beacon failure");
        assertFalse(hook.beaconSeeded(badKey.toId()), "bad pool stays unlit");
    }

    function test_SeedAndDeposit_SecondDepositSkipsSeeding() public {
        AnchorFloor[] memory signed = seeder.consentFloors(pool);
        vm.startPrank(depositor);
        seeder.seedAndDeposit(poolKey, pool, address(token), 100e18, signed);
        uint256 balAfterFirst = token.balanceOf(depositor);
        seeder.seedAndDeposit(poolKey, pool, address(token), 100e18, signed);
        vm.stopPrank();

        (uint256 tokenPosition,,) = poolContract.positions(depositor);
        assertEq(tokenPosition, 200e18, "both deposits credited");
        assertEq(balAfterFirst - token.balanceOf(depositor), 100e18, "no second wei taken");
    }

    // -- 4. per-pool semantics ------------------------------------------------

    function test_Beacon_IsPerPool_NotGlobal() public {
        // second pair on the same C1 pool: aeWETH quote (multi-asset), same hook
        market.setQuoteAsset(AEWETH, true);
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

    // -- 4. JUP-611 consent travels unchanged (Wilko, PR #11 review) ------------

    /// The periphery must not substitute an execution-time anchor for the depositor's
    /// signed floor. Sign at anchor X, poison/move the anchor below X before the
    /// transaction lands, and the deposit must revert with the market's AnchorBelowFloor.
    function test_SeedAndDeposit_RevertsWhenAnchorFallsBelowSignedFloor() public {
        AnchorFloor[] memory signed = seeder.consentFloors(pool); // signed at today's anchor
        assertGt(signed[0].minRate, 0, "fixture has a live anchor");
        // the anchor moves DOWN after signing (oracle moved + re-anchored, as an attacker
        // or a genuine market move would produce)
        _setOracleRate(_rate() * 9 / 10);
        (uint192 movedAnchor,,) = poolContract.anchorOf(USDG);
        assertLt(movedAnchor, signed[0].minRate, "anchor is now below the signed floor");

        vm.prank(depositor);
        vm.expectPartialRevert(bytes4(keccak256("AnchorBelowFloor(address,uint256,uint256)")));
        seeder.seedAndDeposit(poolKey, pool, address(token), 100e18, signed);

        (uint256 tokenPosition,,) = poolContract.positions(depositor);
        assertEq(tokenPosition, 0, "nothing funded at the moved price");
    }

    /// A floor the depositor sets ABOVE today's anchor is refused outright: the
    /// periphery passes it through and the market rejects it.
    function test_SeedAndDeposit_RevertsWhenSignedFloorAboveAnchor() public {
        AnchorFloor[] memory signed = seeder.consentFloors(pool);
        signed[0].minRate = signed[0].minRate + 1;
        vm.prank(depositor);
        vm.expectPartialRevert(bytes4(keccak256("AnchorBelowFloor(address,uint256,uint256)")));
        seeder.seedAndDeposit(poolKey, pool, address(token), 100e18, signed);
    }
}
