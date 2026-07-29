// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.29;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./poolparty/interface/IOracle.sol";

/// @notice Test-only spot oracle implementing the SAME `IOracle` surface the real
///         FlowstateMarket/FlowstatePool consume (the 1inch spot aggregator shape).
///
/// @dev This is the ONE piece of the stack that is not the production contract, and it
///      is deliberately not: Robinhood Chain has no oracle that can price a freshly
///      minted test inventory token, and the slim RH oracle is Phase 3 of the build
///      scope. Keeping the rate settable is what lets the rounding suite drive the REAL
///      market at an awkward rate whose inversion genuinely loses units.
///
///      Cost shape: one warm-ish SLOAD per read. That makes every gas number taken
///      against this oracle a MARKET+POOL+HOOK number with the oracle term set to
///      ~0 — the true end-to-end figure (with RH's live 1inch-style aggregator) is
///      measured separately in `LiveOracleGas.t.sol`. Both are reported.
contract TestSpotOracle is IOracle {
    mapping(address src => mapping(address dst => uint256 rate)) public rates;

    /// @notice When set, `getRate` reverts — the "oracle failure" state the pool's
    ///         `previewBuy` must translate into a non-quotable pool.
    bool public failing;

    function setRate(address src, address dst, uint256 rate) external {
        rates[src][dst] = rate;
    }

    function setFailing(bool value) external {
        failing = value;
    }

    function getRate(IERC20 srcToken, IERC20 dstToken, bool) external view returns (uint256) {
        require(!failing, "TestSpotOracle: down");
        return rates[address(srcToken)][address(dstToken)];
    }

    function getRateToEth(IERC20, bool) external pure returns (uint256) {
        revert("TestSpotOracle: getRateToEth unused");
    }
}
