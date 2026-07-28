# flowstate-v4-hook

Flowstate C1 as a Uniswap V4 hook on Robinhood Chain (4663). Phase 0 spike per
`fb-main/docs/V4_HOOK_BUILD_SCOPE_2026-07-27.md` (rev 2, approved): a buy-only
custom-curve hook skeleton proven against the REAL RH PoolManager on a mainnet fork,
with V4Quoter quote==execution parity, sell-direction typed-revert parity, a
take/settle round trip on real USDG, and the largest-safe-ticket measurement.

Standing principle: no protocol capital anywhere; the hook holds no user funds beyond
transient unlock balances.

## Layout

- `src/FlowstateC1Hook.sol` — the hook. Flags 0x28cc (BEFORE_INITIALIZE,
  BEFORE_ADD_LIQUIDITY, BEFORE_SWAP, AFTER_SWAP, BEFORE_SWAP_RETURNS_DELTA,
  AFTER_SWAP_RETURNS_DELTA). beforeInitialize gates pool creation on an admin pair
  registry; beforeAddLiquidity always reverts (`LiquidityNotAllowed`); beforeSwap
  implements the full curve override (specifiedDelta = -amountSpecified), prices buys
  through the pull-exact market interface (exactInput via `buyFromPoolExactQuote`,
  exactOutput via `buyFromPoolExactOut` + the `fundBuy` funding callback — each a
  single market call with a single oracle read), reverts the sell direction with
  `SellDirectionNotSupported`, and raises `ManagerReservesExceeded` when a ticket
  exceeds the PoolManager's physical reserves (scope §2.1 decision, preserved inside
  the callback); afterSwap returns 0. hookData is never read.
- `src/interfaces/IFlowstateMarketMinimal.sol` — the market surface the hook consumes,
  now the FINAL Phase 1 signatures of the scope §2.2 entry-point pair (landed on
  PoolParty_Contracts branch `feat/market-exact-quote-pair`): `buyFromPoolExactQuote`
  (exact-input in quote terms, single oracle read, `quotePaid <= quoteIn` with
  inversion dust accruing on the hook) and `buyFromPoolExactOut` (exact-output twin
  with the `IFlowstateBuyFunder.fundBuy` funding callback resolving the Phase 0
  funding-order finding — the hook does `manager.take` inside the callback, then the
  market pulls exactly the cost). Legacy `buyFromPool` remains declared for reference;
  the hook's swap paths use only the pair.
- `src/interfaces/IFlowstateBuyFunder.sol` — the funding-callback interface the hook
  implements (mirror of the PoolParty_Contracts original).
- `test/mocks/MockFlowstateMarket.sol` — stand-in implementing the identical Phase 1
  interface: fixed rate (2 FLOWMOCK per 1 USDG), pull-exact, all-or-nothing
  (`FillShortfall`), real callback skip rules (only a code-bearing caller whose
  balance/allowance falls short gets `fundBuy`), holds its own inventory.
- `test/fork/` — all tests fork RH mainnet. `ForkTestBase` mines the 0x28cc address
  with v4-periphery's HookMiner and deploys via plain CREATE2 from the test contract
  (`new FlowstateC1Hook{salt: salt}(...)`) — no vm.etch fallback was needed. It also
  carries the ArbSys precompile mock helper (`mockArbSys()`, runtime code
  `0x4360005260206000f3`) which the V4Quoter path does not need (verified).

## Running

Foundry 1.7.1 (`~/.foundry/bin`). The `robinhood` RPC endpoint is set in
`foundry.toml` (public RPC `https://rpc.mainnet.chain.robinhood.com`); tests fork it
in `setUp` via `vm.createSelectFork`.

```bash
forge test -vv                 # full suite, forks latest RH block
FORK_BLOCK=21411475 forge test # pin the fork block (faster reruns, deterministic)
forge test --gas-report --match-test "test_BuySwap|test_TakeSettleRoundTrip"
```

`forge test --fork-url https://rpc.mainnet.chain.robinhood.com` also works; the
in-test `createSelectFork` selects the same endpoint either way.

## Dependencies (pinned, recorded per scope)

| lib | branch | commit |
|---|---|---|
| uniswap/v4-core | main | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` |
| uniswap/v4-periphery | main | `3245c3cb99c48fa1dc2459c3b60abc37d4294aba` |
| foundry-rs/forge-std | master | `f355ba17303d62d9bf5dcc9d970670c1e1aba5ca` |

All `@uniswap/v4-core` remappings point at the top-level `lib/v4-core` (single copy;
v4-periphery's nested pin differs from main only by CI commits). `via_ir = true` is
required: the beforeSwap callback is stack-too-deep under legacy codegen.

## Phase 0 measurements (2026-07-28, fork block 21425148)

PoolManager physical reserves = the `manager.take()` ceiling per quote asset — the
largest single ticket the hook can serve:

| Asset | Raw | Approx USD (ETH ≈ $1,950, USDG = $1) |
|---|---|---|
| USDG (6d) | 7,156,283.764057 | ≈ $7.16M |
| aeWETH (18d) | 1,034.442357801970688830 | ≈ $2.02M |
| native ETH | 2,110.079987415236055341 | ≈ $4.11M (phase 2: native pools) |

Stability over the trailing ~42h (blocks 19925148 → 21425148, ≈10 blocks/s):
USDG 8.51M → 7.16M (gradual −16% drift), aeWETH 1,145 → 1,034, native ETH
1,889–2,267. No cliff behavior; ceilings sit comfortably above any plausible ticket.

The ceiling is exact and the failure is clean: a buy of the manager's entire USDG
balance executes; one wei more raises `ManagerReservesExceeded`
(`test_LargestSafeTicket_FullUsdgReserveExecutes_OneWeiMoreReverts`).

### Gas: cold vs warm (mock market; `GasColdWarm.t.sol`)

"Fresh" = the pool's first-ever fill (pays one-time zero-to-nonzero storage init).
"Seasoned" = pool has traded before (routed steady state; seasoning done in a
separate EVM context so access-list warmth is reset). COLD = first call in a block;
WARM = second and later calls in the same block. Swap gas measured around
`PoolSwapTest.swap` (add ≈21k intrinsic + calldata for a full tx).

| Path | Fresh COLD | Seasoned COLD | WARM (same block) |
|---|---|---|---|
| swap exactIn | 283,052 | 248,852 | 164,506 |
| swap exactOut | 284,060 | 249,860 | 165,517 |
| quoter exactIn (gasEstimate) | 195,736 | 178,636 | 176,136 |
| quoter exactOut (gasEstimate) | 196,560 | 179,460 | 176,960 |

A quote issued in the same block after a fill returns gasEstimate ≈123-124k (slots
warm and nonzero; seen in the parity test logs). Seasoned cold swap ≈249k ≈270k as a
full tx — right at the measured GMGN hooked p50 (263-270k) BEFORE the real oracle
read is added; the warm same-block swap saves ≈84k. Decomposition of the exactIn buy
(trace): hook beforeSwap frame 153.9k, of which the market hop is 71.2k and the two
USDG proxy transfers dominate the rest; pure hook plumbing (callbacks, take/settle
orchestration, registry read, delta math) ≈60-83k including the physical output-token
settle — inside the scope's 60-90k assumption.
