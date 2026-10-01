// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Gen4Queue} from "../src/libraries/Gen4Queue.sol";
import {Gen4Accounting} from "../src/libraries/Gen4Accounting.sol";
import {IGen4Pool} from "../src/interfaces/IGen4Inventory.sol";

/// @notice Conformance tests for the production selector and accounting primitives
///         consumed directly by FlowstateC1Hook's Gen-4 loop.
contract Gen4MixedQueueConformanceTest is Test {
    uint256 internal constant SPREAD_BPS = 16;
    uint256 internal constant JAR_BPS = 8;

    function test_PoolWinsExactlyAtListingTail() public pure {
        assertEq(uint256(Gen4Queue.select(true, 7, true, 7)), uint256(Gen4Queue.Source.Pool));
    }

    function test_ListingWinsBeforeLaterPoolNode() public pure {
        assertEq(uint256(Gen4Queue.select(true, 8, true, 7)), uint256(Gen4Queue.Source.Listing));
    }

    function test_DeadListingStillExistsAndMustBeAttempted() public pure {
        assertEq(uint256(Gen4Queue.select(false, 0, true, 4)), uint256(Gen4Queue.Source.Listing));
    }

    function test_DepositListingDepositOrdersByPoolTail() public pure {
        uint64 firstDeposit = 11;
        uint64 listingTail = firstDeposit;
        uint64 secondDeposit = 12;
        assertEq(uint256(Gen4Queue.select(true, firstDeposit, true, listingTail)), uint256(Gen4Queue.Source.Pool));
        assertEq(uint256(Gen4Queue.select(true, secondDeposit, true, listingTail)), uint256(Gen4Queue.Source.Listing));
    }

    function test_TopUpKeepsEarlierIndexAndPosition() public pure {
        IGen4Pool.QueueNode[] memory nodes = _nodes(1);
        nodes[0] = _node(5, 9, 0);
        (, uint256 beforeListing,) = Gen4Queue.inspect(nodes, 5);
        assertEq(beforeListing, 9);
    }

    function test_HoldBreakRequeueMovesBehindExistingListing() public pure {
        assertEq(uint256(Gen4Queue.select(true, 22, true, 21)), uint256(Gen4Queue.Source.Listing));
    }

    function test_PinnedInventoryExcludedAtBoundary() public pure {
        IGen4Pool.QueueNode[] memory nodes = _nodes(3);
        nodes[0] = _node(1, 10, 7);
        nodes[1] = _node(2, 20, 20);
        nodes[2] = _node(3, 30, 5);
        (uint64 first, uint256 bounded, uint256 total) = Gen4Queue.inspect(nodes, 2);
        assertEq(first, 1);
        assertEq(bounded, 3);
        assertEq(total, 28);
    }

    function test_FullyPinnedHeadDoesNotHideLaterExecutableNode() public pure {
        IGen4Pool.QueueNode[] memory nodes = _nodes(2);
        nodes[0] = _node(9, 10, 10);
        nodes[1] = _node(10, 4, 0);
        (uint64 first, uint256 bounded,) = Gen4Queue.inspect(nodes, 9);
        assertEq(first, 10);
        assertEq(bounded, 0);
        assertEq(uint256(Gen4Queue.select(bounded != 0, first, true, 9)), uint256(Gen4Queue.Source.Listing));
    }

    function test_BoundedPoolLegCannotCrossListingTail() public pure {
        IGen4Pool.QueueNode[] memory nodes = _nodes(3);
        nodes[0] = _node(40, 3, 0);
        nodes[1] = _node(41, 5, 2);
        nodes[2] = _node(42, 100, 0);
        (, uint256 bounded, uint256 total) = Gen4Queue.inspect(nodes, 41);
        assertEq(bounded, 6);
        assertEq(total, 106);
    }

    // sizeForGas: a pool leg never plans more nodes than its gas budget walks (JUP-698 gate 1 finding)
    function test_SizeForGasStopsAtTheBudget() public pure {
        IGen4Pool.QueueNode[] memory nodes = _nodes(4);
        nodes[0] = _node(1, 10, 0);
        nodes[1] = _node(2, 20, 0);
        nodes[2] = _node(3, 30, 0);
        nodes[3] = _node(4, 40, 0);
        assertEq(Gen4Queue.sizeForGas(nodes, type(uint64).max, 0, 100, 10), 0);
        assertEq(Gen4Queue.sizeForGas(nodes, type(uint64).max, 99, 100, 10), 0);
        assertEq(Gen4Queue.sizeForGas(nodes, type(uint64).max, 100, 100, 10), 10);
        assertEq(Gen4Queue.sizeForGas(nodes, type(uint64).max, 299, 100, 10), 30);
        assertEq(Gen4Queue.sizeForGas(nodes, type(uint64).max, 400, 100, 10), 100);
    }

    function test_SizeForGasNeverCrossesTheListingBoundary() public pure {
        IGen4Pool.QueueNode[] memory nodes = _nodes(3);
        nodes[0] = _node(7, 10, 0);
        nodes[1] = _node(8, 20, 5);
        nodes[2] = _node(9, 30, 0);
        assertEq(Gen4Queue.sizeForGas(nodes, 8, type(uint256).max, 100, 10), 25);
        assertEq(Gen4Queue.sizeForGas(nodes, 6, type(uint256).max, 100, 10), 0);
    }

    function test_SizeForGasChargesPinnedNodesOnlyTheSkip() public pure {
        IGen4Pool.QueueNode[] memory nodes = _nodes(3);
        nodes[0] = _node(1, 10, 10);
        nodes[1] = _node(2, 10, 10);
        nodes[2] = _node(3, 30, 0);
        assertEq(Gen4Queue.sizeForGas(nodes, type(uint64).max, 120, 100, 10), 30);
        assertEq(Gen4Queue.sizeForGas(nodes, type(uint64).max, 119, 100, 10), 0);
    }

    function test_ActualAmountsDriveAggregateAccounting() public pure {
        Gen4Accounting.Totals memory totals;
        Gen4Accounting.recordPool(totals, 4, 39);
        Gen4Accounting.recordListingAttempt(totals, 4, true, 3, 31);
        Gen4Accounting.Final memory result = Gen4Accounting.exactOutput(totals, SPREAD_BPS, JAR_BPS);
        assertEq(result.tokensOut, 7);
        assertEq(result.cost, 70);
        assertEq(result.spread, 1);
        assertEq(result.jarFee, 1);
    }

    function test_UnsuccessfulListingRetainsNoBuyerFunds() public pure {
        Gen4Accounting.Totals memory totals;
        Gen4Accounting.recordPool(totals, 2, 20);
        Gen4Accounting.recordListingAttempt(totals, 4, false, 999, 999);
        // a complete fill (WSR F5): the committed input is cost + spread; nothing is refunded
        Gen4Accounting.Final memory result = Gen4Accounting.exactInput(totals, 21, SPREAD_BPS, JAR_BPS);
        assertEq(result.cost, 20);
        assertEq(result.dust, 0);
        assertEq(result.charged, 21);
    }

    function test_ExactOutputRemainingUsesActualMixedFills() public pure {
        Gen4Accounting.Totals memory totals;
        Gen4Accounting.recordPool(totals, 4, 40);
        assertEq(Gen4Accounting.remainingOutput(totals, 10), 6);
        Gen4Accounting.recordListingAttempt(totals, 4, true, 2, 20);
        assertEq(Gen4Accounting.remainingOutput(totals, 10), 4);
    }

    function _nodes(uint256 length) private pure returns (IGen4Pool.QueueNode[] memory) {
        return new IGen4Pool.QueueNode[](length);
    }

    function _node(uint64 index, uint128 amount, uint128 pinned)
        private
        pure
        returns (IGen4Pool.QueueNode memory)
    {
        return IGen4Pool.QueueNode(index, address(uint160(index)), amount, pinned, 0);
    }
}
