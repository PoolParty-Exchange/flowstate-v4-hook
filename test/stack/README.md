# JUP-698 stack harness: the Gen-4 hook on the exact pinned PoolParty_Contracts stack

Gate 1 of the JUP-698 handover (Wilko, 26 Sep 2026): conformance against the real contracts, not mocks.

**Pinned stack:** PoolParty_Contracts `3e899f0486e6050a4a6aa096fc4dd67c61eb4d90` (main after PR #57; it carries PR #54's listings and PR #56's `tokenQueueEnds`). The suite also passes on `de4464fb79e67d09212944f00ee64c9fae772bab`, the PR #54 head it was first pinned to. The market, the pool with its linked libraries, `C1ListingRegistry` and `C1ListingSettlement` are the real contracts, built and deployed by that checkout's own Hardhat config and test fixtures. The hook, Uniswap's `PoolManager` and `PoolSwapTest`, and the test-only `Gen4LiveDeltaRouter` come from this repo's `forge build`.

## Run

```
forge build
git -C <PoolParty_Contracts clone> worktree add --detach <dir> 3e899f0486e6050a4a6aa096fc4dd67c61eb4d90
ln -s <PoolParty_Contracts clone>/node_modules <dir>/node_modules
cd <dir>
HOOK_OUT=<this repo>/out npx hardhat test --config hardhat.test.config.js <this repo>/test/stack/gen4-stack.test.cjs
HOOK_OUT=<this repo>/out npx hardhat test --no-compile --config hardhat.test.config.js <this repo>/test/stack/gas-probe.test.cjs
```

## Test environment, stated

- The hook takes the buyer's input from the PoolManager inside `beforeSwap`, before the router pays it in (gen-3's `ManagerReservesExceeded` rule), so the test PoolManager is given USDC reserves, as the live Robinhood Chain PoolManager holds from its other pools.
- `PoolSwapTest` requires the router's live delta to equal the swap's returned delta, which any hook refund breaks; swaps that may refund go through `Gen4LiveDeltaRouter`, which settles the live delta as v4-periphery's `SETTLE_ALL` / `TAKE_ALL` do.
- The hook is deployed through the canonical CREATE2 deployer at a mined address carrying its permission flags (`0x28cc`).
- Every swap is checked for conservation: the buyer pays exactly both sources' payments plus the hook's spread, jar fee and dust.
- The quote-parity and beacon tests deploy Uniswap's `V4Quoter` (v4-periphery, unmodified) on the stack's PoolManager; `test/stack/StackV4Quoter.sol` only imports it so `forge build` writes its artifact to `out/`.
- The tests under "design E on the stack" (30 Sep 2026, Daniel's launch condition) run both ETH pools of one token against the real contracts: the real `PoolManager`, the hook's real 16 bps spread and 8 bps jar fee, a $20 inventory floor (K = 10 tokens) and a real listing queued behind two deposits. `stack({ ethPools: true })` installs `StackWrappedDollar` (the fixture's USDC plus WETH's `deposit`/`withdraw`, runtime code only, storage asserted unchanged) and deploys the hook with it as `weth9`, so the native-ETH pool and the "aeWETH" pool both sell the one C1 pool, which is the production shape. `Gen4TwoPoolRouter` runs several swaps in one `unlock`, as a splitting aggregator does. Three tests: both pools' quotes fill in one transaction in either order with exact budgets, spread and jar fee; a smaller main slice sells what its own quote sold whichever pool runs first (the Robin pass 65 case: it fails with the main pool's credit disabled); an over-budget aeWETH slice reverts the whole transaction.
- The tests under "ported from the forge fork suite" (29 Sep 2026) carry the Gen-4 versions of the fork suite's retired swap tests: the TokenJar fee (against a jar-free twin stack), quote parity, spread rungs, the PoolManager reserve ceiling, the visibility beacon, hookData, margin custody and sweep, declines on a paused market, a paused pool and a frozen hook, and the reseller code. Where the fixture's flat $2 rate makes them derivable by hand, the expected amounts are pinned.
