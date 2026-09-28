// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

/// @notice The acceptance gate from scope rule 2: the canonical RH V4Quoter must return
///         quotes for the buy direction that match execution to the wei, from arbitrary
///         senders, with empty hookData; and both sell-direction paths must raise the
///         same typed error at quote time and swap time.
/// @dev 29 Sep 2026: the two buy-direction parity tests ran the deleted Gen-3 path and are
///      retired; buy parity (pool only and pool + listing, both directions, any sender, and
///      identical declines) is in test/stack/gen4-stack.test.cjs ("quote parity"), against
///      Uniswap's V4Quoter deployed on the stack's PoolManager. The sell direction reverts in
///      beforeSwap before any buy path, so those four tests still run here.
contract QuoterParityForkTest is ForkTestBase {
    address freshSender = makeAddr("arbitrary-fresh-eoa");

    // -- Deliverable 3: sell-path typed-revert parity -------------------------

    function test_QuoterSellExactInput_RevertsTyped() public {
        vm.prank(freshSender);
        try quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: !_buyZeroForOne(),
                exactAmount: 1e18,
                hookData: ""
            })
        ) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.SellDirectionNotSupported.selector));
        }
    }

    function test_QuoterSellExactOutput_RevertsTyped() public {
        vm.prank(freshSender);
        try quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: !_buyZeroForOne(),
                exactAmount: 1e6,
                hookData: ""
            })
        ) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.SellDirectionNotSupported.selector));
        }
    }

    function test_SwapSellExactInput_RevertsIdenticallyToQuoter() public {
        try this.swapSellExternal(-1e18) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.SellDirectionNotSupported.selector));
        }
    }

    function test_SwapSellExactOutput_RevertsIdenticallyToQuoter() public {
        try this.swapSellExternal(1e6) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(_containsSelector(reason, FlowstateC1Hook.SellDirectionNotSupported.selector));
        }
    }

    function swapSellExternal(int256 amountSpecified) external {
        _swapSell(amountSpecified);
    }
}
