// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Flash-accounting round trip with REAL USDG as the input currency, the mock
///         inventory token as output, and the REAL FlowstateMarket + FlowstatePool as
///         the counterparty.
///
///         Flow inside one unlock: the hook takes quoteIn USDG out of the PoolManager
///         (debt), the market pulls exactly the band-checked oracle cost from the hook
///         straight into the POOL, the pool carves the seller-leg fee and pushes it to
///         the buyback receiver, ships the tokens to the hook, the hook settles them
///         into the manager, and the swapper's settlement leg returns exactly quoteIn
///         USDG. Net manager deltas are zero on both currencies.
///
/// @dev The one shape change versus the Phase 0 mock: the buyer's payment no longer
///      lands in a single contract. `quotePaid` splits into `pool` (held against the
///      contributor's claim) and `stack.receiver` (the 30/30/40 fee, all of which
///      routes to buyback here because no reseller code is registered). The buyer pays
///      the same wei either way — the fee is on the SELLER leg — so nothing the hook
///      quotes moves. Conservation is asserted over the pair.
contract TakeSettleForkTest is ForkTestBase {
    struct Balances {
        uint256 managerUsdg;
        uint256 managerTok;
        uint256 swapperUsdg;
        uint256 swapperTok;
        uint256 poolUsdg;
        uint256 poolTok;
        uint256 receiverUsdg;
        uint256 hookUsdg;
        uint256 hookTok;
        uint256 listerClaimable;
    }

    function _snap() internal view returns (Balances memory b) {
        b.managerUsdg = IERC20(USDG).balanceOf(POOL_MANAGER);
        b.managerTok = token.balanceOf(POOL_MANAGER);
        b.swapperUsdg = IERC20(USDG).balanceOf(swapper);
        b.swapperTok = token.balanceOf(swapper);
        b.poolUsdg = IERC20(USDG).balanceOf(pool);
        b.poolTok = token.balanceOf(pool);
        b.receiverUsdg = IERC20(USDG).balanceOf(stack.receiver);
        b.hookUsdg = IERC20(USDG).balanceOf(address(hook));
        b.hookTok = token.balanceOf(address(hook));
        b.listerClaimable = poolContract.claimableQuote(lister);
    }

    function _assertConservation(Balances memory pre, Balances memory post, uint256 quotePaid, uint256 tokensOut)
        internal
        view
    {
        uint256 fee = _feeOn(quotePaid);

        // Flash accounting nets to zero: the unlock closed, and the manager's physical
        // balances are unchanged on both currencies.
        assertEq(post.managerUsdg, pre.managerUsdg, "manager USDG must net zero");
        assertEq(post.managerTok, pre.managerTok, "manager TOK must net zero");

        // The swapper's payment flowed through manager + hook into pool + receiver.
        assertEq(pre.swapperUsdg - post.swapperUsdg, quotePaid, "swapper payment");
        assertEq(
            (post.poolUsdg - pre.poolUsdg) + (post.receiverUsdg - pre.receiverUsdg),
            quotePaid,
            "pool + buyback receiver together received the payment"
        );
        assertEq(post.receiverUsdg - pre.receiverUsdg, fee, "buyback receiver took exactly the seller-leg fee");
        assertEq(post.poolUsdg - pre.poolUsdg, quotePaid - fee, "pool holds the net for the contributor");

        // Contributor ledger: the lister is credited the net, to the wei.
        assertEq(post.listerClaimable - pre.listerClaimable, quotePaid - fee, "contributor credited net proceeds");

        // Tokens flowed pool -> hook -> manager -> swapper.
        assertEq(post.swapperTok - pre.swapperTok, tokensOut, "swapper received tokens");
        assertEq(pre.poolTok - post.poolTok, tokensOut, "pool shipped tokens");

        // No residue on the hook: balances beyond a single unlock are zero (base spread
        // is 0 in this fixture, so not even margin accrues).
        assertEq(post.hookUsdg, 0, "hook USDG residue");
        assertEq(post.hookTok, 0, "hook TOK residue");
    }

    function test_TakeSettleRoundTrip_ExactInput() public {
        uint256 quoteIn = 1_000e6;
        uint256 tokensOut = _marketTokensFor(quoteIn);
        uint256 quotePaid = _marketCostFor(tokensOut);
        assertEq(quotePaid, quoteIn, "fixture rate inverts exactly, so no dust");

        Balances memory pre = _snap();
        assertEq(pre.hookUsdg, 0);
        assertEq(pre.hookTok, 0);

        vm.prank(swapper);
        _swapBuy(-int256(quoteIn), "");

        _assertConservation(pre, _snap(), quotePaid, tokensOut);
    }

    function test_TakeSettleRoundTrip_ExactOutput() public {
        uint256 tokensOut = 2_000e18;
        uint256 quotePaid = _marketCostFor(tokensOut);

        Balances memory pre = _snap();

        vm.prank(swapper);
        _swapBuy(int256(tokensOut), "");

        _assertConservation(pre, _snap(), quotePaid, tokensOut);
    }

    /// @dev The pool's claim ledger is the exit path (scope §4: sellers exit through C1
    ///      deposit-and-claim, off-hook). Prove a routed V4 buy leaves the contributor
    ///      with a genuinely claimable position, not just a number.
    function test_ContributorCanClaimProceedsOfARoutedV4Buy() public {
        uint256 quoteIn = 5_000e6;
        vm.prank(swapper);
        _swapBuy(-int256(quoteIn), "");

        uint256 claimable = poolContract.claimableQuote(lister);
        assertEq(claimable, quoteIn - _feeOn(quoteIn), "credited net of the seller-leg fee");

        uint256 before = IERC20(USDG).balanceOf(lister);
        vm.prank(lister);
        (bool ok,) = pool.call(abi.encodeWithSignature("claimQuote()"));
        assertTrue(ok, "claimQuote");
        assertEq(IERC20(USDG).balanceOf(lister) - before, claimable, "claimed to the wei");
        assertEq(poolContract.claimableQuote(lister), 0, "ledger cleared");
    }
}
