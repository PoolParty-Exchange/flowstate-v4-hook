// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deliverable 5: the PoolManager's physical reserves per quote asset are the
///         manager.take() ceilings — the largest single ticket the hook can serve.
///         Measures them at the fork block and proves the ceiling is exact: a buy of
///         the manager's ENTIRE USDG balance executes, one wei more raises the typed
///         reserve revert.
contract ManagerReservesForkTest is ForkTestBase {
    function test_MeasureManagerReserves() public view {
        console2.log("fork block:", block.number);
        console2.log("fork timestamp:", block.timestamp);
        console2.log("PoolManager USDG (raw, 6d):", IERC20(USDG).balanceOf(POOL_MANAGER));
        console2.log("PoolManager aeWETH (raw, 18d):", IERC20(AEWETH).balanceOf(POOL_MANAGER));
        console2.log("PoolManager native ETH (wei):", POOL_MANAGER.balance);
    }

    function test_LargestSafeTicket_FullUsdgReserveExecutes_OneWeiMoreReverts() public {
        uint256 ceiling = IERC20(USDG).balanceOf(POOL_MANAGER);
        uint256 tokensNeeded = ceiling * RATE_NUM / RATE_DEN;
        _contributeInventory(tokensNeeded);
        deal(USDG, swapper, ceiling + 1);

        uint256 snapshot = vm.snapshotState();

        // The full-reserve ticket executes.
        uint256 tokBefore = token.balanceOf(swapper);
        vm.prank(swapper);
        _swapBuy(-int256(ceiling), "");
        assertEq(token.balanceOf(swapper) - tokBefore, tokensNeeded, "full-reserve ticket");
        assertEq(IERC20(USDG).balanceOf(POOL_MANAGER), ceiling, "manager nets zero even at ceiling");

        vm.revertToState(snapshot);

        // One wei above the ceiling raises the explicit typed revert.
        try this.swapBuyExternal(-int256(ceiling + 1)) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.ManagerReservesExceeded.selector));
        }
    }

    function swapBuyExternal(int256 amountSpecified) external returns (BalanceDelta) {
        return _swapBuy(amountSpecified, "");
    }
}
