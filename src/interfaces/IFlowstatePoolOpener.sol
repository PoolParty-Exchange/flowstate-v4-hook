// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Gen-6 (JUP-772, 24 Oct 2026): the hook's own door-opening periphery, an immutable
///         dependency of the hook (constructor argument), never of the frontend. The hook calls it
///         inside the user's own transaction: `open` when a pair is registered (createPool, or the
///         owner's registerPair), `lightBeacon` on a pool's first fill.
interface IFlowstatePoolOpener {
    /// @notice Initialise the V4 pool of a pair registered on the hook, on the PoolManager, at the C1
    ///         pool's anchor price for the pair's market asset (1:1 when the anchor is unseeded; the
    ///         price is cosmetic, the hook overrides all pricing). Permissionless and idempotent: an
    ///         initialised pool answers true without a call; an unregistered pair answers false (the
    ///         hook's beforeInitialize refuses it). Never reverts.
    function open(Currency quote, Currency token) external returns (bool opened);

    /// @notice Light a pool's visibility beacon (JUP-516: one liquidityDelta == 1 add) paid by the hook
    ///         in the pool's currency on the side `payIsCurrency0` names, pulled from the hook's
    ///         allowance in the asset the hook holds for it (the wrapper where the pool owes native,
    ///         unwrapped here), at most `maxPay`. Hook-only. Returns what it cost.
    function lightBeacon(PoolKey calldata key, bool payIsCurrency0, uint256 maxPay) external returns (uint256 paid);
}
