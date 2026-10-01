// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice Minimal market surface the Gen-4 hook consumes: the registry and quote-asset reads it
///         validates pairs with, the planning reads (supplier registry, inventory floor, passive
///         rate, maxBuy) and the one buy it calls, buyFromPoolBounded, with the input prefunded.
/// @dev The Gen-3 exact-quote and exact-output entry points and their fundBuy callback were
///      dropped from this interface with the Gen-3 path (29 Sep 2026); the hook never calls them.
///      Verified against the real FlowstateMarket by the fork suite and the stack harness, so
///      signature drift on the market side is a compile or test failure here.
interface IFlowstateMarketMinimal {
    /// @notice Canonical Market registry entry for a Flowstate pool.
    /// @dev The public mapping getter returns the PoolRecord fields in declaration order.
    function poolRecords(address pool) external view returns (address inventoryToken, bool exists);

    /// @notice Whether an asset is currently approved as executable quote input.
    function approvedQuoteAssets(address asset) external view returns (bool);

    /// @notice JUP-695 supplier registry; zero while sell-side attribution is off. Gen-4 reads it
    ///         once per swap to plan pool-leg gas.
    function supplierRegistry() external view returns (address);

    /// @notice Per-asset inventory floor: a pool whose sellable stock is worth less stops selling.
    function inventoryFloor(address asset) external view returns (uint256);

    /// @notice JUP-696 passive-lane rate used by both pool and listing settlement.
    function previewRate(address pool, address asset) external view returns (bool ok, uint256 rate);

    /// @notice JUP-612 executable passive inventory within the pool's bounded
    ///         MAX_FILL_NODES traversal. Returns zeroes rather than reverting when
    ///         the pool cannot currently execute.
    function maxBuy(address pool, address asset) external view returns (uint256 maxTokens, uint256 maxQuote);

    function buyFromPoolBounded(
        address pool,
        address asset,
        uint256 amount,
        string calldata resellerCode,
        address buyer,
        uint256 maxCost,
        uint256 minTokensFilled,
        uint256 deadline
    ) external returns (uint256 tokensFilled, uint256 quotePaid);
}
