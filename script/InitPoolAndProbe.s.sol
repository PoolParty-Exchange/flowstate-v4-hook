// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Phase 5 step 1: initialize the live V4 pool for a registered hook pair and
/// prove the full path with one dust buy through a freshly deployed
/// PoolSwapTest router. The initialization moment starts the routing
/// observation clock: from here, third-party backends can discover the pool.
///
///   HOOK=0x.. PAIR_TOKEN=0x.. AEWETH=0x.. V4_POOL_MANAGER=0x.. \
///   RATE_RAW=34199380125179 PROBE_AMOUNT=300000000000000 \
///   forge script script/InitPoolAndProbe.s.sol --rpc-url $RH_RPC_URL --broadcast
///
/// RATE_RAW = quote-asset raw units per 1e18 token units (the oracle's rate),
/// used only for the cosmetic slot0 seed; the hook overrides all pricing.
/// PROBE_AMOUNT = quote-asset raw units spent on the proof buy (exact-in).
contract InitPoolAndProbe is Script {
    function run() external {
        address hook = vm.envAddress("HOOK");
        address token = vm.envAddress("PAIR_TOKEN");
        address quote = vm.envAddress("AEWETH");
        IPoolManager manager = IPoolManager(vm.envAddress("V4_POOL_MANAGER"));
        uint256 rateRaw = vm.envUint("RATE_RAW");
        uint256 probeAmount = vm.envUint("PROBE_AMOUNT");

        bool quoteIsC0 = quote < token;
        (Currency c0, Currency c1) =
            quoteIsC0 ? (Currency.wrap(quote), Currency.wrap(token)) : (Currency.wrap(token), Currency.wrap(quote));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hook)});

        // slot0 seed from the rate: price = raw1 per raw0 (fork-fixture formula)
        (uint256 raw0, uint256 raw1) = quoteIsC0 ? (rateRaw, uint256(1e18)) : (uint256(1e18), rateRaw);
        uint256 sqrtPrice = FixedPointMathLib.sqrt((raw1 << 192) / raw0);
        require(sqrtPrice > TickMath.MIN_SQRT_PRICE && sqrtPrice < TickMath.MAX_SQRT_PRICE, "seed out of range");

        vm.startBroadcast();

        manager.initialize(key, uint160(sqrtPrice));
        console2.log("pool initialized; observation clock starts at this tx");

        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        IERC20(quote).approve(address(swapRouter), probeAmount);

        // buy = quote in; zeroForOne only when the quote is currency0
        bool zeroForOne = quoteIsC0;
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(probeAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        vm.stopBroadcast();

        console2.log("probe buy settled through the hook");
        console2.log("delta amount0:", delta.amount0());
        console2.log("delta amount1:", delta.amount1());
        console2.log("swap router (test only, keep for later probes):", address(swapRouter));
    }
}
