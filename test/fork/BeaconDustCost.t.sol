// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {MockInventoryToken} from "../mocks/MockInventoryToken.sol";

/// @notice Measures the REAL minimum settle cost of the beacon dust mint
///         (one single-sided position, liquidityDelta = 1, one tickSpacing wide,
///         placed just above the current tick) on an RH-mainnet fork, at the
///         live CASHCAT pool's actual sqrtPrice and our tickSpacing of 60.
///         This is the load-bearing number for the depositor-pays framing.
contract BeaconDustCostTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    bytes32 constant LIVE_CASHCAT_POOL_ID = 0x626d6ca49f8b0198632914a934d67533dfbc12e6e9434a573fbbd8208ce1b01f;

    IPoolManager pm;
    PoolModifyLiquidityTest router;
    MockInventoryToken tokenA;
    MockInventoryToken tokenB;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("robinhood"));
        pm = IPoolManager(POOL_MANAGER);
        router = new PoolModifyLiquidityTest(pm);
        tokenA = new MockInventoryToken();
        tokenB = new MockInventoryToken();
        tokenA.mint(address(this), 1e24);
        tokenB.mint(address(this), 1e24);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
    }

    function test_beaconDustMinimumSettle() public {
        // live sqrtPrice of the real CASHCAT hook pool, read from the fork
        (uint160 liveSqrtPrice,,,) = IStateView(STATE_VIEW).getSlot0(PoolId.wrap(LIVE_CASHCAT_POOL_ID));
        emit log_named_uint("live CASHCAT pool sqrtPriceX96", liveSqrtPrice);

        (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(0))});
        pm.initialize(key, liveSqrtPrice);

        int24 tick = TickMath.getTickAtSqrtPrice(liveSqrtPrice);
        // one-spacing-wide range fully ABOVE the current tick => owes only currency0
        int24 lower = ((tick / 60) + 1) * 60;
        int24 upper = lower + 60;

        uint256 a0Before = c0.balanceOf(address(this));
        uint256 a1Before = c1.balanceOf(address(this));
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1, salt: 0}),
            ""
        );
        uint256 settle0 = a0Before - c0.balanceOf(address(this));
        uint256 settle1 = a1Before - c1.balanceOf(address(this));
        emit log_named_uint("settle currency0 (wei) for L=1", settle0);
        emit log_named_uint("settle currency1 (wei) for L=1", settle1);
        // regression bound (review concern 1): the L=1 beacon settle must stay
        // value-negligible. 1e6 wei = 1e-12 of an 18d token; measured value is 1 wei
        // at this pool's live price, so a breach means the math or a library changed.
        assertLt(settle0 + settle1, 1e6, "L=1 settle no longer dust");
        assertGt(settle0 + settle1, 0, "L=1 settle should be nonzero");

        // scaling checks so the number is not a rounding fluke
        a0Before = c0.balanceOf(address(this));
        router.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1e6, salt: bytes32(uint256(1))}), ""
        );
        emit log_named_uint("settle currency0 (wei) for L=1e6", a0Before - c0.balanceOf(address(this)));

        a0Before = c0.balanceOf(address(this));
        router.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1e18, salt: bytes32(uint256(2))}), ""
        );
        emit log_named_uint("settle currency0 (wei) for L=1e18", a0Before - c0.balanceOf(address(this)));
    }
}
