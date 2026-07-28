// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {FlowstateC1Hook} from "../../src/FlowstateC1Hook.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @notice The acceptance gate from scope rule 2: the canonical RH V4Quoter must return
///         quotes for the buy direction that match execution to the wei, from arbitrary
///         senders, with empty hookData; and both sell-direction paths must raise the
///         same typed error at quote time and swap time.
contract QuoterParityForkTest is ForkTestBase {
    address freshSender = makeAddr("arbitrary-fresh-eoa");

    function _quoteBuyExactIn(address caller, uint128 quoteIn) internal returns (uint256 amountOut, uint256 gasEst) {
        vm.prank(caller);
        return quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: _buyZeroForOne(),
                exactAmount: quoteIn,
                hookData: ""
            })
        );
    }

    function _quoteBuyExactOut(address caller, uint128 tokensOut) internal returns (uint256 amountIn, uint256 gasEst) {
        vm.prank(caller);
        return quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: _buyZeroForOne(),
                exactAmount: tokensOut,
                hookData: ""
            })
        );
    }

    // -- Deliverable 2: buy-path parity ---------------------------------------

    function test_QuoterBuyExactInput_ParityAtThreeSizes() public {
        uint128[3] memory sizes = [uint128(10e6), uint128(1_000e6), uint128(25_000e6)];

        for (uint256 i = 0; i < sizes.length; i++) {
            (uint256 quotedFresh, uint256 gasEst) = _quoteBuyExactIn(freshSender, sizes[i]);
            (uint256 quotedZero,) = _quoteBuyExactIn(address(0), sizes[i]);
            assertEq(quotedFresh, quotedZero, "quote differs by sender");
            assertGt(quotedFresh, 0);

            uint256 tokBefore = token.balanceOf(swapper);
            uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);
            vm.prank(swapper);
            _swapBuy(-int256(uint256(sizes[i])), "");

            assertEq(token.balanceOf(swapper) - tokBefore, quotedFresh, "delivered != quoted");
            assertEq(usdgBefore - IERC20(USDG).balanceOf(swapper), uint256(sizes[i]), "input != specified");
            console2.log("exactIn size (USDG raw):", sizes[i]);
            console2.log("  quoted tokensOut:", quotedFresh);
            console2.log("  quoter gasEstimate:", gasEst);
        }
    }

    function test_QuoterBuyExactOutput_ParityAtThreeSizes() public {
        uint128[3] memory sizes = [uint128(20e18), uint128(2_000e18), uint128(50_000e18)];

        for (uint256 i = 0; i < sizes.length; i++) {
            (uint256 quotedFresh, uint256 gasEst) = _quoteBuyExactOut(freshSender, sizes[i]);
            (uint256 quotedZero,) = _quoteBuyExactOut(address(0), sizes[i]);
            assertEq(quotedFresh, quotedZero, "quote differs by sender");
            assertGt(quotedFresh, 0);

            uint256 tokBefore = token.balanceOf(swapper);
            uint256 usdgBefore = IERC20(USDG).balanceOf(swapper);
            vm.prank(swapper);
            _swapBuy(int256(uint256(sizes[i])), "");

            assertEq(token.balanceOf(swapper) - tokBefore, uint256(sizes[i]), "delivered != specified");
            assertEq(usdgBefore - IERC20(USDG).balanceOf(swapper), quotedFresh, "paid != quoted");
            console2.log("exactOut size (FLOWMOCK raw):", sizes[i]);
            console2.log("  quoted usdgIn:", quotedFresh);
            console2.log("  quoter gasEstimate:", gasEst);
        }
    }

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
