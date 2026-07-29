// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @dev Minimal burn surface for FLOW (fallback path handles tokens without it).
interface IERC20Burnable {
    function burn(uint256 amount) external;
}

/**
 * @dev Venue adapter for keeper swaps (plan §3.3): routing complexity lives in
 *      owner-vetted adapter contracts, not in pathData blobs — the accumulators only
 *      know "adapter address per input asset". assetIn == address(0) means native
 *      (sent as msg.value). Output is ALWAYS measured by the caller via balance-diff;
 *      the return value is informational.
 */
interface ISwapAdapter {
    function swapExactInput(address tokenIn, uint256 amountIn, address tokenOut, address recipient)
        external
        payable
        returns (uint256 amountOut);
}

/**
 * @dev Bridge adapter (Stargate/LZ binds when the home chain lands — destination is
 *      config, per the scope's deferred-by-design constraint).
 */
interface IBridgeAdapter {
    function quoteBridgeFee(address asset, address destination, uint32 dstEid)
        external
        view
        returns (uint256 nativeFee);

    function bridge(address asset, uint256 amount, address destination, uint32 dstEid, address refund)
        external
        payable;
}
