// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deliverable 4: flash-accounting round trip with REAL USDG as the input
///         currency and the mock inventory token as output.
///
///         Flow inside one unlock: hook takes quoteIn USDG out of the PoolManager
///         (debt), the market pulls exactly quoteIn from the hook, the hook settles
///         tokensOut into the manager, then the swapper's settlement leg transfers
///         exactly quoteIn USDG back into the manager. Net manager deltas are zero on
///         both currencies; the inbound settlement leg equals the swapper's payment,
///         which is forced by the conservation asserts below (manager nets zero while
///         the swapper paid quoteIn and the market received exactly quoteIn).
contract TakeSettleForkTest is ForkTestBase {
    struct Balances {
        uint256 managerUsdg;
        uint256 managerTok;
        uint256 swapperUsdg;
        uint256 swapperTok;
        uint256 marketUsdg;
        uint256 marketTok;
        uint256 hookUsdg;
        uint256 hookTok;
    }

    function _snap() internal view returns (Balances memory b) {
        b.managerUsdg = IERC20(USDG).balanceOf(POOL_MANAGER);
        b.managerTok = token.balanceOf(POOL_MANAGER);
        b.swapperUsdg = IERC20(USDG).balanceOf(swapper);
        b.swapperTok = token.balanceOf(swapper);
        b.marketUsdg = IERC20(USDG).balanceOf(address(market));
        b.marketTok = token.balanceOf(address(market));
        b.hookUsdg = IERC20(USDG).balanceOf(address(hook));
        b.hookTok = token.balanceOf(address(hook));
    }

    function test_TakeSettleRoundTrip_ExactInput() public {
        uint256 quoteIn = 1_000e6;
        uint256 tokensOut = quoteIn * RATE_NUM / RATE_DEN;
        Balances memory pre = _snap();
        assertEq(pre.hookUsdg, 0);
        assertEq(pre.hookTok, 0);

        vm.prank(swapper);
        _swapBuy(-int256(quoteIn), "");

        Balances memory post = _snap();

        // Flash accounting nets to zero: the unlock closed, and the manager's
        // physical balances are unchanged on both currencies.
        assertEq(post.managerUsdg, pre.managerUsdg, "manager USDG must net zero");
        assertEq(post.managerTok, pre.managerTok, "manager TOK must net zero");

        // The swapper's payment flowed through manager + hook into the market,
        // to the wei; tokens flowed market -> manager -> swapper.
        assertEq(pre.swapperUsdg - post.swapperUsdg, quoteIn, "swapper payment");
        assertEq(post.marketUsdg - pre.marketUsdg, quoteIn, "market received payment");
        assertEq(post.swapperTok - pre.swapperTok, tokensOut, "swapper received tokens");
        assertEq(pre.marketTok - post.marketTok, tokensOut, "market shipped tokens");

        // No residue on the hook: balances beyond a single unlock are zero.
        assertEq(post.hookUsdg, 0, "hook USDG residue");
        assertEq(post.hookTok, 0, "hook TOK residue");
    }

    function test_TakeSettleRoundTrip_ExactOutput() public {
        uint256 tokensOut = 2_000e18;
        uint256 quoteIn = (tokensOut * RATE_DEN + RATE_NUM - 1) / RATE_NUM;
        Balances memory pre = _snap();

        vm.prank(swapper);
        _swapBuy(int256(tokensOut), "");

        Balances memory post = _snap();

        assertEq(post.managerUsdg, pre.managerUsdg, "manager USDG must net zero");
        assertEq(post.managerTok, pre.managerTok, "manager TOK must net zero");
        assertEq(pre.swapperUsdg - post.swapperUsdg, quoteIn, "swapper payment");
        assertEq(post.marketUsdg - pre.marketUsdg, quoteIn, "market received payment");
        assertEq(post.swapperTok - pre.swapperTok, tokensOut, "swapper received tokens");
        assertEq(pre.marketTok - post.marketTok, tokensOut, "market shipped tokens");
        assertEq(post.hookUsdg, 0, "hook USDG residue");
        assertEq(post.hookTok, 0, "hook TOK residue");
    }
}
