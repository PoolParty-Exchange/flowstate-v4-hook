// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {MockInventoryToken} from "../mocks/MockInventoryToken.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    function test_BuySwap_ExactInput_DeliversAtOracleRate() public {
        uint256 quoteIn = 1_000e6;
        uint256 tokBefore = token.balanceOf(swapper);
        uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);

        vm.prank(swapper);
        _swapBuy(-int256(quoteIn), "");

        assertEq(IERC20(USDG).balanceOf(swapper), usdgBefore - quoteIn);
        assertEq(token.balanceOf(swapper) - tokBefore, _marketTokensFor(quoteIn));
        assertEq(token.balanceOf(swapper) - tokBefore, quoteIn * RATE_NUM / RATE_DEN, "fixture equivalence holds");
    }

    function test_HookDataIgnored_ByteIdenticalDeltas() public {
        uint256 snapshot = vm.snapshotState();

        vm.prank(swapper);
        BalanceDelta emptyData = _swapBuy(-1_000e6, "");
        uint256 tokOutEmpty = token.balanceOf(swapper);

        vm.revertToState(snapshot);

        vm.prank(swapper);
        BalanceDelta junkData = _swapBuy(-1_000e6, hex"deadbeef0102030405ffffffffffffffffffffffffffffffff00");
        uint256 tokOutJunk = token.balanceOf(swapper);

        assertEq(BalanceDelta.unwrap(emptyData), BalanceDelta.unwrap(junkData));
        assertEq(tokOutEmpty, tokOutJunk);
    }

    function test_Swap_RevertsTyped_WhenExceedingManagerReserves() public {
        // Reverts inside beforeSwap's reserve check, before any settlement leg,
        // so the swapper needs no funding here.
        uint256 managerUsdg = IERC20(USDG).balanceOf(POOL_MANAGER);
        uint256 oversize = managerUsdg + 1;

        try this.swapBuyExternal(-int256(oversize)) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.ManagerReservesExceeded.selector));
        }
    }

    function swapBuyExternal(int256 amountSpecified) external returns (BalanceDelta) {
        return _swapBuy(amountSpecified, "");
    }
}
