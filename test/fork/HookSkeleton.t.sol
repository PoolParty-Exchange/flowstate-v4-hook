// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {MockInventoryToken} from "../mocks/MockInventoryToken.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract HookSkeletonForkTest is ForkTestBase {
    function test_HookAddressHasExactFlags0x28cc() public view {
        assertEq(uint160(address(hook)) & ((1 << 14) - 1), uint160(0x28cc));
    }

    function test_PoolInitializedAgainstRealManager() public {
        // Re-initializing the same key must revert: proof the pool exists on the
        // REAL RH PoolManager, not a local deployment.
        vm.expectRevert();
        manager.initialize(poolKey, _sqrtPriceForMockRate());
    }

    function test_BeforeInitialize_RevertsUnregisteredPair() public {
        MockInventoryToken stranger = new MockInventoryToken();
        (Currency c0, Currency c1) = USDG < address(stranger)
            ? (Currency.wrap(USDG), Currency.wrap(address(stranger)))
            : (Currency.wrap(address(stranger)), Currency.wrap(USDG));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});

        try manager.initialize(key, _sqrtPriceForMockRate()) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.PairNotRegistered.selector));
        }
    }

    function test_BeforeInitialize_RevertsNonZeroLpFee() public {
        PoolKey memory key = PoolKey({
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        try manager.initialize(key, _sqrtPriceForMockRate()) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.LpFeeMustBeZero.selector));
        }
    }

    function test_BeforeAddLiquidity_RevertsTyped() public {
        try lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        ) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.LiquidityNotAllowed.selector));
        }
    }

    // 29 Sep 2026: the three swap tests (exact input at the oracle rate, hookData ignored, the typed
    // ManagerReservesExceeded revert) ran the deleted Gen-3 path; their Gen-4 versions are in
    // test/stack/gen4-stack.test.cjs ("ported from the forge fork suite").
}
