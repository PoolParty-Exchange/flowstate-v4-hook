# flowstate-v4-hook

Flowstate C1 as a Uniswap V4 hook on Robinhood Chain (4663), per
`fb-main/docs/V4_HOOK_BUILD_SCOPE_2026-07-27.md` (rev 2, approved). A buy-only
custom-curve hook, proven on an RH mainnet fork against the REAL RH PoolManager, the
canonical V4Quoter, and — as of Phase 1 final — the REAL FlowstateMarket + FlowstatePool.

Standing principle: no protocol capital anywhere; the hook holds no user funds beyond
transient unlock balances and sweepable spread margin.

**Phase status:** Phase 0 complete, Phase 1 complete (slice 1 = the market entry-point
pair, slice 2 = fee rungs + sweep, slice 3 = real-market wiring, this document).

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
  margin accrual, and the owner-settable sweep.
- `src/interfaces/IFlowstateMarketMinimal.sol` — the market surface the hook consumes:
  the scope §2.2 entry-point pair, `buyFromPoolExactQuote` (exact-input in quote terms)
  and `buyFromPoolExactOut` (exact-output twin with the `IFlowstateBuyFunder.fundBuy`
  funding callback). Legacy `buyFromPool` remains declared for reference; the hook's
  swap paths use only the pair.
- `src/interfaces/IFlowstateBuyFunder.sol` — the funding-callback interface the hook
  implements (mirror of the PoolParty_Contracts original).
- `test/real/poolparty/` — **byte-identical vendored copies** of the real Flowstate
  contracts (see "Vendoring" below).
- `test/real/TestSpotOracle.sol` — the only non-production piece of the stack, and only
  because RH's aggregator cannot price a freshly minted test token (see "The oracle").
- `test/fork/RealStackDeployer.sol` — deploys the real stack inside the fork, mirroring
  `deploy/flowstate-testnet.js` step for step, plus the 0.8.26 interfaces the tests
  drive it through.
- `test/fork/` — all tests fork RH mainnet. `ForkTestBase` deploys the real stack, mines
  the 0x28cc address with v4-periphery's HookMiner, deploys via plain CREATE2 from the
  test contract, creates a real C1 pool with holder-funded inventory, and initializes
  the V4 pool against the real PoolManager. It also carries the ArbSys precompile mock
  helper (`mockArbSys()`), which the V4Quoter path does not need (verified).

**`test/mocks/MockFlowstateMarket.sol` is deleted.** There is no second implementation
of the market interface left in this repo, so there is nothing left to drift.

## Vendoring: how the real contracts get into a Foundry test

PoolParty_Contracts is a Hardhat repo. Three options were on the table (vendor the
sources, remap to the sibling repo, or compile artifacts and `vm.etch`). **Chosen:
vendored sources**, because it is the only option where a reviewer can read exactly what
was deployed and `diff` it against the source of truth in one command:

```bash
diff -r test/real/poolparty \
        ../PoolParty_Contracts/contracts   # only "Only in" lines should appear
```

The copies are byte-identical to `PoolParty_Contracts` **origin/main @ `8c5937f`** (4 Sep 2026: the merge of contracts PR #43, JUP-602 + JUP-611 + JUP-612 + JUP-619, carrying #38 + #40 + #41 + #42; this pin moves back to `origin/main` once #43 merges, and the drift gate holds it to whatever commit `.vendored-from` names). Before that it was **origin/main @ `959e867`**
(the merge of PR #8, the exact-quote pair, and PR #9, governance + the 12h emergency
lane). Vendored: `FlowstateMarket`, `FlowstatePool`, `FlowBridgeCollector`,
`FlowAccumulatorBase`, `proxy/InitializableBeaconProxy`, `libraries/{FlowstateStructs,
FlowstateEvents}`, `interface/{IOracle, IFlowstatePool, IFlowstateBuyFunder,
IInitializableBeaconProxy, IUpgradeableBeacon, IFlowAdapters}`. Refreshing them is a
`cp` and a re-run; a signature change on the market side becomes a compile error here.

Two mechanical consequences worth knowing before editing anything:

1. **No `solc` pin in `foundry.toml`.** The hook pins `pragma solidity 0.8.26` exactly —
   that is the version it ships at and the version its mined CREATE2 address derives
   from — and the vendored contracts pin `0.8.29`. Auto-detect puts them in separate
   compilation units.
2. **No Solidity file imports both.** A file requiring `=0.8.26` and `=0.8.29` is an
   unsatisfiable unit. `RealStackDeployer` therefore declares the market/pool surface as
   local 0.8.26 interfaces and instantiates the 0.8.29 contracts through
   `vm.getCode`/`deployCode`. The upshot is the point: **the hook under test is
   byte-identical to the hook that will be deployed** — it was not recompiled at a
   different solc to make the test build.

`@openzeppelin/contracts-upgradeable` was added as a submodule pinned at **v5.0.0**, the
exact version PoolParty_Contracts resolves. `@openzeppelin/contracts` continues to
resolve to v4-core's nested copy (5.0.2) rather than PoolParty's 5.6.1; the delta is
confined to internal gas micro-optimisations in `SafeERC20`/`Clones` (tens of gas on a
~372k path) and no behaviour we depend on. Flagged rather than hidden.

## The oracle: what is real and what is not

Everything in the stack is the production contract except the price oracle, and the
suite measures BOTH ways because the difference is the whole gas story:

- **`TestSpotOracle` (default fixture).** One SLOAD per read, rate settable. Needed
  because RH's aggregator cannot price a freshly minted test inventory token, and
  because the rounding suite has to drive the real market at chosen rates. Numbers taken
  against it are **market + pool + hook with the oracle term set to ~0**.
- **RH's live aggregator** (`0x000000000149d2C5F921960977e8a2b6F8b972c7`, the address the
  RH Flowstate deployment is wired to). `LiveOracleGas.t.sol` stands up the entire stack
  against it and lists a REAL pair it can price — aeWETH inventory quoted in USDG — so
  the PoolManager, the V4Quoter, the market, the pool, the oracle and both ERC20 legs
  are all the real thing. These are the true end-to-end numbers.

## Running

Foundry 1.7.1 (`~/.foundry/bin`). The `robinhood` RPC endpoint is set in
`foundry.toml` (public RPC `https://rpc.mainnet.chain.robinhood.com`); tests fork it
in `setUp` via `vm.createSelectFork`.

```bash
forge test                     # full suite (109 tests), forks latest RH block
FORK_BLOCK=21411475 forge test # pin the fork block (faster reruns, deterministic)
forge test --match-path "test/fork/GasColdWarm.t.sol"  -vv  # stub-oracle gas table
forge test --match-path "test/fork/LiveOracleGas.t.sol" -vv # LIVE-oracle gas table
forge test --match-path "test/fork/RealStackWiring.t.sol"   # real-market behaviours
```

Submodules matter now (`--recursive`, or `git submodule update --init --recursive`):
the build needs `lib/openzeppelin-contracts-upgradeable` alongside v4-core/v4-periphery.

Note on pinning: the public RH RPC prunes historical state, so a `FORK_BLOCK` more
than roughly a day old now fails with `metadata is not found` (the Phase 0 block
21425148 is already gone). Unpinned runs against latest are the reliable default;
pin only for a same-day rerun.

`forge test --fork-url https://rpc.mainnet.chain.robinhood.com` also works; the
in-test `createSelectFork` selects the same endpoint either way.

## Dependencies (pinned, recorded per scope)

| lib | ref | commit |
|---|---|---|
| uniswap/v4-core | main | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` |
| uniswap/v4-periphery | main | `3245c3cb99c48fa1dc2459c3b60abc37d4294aba` |
| foundry-rs/forge-std | master | `f355ba17303d62d9bf5dcc9d970670c1e1aba5ca` |
| OpenZeppelin/openzeppelin-contracts-upgradeable | v5.0.0 | `625fb3c2b2696f1747ba2e72d1e1113066e6c177` |
| PoolParty_Contracts (vendored sources, not a submodule) | origin/main | `959e867` |

All `@uniswap/v4-core` remappings point at the top-level `lib/v4-core` (single copy;
v4-periphery's nested pin differs from main only by CI commits). `via_ir = true` is
required: the beforeSwap callback is stack-too-deep under legacy codegen. No `solc`
pin — see "Vendoring" above.

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

### Gas: cold vs warm (Phase 0, MOCK market — SUPERSEDED, kept as the baseline the Phase 1 delta is measured against)

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

> The gas table at the end of this section was taken against the MOCK market and is
> superseded by "Phase 1 final" below. The spread/rounding semantics it documents are
> unchanged and were re-verified against the real market.

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

73 RH-mainnet-fork tests green at the time of slice 2 (26 from Phase 0 / slice 1,
unchanged in behavior, +47 new); 109 after slice 3. Coverage added by slice 2:
quoter-vs-execution parity to the wei **with spread applied** across four spread
configurations × both directions × three sizes; rounding proofs; accrual, sweep and
access control; rung edge cases; the custody invariant; and the gas table below.

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


---

# Phase 1 final (2026-07-29): wired to the REAL FlowstateMarket

The mock is deleted. Every fork test now runs the hook against a fresh deployment of the
real pass-1 stack — `FlowstateMarket` behind a UUPS proxy, `FlowstatePool` behind the
beacon, `InitializableBeaconProxy` clones, `FlowBridgeCollector` as the spoke-chain fee
receiver, three `TimelockController`s — built inside the fork in the exact order of
`deploy/flowstate-testnet.js`, including the eight-argument `initialize` (PR #9 added
`emergencyTimelock12`) and **beacon ownership transferred to the market proxy**, which
`test_Governance_BeaconOwnedByMarket_SoPoolUpgradeActuallyWorks` proves end to end
rather than asserting from the deploy script's own sanity probe.

The RH dust deployment (market proxy `0x09427C08…20ec`) is deliberately NOT reused: it
predates PR #8/#9 and has neither entry point.

**109 tests green. The hook contract needed no behavioural change of any kind** — no new
code path, no changed arithmetic, no changed revert. The only edit to `src/` was one
stale comment naming the mock's `ZeroAmount` where the real pool raises `InvalidAmount`.
The scope's claim that the adapter is interface-complete against the real market holds.

## Gas: the headline

Method as before (seasoned pool = routed steady state; COLD = first call in a block),
plus one new discipline the mock did not require: **setUp and every seasoning step end
with `_expireRateCache()`**, because `FlowstatePool` caches its rate for the whole
timestamp. Without that, every "cold" number would silently be a cache hit.

### A. Real market + pool + hook, oracle term ≈ 0 (`TestSpotOracle`)

| Path | Fresh COLD | Seasoned COLD | WARM (cached) |
|---|---|---|---|
| swap exactIn | 440,192 | **371,792** | 200,005 |
| swap exactOut | 444,367 | **375,967** | 204,183 |
| quoter exactIn (gasEstimate) | 352,876 | 301,576 | 299,076 |
| quoter exactOut (gasEstimate) | 356,867 | 305,567 | 303,067 |

With spread active (base 16 bps + three rungs), seasoned COLD: exactIn 362,541,
exactOut 379,584; WARM 181,154 / 195,400. The slice-2 conclusion survives: the spread
logic is free-to-cheap, and exactIn is slightly cheaper once margin keeps the hook's
balance slot nonzero.

### B. Real everything, including RH's LIVE oracle (`LiveOracleGas.t.sol`)

Real PoolManager, real V4Quoter, real market, real pool, real oracle, real ERC20s
(aeWETH inventory quoted in USDG). This is the number that matters.

| Path | Fresh COLD | Seasoned COLD | WARM (cached) |
|---|---|---|---|
| swap exactIn | 900,652 | **832,252** | 190,216 |
| swap exactOut | 904,818 | **836,418** | 194,394 |
| quoter exactIn (gasEstimate) | 809,399 | 758,099 | 755,599 |
| quoter exactOut (gasEstimate) | 810,890 | 759,590 | — |

**The oracle, measured in isolation on the same fork: COLD 474,131 gas, WARM 196,613.**
Cross-checked by subtraction: 832,252 − 371,792 = 460,460.

### What that means against scope §6

| Reference | Value | Where we land |
|---|---|---|
| routed hooked p50 (RH, measured) | 263k | warm/cached fills (190k) beat it |
| target to sit inside routed p90 | ≤450k | **missed cold: 832k** |
| demonstrated per-hook routed ceiling | 715k | **exceeded cold: 832k** |
| routed 2-leg oracle-hook routes | 759k | exceeded cold |
| quoter gasEstimate seen routed (Doppler) | 818k | our 809k sits just under |
| outlier routed swaps | 1.45M / 1.9M | comfortably below |
| scope's planning projection, naive oracle | 950k–1.1M | **beaten: 832k** |

Stated plainly, because it is a real finding and not a failure: **with a naive
1inch-style oracle the cold path lands at ~832k, above the 715k demonstrated envelope.**
Two things soften it and one sharpens it.

- Softening 1: the measured oracle is 474k, not the 700k the scope planned with, so the
  total beats the scope's own projection by ~120–270k.
- Softening 2: the cached path is **190k**, and on RH the cache spans a whole SECOND —
  roughly ten blocks at ~10 blocks/s (`test_SameTimestampCache_SpansMultipleBlocks`).
  Any pool trading more than once a second pays the cold price once per second, not per
  swap, so a busy pool's realised p50 sits far closer to 190k than to 832k.
- Sharpening: **Phase 3's slim oracle is now on the critical path, and its budget needs
  tightening.** The non-oracle path is 372k, so the scope's slim-oracle target of
  150–300k yields 522–672k — inside the 715k envelope but still over the 450k target. To
  reach ≤450k the oracle has to come in under ~80k, which a genuinely minimal
  one-or-two-venue reader (a V3 `slot0`, a V4 `StateView` read) plausibly can. Phase 3
  should be scoped to that number, not to 300k.

## Differences from the mock

Every behavioural difference found between `MockFlowstateMarket` and the real
`FlowstateMarket`/`FlowstatePool`. **None of them required a hook change**, but several
are load-bearing for how the venue behaves in production.

| # | Area | Mock | Real | Consequence |
|---|---|---|---|---|
| 1 | Protocol fee | none at all | `DEFAULT_FEE_BPS` = 100 (1%) carved from the SELLER leg inside `settleBuy` | Buyer quotes are byte-identical at any fee tier (`test_Fee_IsSellerSide_SoTheBuyerQuoteNeverMoves`), confirming scope §5's premise that routed buyers get raw oracle cost and the hook spread is the only buyer-side charge. But the buyer's payment now splits: pool keeps `quotePaid − fee`, the buyback receiver takes the fee. Conservation tests assert over the pair. |
| 2 | Fee routing | n/a | one extra ERC20 `transfer` per fill (all of it to buyback with an unregistered reseller code, by the pool's remainder rule) | part of the +123k the real market adds |
| 3 | Rounding | `floor(quoteIn*num/den)` then `ceil(tok*den/num)` — could lose a raw unit at any rate | `floor(quoteIn*1e18/rate)` then `ceil(tok*rate/1e18)` | **The most interesting difference.** The floor discards at most `rate` from the numerator, so the ceil recovers the input EXACTLY whenever `rate ≤ 1e18`. Market-side inversion dust is therefore identically zero on every USDG-quoted pool. It is only reachable when `rate > 1e18`, i.e. when one raw inventory-token unit is worth more than one raw quote unit — the low-decimal-token / 18-decimal-quote shape, which is precisely the **aeWETH-quoted long-tail pools** in the v1 quote-asset set. The hook's separate dust counter is not dead code; it is the aeWETH case. Both regimes are proven (`test_MarketInversionIsExact_…`, `test_MarketInversionLosesUnits_…`). |
| 4 | Anchor band | none — the mock priced any rate | `anchorBandBps` (default 1000) × widen (1 + elapsed/60, cap 4), checked against a stored anchor | An out-of-band oracle move declines in the V4Quoter simulation and the swap **identically** (`RateOutOfBand`), which is the failure shape scope §8 calls acceptable. The admin `resetAnchor` is the escape hatch and restores service. An in-band move is served and advances the anchor. |
| 5 | Same-timestamp cache | none — the mock re-read its constant every call, so the Phase 0 "warm" column measured storage warmth only | second and later trades in one timestamp skip the oracle entirely | Proven the only way that admits no doubt: break the oracle between two trades in the same second; the second still fills. This is the scope §6 "free" mitigation lever, and it is worth **642k** on the live-oracle path. On RH it spans ~10 blocks, not one. |
| 6 | Decimals | implicit in the num/den pair | implicit in `rate`, scaled by `RATE_SCALE = 1e18`; no decimals are read anywhere | No difference in kind. It does mean the decimals pairing decides whether `rate` sits above or below `1e18`, which is what row 3 turns on. |
| 7 | Fill capacity | capped by the mock's own token balance | capped by the FIFO walk, **`MAX_FILL_NODES = 50`** | A pool whose inventory is spread over more than 50 contributors cannot fill past the first 50 nodes even though `tokenBalance` says otherwise. No mock analogue existed. Proven with 51 contributors. |
| 8 | Shortfall semantics | `FillShortfall` when the ask exceeded its balance | `FillShortfall` (same selector, no args) from `FlowstatePool` on the exact-quote pair; `NoLiquidity` when the pool is empty; legacy `buyFromPool` still partial-fills | Selector-identical for shortfall, so the existing assertions carried over untouched. Empty is a **different** error (`NoLiquidity`, not `FillShortfall`) — a real revert-shape change. |
| 9 | Sub-dust ticket | mock raised `ZeroAmount` | pool raises `InvalidAmount` | Invisible in practice: the hook pre-empts it with its own `TradeTooSmallForSpread`. One stale comment in `src/` was corrected. |
| 10 | Pause | none | market `whenNotPaused` (`EnforcedPause`) and per-pool `poolPaused` (`PoolIsPaused`) | Both decline identically in quoter and swap. |
| 11 | Freeze | none | `freezeEnabled` + `frozen[msg.sender] \|\| frozen[buyer]`, both of which are the hook | **`test_FreezingTheHookAddressKillsTheVenue`** turns scope §3's governance runbook rule into a checked fact: freezing an ordinary swapper is invisible (the hook is always the buyer), freezing the hook takes the whole venue offline. NEVER FREEZE THE HOOK ADDRESS. |
| 12 | Oracle failure | impossible | `NoOracleRate` on a zero/oversized rate; a reverting oracle propagates | Declines identically in quoter and swap. |
| 13 | Unknown pool | mock was its own pool record | `UnknownPool` from the market's registry | Declines identically in both paths. |
| 14 | Where funds sit | mock held inventory and proceeds itself | inventory and proceeds live in `FlowstatePool`, with a per-contributor FIFO claim ledger | `test_ContributorCanClaimProceedsOfARoutedV4Buy` proves a routed V4 buy leaves the contributor a genuinely claimable position — the off-hook exit path of scope §4. |
| 15 | Reentrancy | none | market-wide `nonReentrant`, and `fundBuy` runs inside it | The hook's `fundBuy` → `manager.take` path is unaffected; the callback-skip case (margin covers the cost) behaves identically, as slice 2 already proved and slice 3 re-proved against the real skip rule. |
| 16 | Gas | seasoned COLD ≈249k exactIn | 372k with a trivial oracle, **832k with the live one** | See above. |

**No surprises in the places that would have hurt.** Take/settle conservation, the
`ManagerReservesExceeded` ceiling, quoter-vs-execution parity to the wei in both
directions from an arbitrary sender and from `address(0)` with empty hookData,
sell-direction typed-revert parity, spread accrual, and the sweep all behave exactly as
they did against the mock. Rows 3, 5, 7 and 11 are the four worth carrying forward into
Phase 2 and the ops runbook.

## What this changes for the remaining phases

- **Phase 2 (test suite).** Cheaper than scoped. The quote==execution prover, the
  cold/warm cache cases, the band edge, empty inventory, paused and the sell-revert
  parity all landed here as a by-product of proving the real wiring, so Phase 2 shrinks
  to hookData fuzzing at scale, multi-pool/multi-quote-asset cases, and an invariant
  pass. Call it 2 days rather than 3–4.
- **Phase 3 (slim RH oracle).** Now the critical path and the single biggest lever in
  the build: it is worth 460k per cold swap, and it is what decides whether the hook
  sits inside the routed envelope. Retarget it from "≤300k" to "≤80k", which reframes it
  as a one-or-two-venue depth-weighted reader rather than a pruned 1inch fork. The
  timebox (5 days, escalate past 8) still looks right.
- **Phase 5 (dust deploy).** Add one measurement: whether backends re-quote often enough
  that the same-second cache is doing real work on our pool. If a live pool's realised
  gas p50 sits near 190k rather than 832k, the gas concern largely dissolves and the
  slim oracle becomes an optimisation rather than a gate.
