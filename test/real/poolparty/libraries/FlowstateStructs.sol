// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/**
 * @title FlowstateStructs
 * @notice Shared data structures for the Flowstate pass-1 rebuild.
 * @dev Spec: docs/FLOWSTATE_PASS1_IMPLEMENTATION_PLAN_2026-07-16.md (§3.1/§3.2).
 */
library FlowstateStructs {
    /// @notice Partner fee-split registration for a reseller code.
    /// @dev Invariant enforced at every write:
    ///      resellerShareBps + bd1ShareBps + bd2ShareBps == PARTNER_SHARE_BPS (6000).
    ///      All wallets are EOA-only (checked at registration AND on every update —
    ///      smart wallets are not address-portable across chains).
    struct ResellerConfig {
        address payable wallet;        // slot A
        uint16 resellerShareBps;       // slot A
        bool registered;               // slot A
        address payable bd1;           // slot B
        uint16 bd1ShareBps;            // slot B
        address payable bd2;           // slot C — address(0) ⇒ bd2ShareBps must be 0
        uint16 bd2ShareBps;            // slot C
    }

    /// @notice Factory-side registry entry for a deployed pool.
    struct PoolRecord {
        address inventoryToken;        // slot A
        bool exists;                   // slot A
        address quoteAsset;            // slot B
    }

    /// @notice Per-fill fee context, computed by the factory and passed to the pool
    ///         in calldata. Never stored.
    struct FeeContext {
        uint16 feeBps;                 // token tier: feeBpsOverride or DEFAULT_FEE_BPS
        address payable resellerWallet;
        uint16 resellerShareBps;
        address payable bd1;
        uint16 bd1ShareBps;
        address payable bd2;
        uint16 bd2ShareBps;
        address buybackReceiver;
        string resellerCode;           // forwarded so trade events emit on the pool address
    }

    /// @notice FIFO ledger node — 2 storage slots (plan R7).
    /// @dev slot A: addr (20B) + next (8B); slot B: amount (16B) + prev (8B).
    ///      Contribution amounts are bounded to uint128 at credit time.
    struct Node {
        address addr;
        uint64 next;
        uint128 amount;
        uint64 prev;
    }

    /// @notice Non-reverting quoter result (§3.1).
    struct Quote {
        bool available;
        uint256 fillableAmount;
        uint256 quoteAmount;
        uint256 feeAmount;
        uint16 feeBps;
        address quoteAsset;
    }
}
