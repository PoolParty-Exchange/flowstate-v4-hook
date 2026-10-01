// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

// Compiles Uniswap's V4Quoter (v4-periphery, unmodified) into out/ so the stack harness
// (gen4-stack.test.cjs) can deploy it against its own PoolManager for the quote-parity test.
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
