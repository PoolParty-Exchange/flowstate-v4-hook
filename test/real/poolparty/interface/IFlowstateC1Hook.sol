// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @notice The market's view of the V4 hook: exactly the one call createPool makes
///         for JUP-587 auto-registration. `Currency` on the hook side is a
///         user-defined value type over address, so plain addresses ABI-match.
interface IFlowstateC1Hook {
    /// @dev Trusted-market pair registration. Idempotent on the hook side: an
    ///      already-registered pair is left untouched. Reverts bubble to the
    ///      market's try/catch, never to the pool creator.
    function registerPairFromMarket(address quote, address token, address marketPool) external;
}
