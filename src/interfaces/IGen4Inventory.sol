// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @notice JUP-697 one-candidate listing inspection surface pinned at
///         PoolParty_Contracts PR #54 head de4464f.
interface IGen4ListingRegistry {
    function market() external view returns (address);

    function peek(address token)
        external
        view
        returns (uint8 state, uint64 id, uint64 createdBlock, uint256 available, uint32 version, uint64 poolTail);
}

/// @notice JUP-697 one-candidate settlement surface. Gen-4 always supplies a
///         non-zero listingId and its inspected version; legacy walking mode is
///         deliberately unreachable through this adapter.
interface IGen4ListingSettlement {
    function market() external view returns (address);
    function registry() external view returns (address);
    function price(address token, address quoteAsset) external view returns (uint8 why, uint256 rate);

    function settleHead(
        address token,
        uint64 listingId,
        uint32 version,
        uint256 maxAmount,
        address quoteAsset,
        uint256 maxQuoteIn,
        address recipient,
        string calldata resellerCode,
        uint256 deadline
    ) external returns (uint8 outcome, uint64 id, uint256 filled, uint256 quotePaid);
}

/// @notice Pool queue read model added by JUP-688/JUP-697. The index is
///         append-only; `pinned` is the active pinned amount, already clamped to
///         `amount` by the pool.
interface IGen4Pool {
    struct QueueNode {
        uint64 index;
        address owner;
        uint128 amount;
        uint128 pinned;
        uint32 pinNonce;
    }

    function queue(uint256 maxNodes) external view returns (QueueNode[] memory);
    function tokenQueueEnds() external view returns (uint64 head, uint64 tail);
}
