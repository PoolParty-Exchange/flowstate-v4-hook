// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Overflow-free comparison of two 256x256-bit products (PR #28
///         review): a·b vs c·d compared over their full 512-bit values, so a
///         caller- or owner-supplied extreme operand can never panic a bounds
///         check or a read that is defined to degrade gracefully. Raw cross
///         multiplication was the original shape in both the bounded entry
///         points (caller-supplied `amount`) and the divergence check
///         (owner-supplied threshold); both could be made to revert with
///         inputs whose comparison is perfectly well-defined.
library Mul512Compare {
    /// @dev a·b > c·d, exact over 512 bits, never reverts.
    function gt(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = _mul512(a, b);
        (uint256 h2, uint256 l2) = _mul512(c, d);
        return h1 > h2 || (h1 == h2 && l1 > l2);
    }

    /// @dev a·b < c·d, exact over 512 bits, never reverts.
    function lt(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        return gt(c, d, a, b);
    }

    /// @dev The two-limb full product: mulmod over 2^256-1 recovers the high
    ///      limb (the full-precision identity OZ Math.mulDiv builds on:
    ///      hi = mm - lo, borrowing 1 when mm < lo, where mm = a·b mod 2^256-1).
    function _mul512(uint256 a, uint256 b) private pure returns (uint256 hi, uint256 lo) {
        unchecked {
            uint256 mm = mulmod(a, b, type(uint256).max);
            lo = a * b;
            hi = mm - lo;
            if (mm < lo) hi--;
        }
    }
}
