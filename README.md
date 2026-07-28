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
  the callback); afterSwap returns 0. hookData is never read. It also carries the
  scope §5 fee determination (base spread + size rungs, both directions), per-asset
  margin accrual, and the owner-settable sweep — see "Phase 1 slice 2" below.
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
forge test --match-path "test/fork/GasColdWarm.t.sol" -vv   # the gas tables below
```

Note on pinning: the public RH RPC prunes historical state, so a `FORK_BLOCK` more
than roughly a day old now fails with `metadata is not found` (the Phase 0 block
21425148 is already gone). Unpinned runs against latest are the reliable default;
pin only for a same-day rerun.

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

## Phase 1 slice 2 (2026-07-29): fee-determination rungs + margin sweep

Implements scope §5 exactly. Inputs to pricing are **pool identity and trade size
only** — no per-caller logic anywhere (§5b is a hard property of the venue, not a
gap), and every config setter is owner-gated and sits outside the swap path.

### The spread

`spreadBps = baseSpread[pair] + sizeAdjustment(quote notional)`

- `baseSpread` is per pair, set at `registerPair` and retunable via `setBaseSpread`.
- `sizeAdjustment` is a per-quote-asset schedule of `(notionalCeiling, extraBps)`
  rungs (`setSizeRungs`). Rungs are keyed per quote asset because the ceiling is in
  raw units and raw notionals are not comparable across decimals.
- Evaluation: the first rung whose ceiling `>=` notional applies; **above the top
  ceiling the top rung applies** (open-ended), so a huge trade never pays fewer bps
  than a mid-size one. An **empty schedule is base-spread-only** — the conservative
  ship default.
- Schedule validation is **reject, not normalize** (documented choice): input must be
  strictly ascending by ceiling with non-decreasing `extraBps`, each `<= 1000` bps;
  anything else raises `RungScheduleInvalid`. Zero ceilings and duplicates are
  rejected by the same rule.
- `baseSpreadFloorBps` (the per-chain oracle-drift floor: 10 BSC / 16 RH / 23 Base)
  is enforced **at config time only**, in `registerPair`/`setBaseSpread`. The hot
  path never re-validates config, and raising the floor deliberately does not
  retro-break registered pairs — the runbook re-sets their spreads.

### Rounding: the hook never undercollects

**exactOutput** is the simple direction: the market returns the exact band-checked
cost, the hook adds `ceil(cost * spreadBps / 10_000)` on top, and the buyer pays
`cost + spread`. No dust is possible.

**exactInput** carves the spread out of the input *before* the market call: the
buyer's `quoteIn` is taken and charged in full, but the market is committed only
`netQuote = floor(quoteIn * 10_000 / (10_000 + spreadBps))` and prices tokens on that
remainder. The floor is what makes the carve safe — it can never hand the market more
than the spread-adjusted share, so `quotePaid + ceil(quotePaid * spreadBps / 10_000)
<= quoteIn` always holds. Spread then accrues on the **recomputed cost the market
actually pulled** (`quotePaid <= netQuote`), never on the raw `quoteIn`.

Everything left over (`quoteIn - quotePaid - spread`: the carve residue plus the
market's own floor/ceil inversion dust) is accounted as **dust, tracked separately
from spread margin** so sweep reconciliation stays clean. Both sit as hook balance
awaiting the same sweep; the `MarginSwept` event carries the split.

Proven in `SpreadRoundingForkTest` (fixed odd sizes, an awkward market rate whose
inversion genuinely loses units, and two fuzz runs over size × bps): spread is always
`>=` the exact bps product and always `<` that product + 1 wei, and
`quotePaid + spread + dust == quoteIn` to the wei.

One boundary: a carve can only strand a ticket of a **single raw unit** (netQuote
rounds to 0 iff `quoteIn * 10_000 < 10_000 + spreadBps`). The hook raises its own
`TradeTooSmallForSpread` there rather than letting the market's `ZeroAmount` surface
for a hook-caused condition — same posture as `ManagerReservesExceeded` — and it
raises identically in the quoter simulation and the real swap.

### Margin accrual and sweep

`accruedSpreadMargin[asset]` and `accruedDust[asset]` accrue per quote asset.
`sweepMargin(asset)` (owner-only, to an owner-settable `sweepDestination`, mirroring
the UniswapX executor's `sweepTokens`/`sweepETH` collection path) transfers the
hook's full balance of that asset, which **is** the accrued total by construction,
plus any force-sent donation, and zeroes both counters. `sweepETH()` recovers
force-sent ETH (none accrues: the hook is all-ERC20 and has no `receive`).

The scope §8 custody invariant is asserted directly
(`test_Invariant_HookHoldsZeroNonMarginBalance`): outside an unlock the hook holds
zero inventory token, zero ETH, and quote-asset balance exactly equal to
`accruedSpreadMargin + accruedDust`.

One subtlety worth knowing when reading `_buyExactOutput`: the market **skips** the
`fundBuy` callback whenever the hook's already-accrued margin covers the cost, and
pulls that margin instead. The hook therefore reads the flash-accounting ledger
(`currencyDelta`) rather than assuming a callback shape, and takes only the
difference. `test_ExactOut_NetsIdentically_WhenFundBuyCallbackIsSkipped` drives one
fill of each shape and proves identical economics — the margin is used as transient
working capital within the unlock and fully restored.

### Tests

73 RH-mainnet-fork tests green (26 from Phase 0 / slice 1, unchanged in behavior, +47
new). New coverage: quoter-vs-execution parity to the wei **with spread applied**
across four spread configurations × both directions × three sizes; rounding proofs;
accrual/sweep/access-control; rung edge cases; the custody invariant; and the gas
table below.

### Gas: what the spread logic costs

Same method as the Phase 0 table (seasoned pool = routed steady state; COLD = first
call in a block). "Spread active" = base 16 bps + a three-rung schedule, with the
accrual slots already seasoned nonzero. Both columns are **re-measured in the same
run** rather than compared against the Phase 0 table above — that table was taken at
fork block 21425148 and absolute numbers drift a few thousand gas with fork state, so
only a same-run comparison isolates the spread logic.

| Path | Seasoned COLD, no spread | Seasoned COLD, spread active | Delta |
|---|---|---|---|
| swap exactIn | 257,291 | 248,040 | **−9,251** |
| swap exactOut | 260,812 | 264,429 | **+3,617** |
| swap exactIn WARM | 166,945 | 148,094 | −18,851 |
| swap exactOut WARM | 170,469 | 161,686 | −8,783 |
| quoter exactIn (gasEstimate) | 187,075 | 177,824 | −9,251 |
| quoter exactOut (gasEstimate) | 190,412 | 194,029 | +3,617 |

Both directions are far inside the scope's 10k flag threshold. exactOut pays a real
`+3.6k` for the rung lookup, the ceil-bps math, the accrual SSTORE, and the one
`currencyDelta` read that makes the callback-skip case safe.

exactIn comes out **cheaper**, which is not a measurement artifact but is worth
naming: once margin sits on the hook its quote-asset balance slot never returns to
zero, so each fill's transfers are nonzero-to-nonzero writes instead of paying the
zero-to-nonzero SSTORE that the no-spread path pays every single swap. The saving is
real in production for as long as margin is accrued — but the **first fill after a
sweep zeroes the balance pays that initialization again**, so sweeping every block
would forfeit it. Sweep on a cadence, not per fill.
