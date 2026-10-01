// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deliverable 5: the PoolManager's physical reserves per quote asset are the
///         manager.take() ceilings — the largest single ticket the hook can serve.
///         Measures them at the fork block. The proof that the ceiling is exact (a buy of
///         the manager's entire balance fills, one raw unit more raises the typed
///         ManagerReservesExceeded) ran the deleted Gen-3 path here; since 29 Sep 2026 it is
///         in test/stack/gen4-stack.test.cjs ("PoolManager reserves"), both directions.
contract ManagerReservesForkTest is ForkTestBase {
    function test_MeasureManagerReserves() public view {
        console2.log("fork block:", block.number);
        console2.log("fork timestamp:", block.timestamp);
        console2.log("PoolManager USDG (raw, 6d):", IERC20(USDG).balanceOf(POOL_MANAGER));
        console2.log("PoolManager aeWETH (raw, 18d):", IERC20(AEWETH).balanceOf(POOL_MANAGER));
        console2.log("PoolManager native ETH (wei):", POOL_MANAGER.balance);
    }
}
