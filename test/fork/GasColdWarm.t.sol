// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Cold vs warm gas for the quoter-parity path (scope §6 leans on the
///         same-block-cache distinction).
///
///         Forge resets EIP-2929 access-list warmth per test function, so within one
///         test the FIRST call is the cold measurement (cold storage on the pool
///         config, registry, mock market, USDG proxy) and the second identical call
///         in the same block is the warm one. The swap test issues no quoter call
///         first, so its cold swap matches routed reality: a backend's eth_call
///         quote warms nothing for the on-chain swap that follows.
contract GasColdWarmForkTest is ForkTestBase {
    uint128 constant QUOTE_IN = 1_000e6;
    uint128 constant TOKENS_OUT = 2_000e18;

    function _callQuoterExactIn() internal returns (uint256 gasEstimate, uint256 callGas) {
        IV4Quoter.QuoteExactSingleParams memory p = IV4Quoter.QuoteExactSingleParams({
            poolKey: poolKey,
            zeroForOne: _buyZeroForOne(),
            exactAmount: QUOTE_IN,
            hookData: ""
        });
        uint256 g = gasleft();
        (, gasEstimate) = quoter.quoteExactInputSingle(p);
        callGas = g - gasleft();
    }

    function _callQuoterExactOut() internal returns (uint256 gasEstimate, uint256 callGas) {
        IV4Quoter.QuoteExactSingleParams memory p = IV4Quoter.QuoteExactSingleParams({
            poolKey: poolKey,
            zeroForOne: _buyZeroForOne(),
            exactAmount: TOKENS_OUT,
            hookData: ""
        });
        uint256 g = gasleft();
        (, gasEstimate) = quoter.quoteExactOutputSingle(p);
        callGas = g - gasleft();
    }

    function test_Gas_QuoterExactIn_ColdThenWarm() public {
        (uint256 estCold, uint256 callCold) = _callQuoterExactIn();
        (uint256 estWarm, uint256 callWarm) = _callQuoterExactIn();
        console2.log("quoteExactInputSingle COLD: gasEstimate", estCold, "| call gas", callCold);
        console2.log("quoteExactInputSingle WARM: gasEstimate", estWarm, "| call gas", callWarm);
        assertLt(estWarm, estCold);
    }

    function test_Gas_QuoterExactOut_ColdThenWarm() public {
        (uint256 estCold, uint256 callCold) = _callQuoterExactOut();
        (uint256 estWarm, uint256 callWarm) = _callQuoterExactOut();
        console2.log("quoteExactOutputSingle COLD: gasEstimate", estCold, "| call gas", callCold);
        console2.log("quoteExactOutputSingle WARM: gasEstimate", estWarm, "| call gas", callWarm);
        assertLt(estWarm, estCold);
    }

    function test_Gas_SwapExactIn_ColdThenWarm_SameBlock() public {
        uint256 blockBefore = block.number;

        vm.prank(swapper);
        uint256 g = gasleft();
        _swapBuy(-int256(uint256(QUOTE_IN)), "");
        uint256 cold = g - gasleft();

        vm.prank(swapper);
        g = gasleft();
        _swapBuy(-int256(uint256(QUOTE_IN)), "");
        uint256 warm = g - gasleft();

        assertEq(block.number, blockBefore, "both swaps in one block");
        console2.log("swap exactIn COLD (first in block):", cold);
        console2.log("swap exactIn WARM (same block):", warm);
        assertLt(warm, cold);
    }

    function test_Gas_SwapExactOut_ColdThenWarm_SameBlock() public {
        uint256 blockBefore = block.number;

        vm.prank(swapper);
        uint256 g = gasleft();
        _swapBuy(int256(uint256(TOKENS_OUT)), "");
        uint256 cold = g - gasleft();

        vm.prank(swapper);
        g = gasleft();
        _swapBuy(int256(uint256(TOKENS_OUT)), "");
        uint256 warm = g - gasleft();

        assertEq(block.number, blockBefore, "both swaps in one block");
        console2.log("swap exactOut COLD (first in block):", cold);
        console2.log("swap exactOut WARM (same block):", warm);
        assertLt(warm, cold);
    }
}

/// @notice Same measurements against a SEASONED pool (one fill executed in setUp, a
///         separate EVM context, so every balance slot downstream of the hook is
///         already nonzero and access-list warmth is reset). This is routed steady
///         state: a pool's first-ever fill pays one-time zero-to-nonzero storage
///         initialization that no later fill repeats, so the fresh-pool COLD numbers
///         above overstate steady-state cold gas.
contract GasColdWarmSeasonedForkTest is GasColdWarmForkTest {
    function setUp() public override {
        super.setUp();
        vm.prank(swapper);
        _swapBuy(-int256(10e6), "");
    }
}
