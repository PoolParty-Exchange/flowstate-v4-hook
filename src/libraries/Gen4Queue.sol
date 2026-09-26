// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IGen4Pool} from "../interfaces/IGen4Inventory.sol";

/// @notice Production FIFO primitives for the Gen-4 mixed pool/listing lane.
/// @dev JUP-697 supplies a definitive cross-source boundary: a pool node was
///      queued before a listing exactly when node.index <= listing.poolTail.
library Gen4Queue {
    enum Source {
        None,
        Pool,
        Listing
    }

    /// @notice Select the globally oldest executable source.
    /// @dev A dead listing still exists and must be selected/retired when no
    ///      executable pool node predates it. `poolIndex` is the first node with
    ///      unpinned inventory, not merely the linked-list head.
    function select(bool hasPool, uint64 poolIndex, bool hasListing, uint64 listingPoolTail)
        internal
        pure
        returns (Source)
    {
        if (!hasListing) return hasPool ? Source.Pool : Source.None;
        if (!hasPool) return Source.Listing;
        return poolIndex <= listingPoolTail ? Source.Pool : Source.Listing;
    }

    /// @notice Inspect only the pool's bounded traversal and return the first
    ///         executable node plus inventory that may be consumed before the
    ///         listing boundary. Passing max uint64 means no listing boundary.
    /// @notice The inventory a pool leg may take within `gasBudget`: executable nodes at or below
    ///         `poolTail`, in queue order, each costing `nodeGas` (a fully pinned node, which the
    ///         market's walk only steps over, `skipGas`), stopping before the budget would be passed.
    function sizeForGas(
        IGen4Pool.QueueNode[] memory nodes,
        uint64 poolTail,
        uint256 gasBudget,
        uint256 nodeGas,
        uint256 skipGas
    ) internal pure returns (uint256 amount) {
        uint256 used;
        uint256 length = nodes.length;
        for (uint256 i; i < length; ++i) {
            IGen4Pool.QueueNode memory node = nodes[i];
            if (node.index > poolTail) break;
            uint256 available = uint256(node.amount) - uint256(node.pinned);
            uint256 cost = available == 0 ? skipGas : nodeGas;
            if (used + cost > gasBudget) break;
            used += cost;
            amount += available;
        }
    }

    function inspect(IGen4Pool.QueueNode[] memory nodes, uint64 poolTail)
        internal
        pure
        returns (uint64 firstIndex, uint256 boundedAvailable, uint256 totalAvailable)
    {
        uint256 length = nodes.length;
        for (uint256 i; i < length; ++i) {
            IGen4Pool.QueueNode memory node = nodes[i];
            uint256 available = uint256(node.amount) - uint256(node.pinned);
            if (available == 0) continue;
            if (firstIndex == 0) firstIndex = node.index;
            totalAvailable += available;
            if (node.index <= poolTail) boundedAvailable += available;
        }
    }
}
