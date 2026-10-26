# Review note for Wilko: PR 61, PR 62, PR 20 (25 Oct 2026)

Three pull requests, reviewed in this order because each builds on the one before. Nothing is deployed, signed or sent. Cecuro's audit follows the deploy and the production testing; Hashlock's longer review runs alongside. Your review and GO gate the sends, as before.

| Order | Pull request | Repository | What it is | Base |
|---|---|---|---|---|
| 1 | [PoolParty_Contracts PR 61](https://github.com/PoolParty-Exchange/PoolParty_Contracts/pull/61) | contracts | JUP-771: a qualified venue opens the passive lane by itself; discovery runs at createPool and at deposit | main (d435d91, holds JUP-770) |
| 2 | [PoolParty_Contracts PR 62](https://github.com/PoolParty-Exchange/PoolParty_Contracts/pull/62) | contracts | JUP-772 listings: the settlement band-checks a quote paid in a non-venue asset against the pool's converted reference | feat/jup-771 (stacked on PR 61) |
| 3 | [flowstate-v4-hook PR 20](https://github.com/PoolParty-Exchange/flowstate-v4-hook/pull/20) | hook | Gen-6: the Uniswap side of a new token needs no operator | main (bda7fff, Gen-5) |

Companion documents (workspace, deployment-ledger): `JUP771_IMPACT_2026-10-24.md`, `GEN6_IMPACT_2026-10-24.md` (the switch list with every number, Robin's two passes in 4a and 4b, the fork end-to-end in 4c, the constants probe in section 7), `router_wrap_measurement_2026-10-23.md` (why one ETH door), `gen6_redeploy_2026-10-24/` (package scripts, GO skeleton, fork records).

## 1. PR 61, JUP-771 (Hamish's ruling of 24 Oct: a qualified venue must open all lanes; discovery must run at createPool and deposit)

**What it switches on**
- `FlowstatePool.passiveOpen()` = not force-closed and no instant-reset notice running. The timelock's decision flag drops out of the opening. A pool without a venue answers NoReference, not LaneClosed, because the price rule already sells only through a qualified venue.
- `closePassiveLane` is now a force-close (one byte at slot 0 offset 31, the last spare byte; every live pool reads false). `openPassiveLane` clears it and still records the flag.
- The instant anchor-reset rule follows the real open state: `FlowstateRegistrar.instantResetRefused(pool)` = flag or cash side on or (venue reads QUALIFIED now and not force-closed). The market's `resetAnchor` calls it. A reset made while unqualified keeps the lane shut through the 48-hour notice even after the venue qualifies (tested, your 18 Sep deferral case).
- `FlowstateRegistrar.tryDiscover(pool)` runs at createPool after the hook pairs and at every deposit into a pool with no live venue. Best effort, never reverts a deposit. Discovery stays OFF until the timelock turns it on; that call is not in this PR and needs a runbook line (see section 5).

**What does not change for the four live pools**: all carry the decision flag, three are admin-paused, V4 reads the brake; day one is identical.

**Why it is safe now and was not in September**: build A priced passive buys off the anchor, which an admin could reset; the gate kept a reset from becoming a sale price. Under Rev 4 the sale price comes from the venue's ring, never the anchor.

**Evidence**: 799 passing on a clean compile; `lane.gate.test.js` rewritten as the rule (16 cases); `discovery.auto.test.js` (5); ten `771:` mutation entries all bite; the split differentials carry a documented allowance (venueless NoReference where the baseline refused LaneClosed; the force-close byte and the laneState word masked); Robin (Sol) found one real gap, fixed: discovery now checks the candidate's token pair, so a misconfigured factory cannot revert a deposit. Sizes: market 23,431 (gate 23,576), pool 23,910 (gate 24,026).

**For you to confirm**: Review A delta on the lane gate and the reset rule (audit items A8 and the 18 Sep fix); the Hashlock scope note needs this listed; the upgrade-ordering line from Robin's K9 (force-close or pause any pool that must stay closed before the beacon moves; today none is in that state).

## 2. PR 62, the Gen-6 listing settlement (JUP-770 deviation A, closed)

**What it switches on**: `C1ListingSettlement._checkBand` converts the reference for a signed listing quote paid in an approved asset other than the venue's: `pool.conversionFor(asset)` must answer ok, then `ref = mulDiv(ref, factor, 1e18, Ceil)` with a rate at or above 2^128 converting to nothing, restating `FlowstatePoolPriceRule._convert`. Refused NoReference exactly where the pool's own signed lane refuses. Gen-5's settlement refused every such quote. The venue's own asset keeps the untouched path. `IListingPool` gains `conversionFor`.

**Why in this release**: the live settlement and registry are immutable and the Gen-6 hook binds to a settlement, so the jup-771 manifest's redeploy of both listing contracts is the moment; the registry has zero listings and zero events.

**Evidence**: `listings.holds.test.js`, new case: on a pool whose venue quotes WETH with USDC the dollar asset and a WETH/USDC reference registered, the converted floor is the market's own (one unit below refused by the settlement and by `settleSigned`; at the floor both settle in USDC; reference removed, both refuse NoReference). Robin: consistent with the pool code; the "exactly" claim rests on the pool's `_convert` and `signedReference`, which I read; tier 2's two reference kinds follow the same two lines and are not separately pinned by a test. If you want that pinned, say so and I add the case.

## 3. PR 20, Gen-6 hook (JUP-772)

**The gap it closes**: until Gen-6 a new token's FlowState pool was permissionless but its Uniswap side was not. The market auto-registered hook pairs for ERC-20 quotes only (Gen-5 refused a native pair from the market), nothing initialised the v4 pool keys (every live init was a deployer send, 6 Aug to 22 Oct), and the beacon was a separate call. No token has ever traded through the hook without one of us initialising it.

**What it switches on, in the order the code runs**
1. One ETH door per token. The market's aeWETH registration opens the token's NATIVE pair (settling in the wrapper); no aeWETH-keyed pool is created. Measured: Uniswap's router and Kyber's aggregator wrap and unwrap aeWETH for the buyer at the edges; on chain over 20,000 blocks every router that reaches v4 pools here does (0x in 50 of its 68 v4-swap transactions, Relay 206 of 466, GMGN 126 of 151). One createPool gives a token two doors, native ETH and USDG, both free.
2. Registration initialises the v4 pool through the new `FlowstatePoolOpener` (the hook's ninth constructor argument, immutable; the constructor refuses an opener not bound to this hook, this PoolManager and this wrapper). Seed price = the C1 pool's anchor for the market asset, 1:1 if unseeded; cosmetic, the hook prices every swap. The hook's `beforeInitialize` still gates. Best effort inside try/catch; a refusal leaves the pool to the permissionless `opener.open`.
3. A pool's first fill lights its beacon out of the hook's own spread after the jar: the opener places the one-unit position on the quote side, pulls exactly what the PoolManager charges (one wei at the measured prices), unwraps it for a native pool, settles. Only attempted with 300k plus the reserve left, capped at 300k, caught; never blocks a fill. `BuyExecuted.spreadAccrued` is net of it.
4. Design E is deleted (the two-ETH-door share: 80/20 default, `setNativeShare`, `nativeShareBps`, the transient ledger, `_pairOpened`). Every door is free. With one ETH pool per token a router cannot split one ETH buy across two ETH doors, which is the case Design E managed. The residual accepted on 23 Oct for USDG stays: a route promising the same stock through doors of different currencies reverts as a whole, nothing moves. **This retires Daniel's 30 Sep launch condition (both ETH pools' quotes fill in one transaction). I need you to see that retired explicitly.**
5. The five gas floors retuned (Hamish, 24 Oct, from a fork probe): attempt 250k to 120k, pool leg base 200k to 120k, finalisation reserve 100k to 60k, leg return 30k to 20k, listing leg floor 500k to 400k. Reason: Gen-6 fills are about 100k cheaper with the gates unchanged, so the limit-to-used ratio rose to 1.32 to 1.40 against Uniswap's 1.30; six sets measured on the fork, this one reads 1.09 / 1.06 / 1.07 / 1.13 / 1.24 across native in, native out, USDG in, an aeWETH payer unwrapped by the router, and a deposits-plus-listing fill. Same safety framing as the Gen-5 floors: courtesy stops, all or nothing holds; the reserve is 1.5 times the measured 40k finalisation; the 400k listing floor sits inside the measured 335k to 542k listing-leg range, so the largest listing legs can start under-gassed and revert cleanly.
6. Six never-called IHooks stubs removed for size. The PoolManager calls a callback only when its flag bit is set; bits unchanged (0x28cc). A direct call to those selectors now reverts with no data instead of `HookNotImplemented`.
7. ABI members removed with Design E: `nativeShareBps`, `setNativeShare`, event `NativeShareSet`, `DEFAULT_NATIVE_SHARE_BPS`, error `InvalidShare`. No consumer in the indexer, APIs or services (searched).

**What is deliberately unchanged**: `_buyGen4ExactInput` and `_buyGen4ExactOutput` (`_plan` keeps only its free-door branch, the pre-Design-E behaviour), the 8 bps jar, spread floors and rungs, `beforeInitialize`'s gate, `beforeAddLiquidity`'s one-add rule, the market's `IFlowstateC1Hook` signature. JUP-768 (one evaluation per fill) is not in this build: it needs a market upgrade and the market has 145 bytes of room.

**Sizes**: Gen-5 24,040 bytes; Gen-6 21,133 (3,443 under EIP-170). Opener 5,639.

**Evidence**
- Offline 56 of 56 (the 35 Design E tests went with the code; new: beacon on the first fill against a real PoolManager with the manager up exactly the dust and books equal to holdings, zero-spread fill stays unlit and whole, native pool paid by unwrapping the wrapper spread with nothing left behind, constructor refuses an opener bound elsewhere, the market's wrapper registration opens the native pair only and never over an owner-tuned native pair, one door sells every deposit then all-or-nothing).
- Robinhood fork suites, all fourteen files green; `RegisterFromMarket` 17 including createPool through the real market registering USDG and native pairs and initialising two pools in 1,017,551 gas with no operator call.
- Stack conformance on the pinned contracts: 25 passing, 1 pending; the assertions adapted, not loosened: `paid = sources + spread + jar + dust + beacon` with the beacon measured as the PoolManager's balance change.
- End-to-end on a fork of the live chain (block 96,649,360, jup-771 applied through the timelock first): 36 of 36 checks. Gen-6 listings, opener, hook at its mined address, the Safe's eight registrations initialising eight pools with no init sends, the switch, Gen-5 retired, buys through the live Universal Router (first fills lighting beacons, second fills at 1.120 / 1.066 / 1.169), the 120 percent USDG plus ETH split refused at estimation and reverted whole with nothing moved, the in-stock split filling both doors, createPool(ROBINCAT) opening both doors by itself. Records in `gen6_redeploy_2026-10-24/fork_e2e/run1` and `run2`; scripts `test/stack/gen6-fork-e2e.cjs` and `gen6-ratio-probe.cjs` on the branch; `deploy/gen6_apply_771_fork.js` in the contracts worktree applies the manifest to a fork because the build-A rehearsal's premise (the frozen 3485d51 baseline) no longer holds live.
- Robin, two passes (Sol): the opener wiring check was added after the first; the second verified the simplified planning equals the old free-door path exactly. Residuals recorded in the impact list 4a and 4b: a failed beacon attempt can cost up to 300k of a first fill's gas (hence the gate); initialisation at registration is best-effort and a refusal shows as slot0 zero; the unlimited opener allowance is the same pattern as the market and settlement allowances, behind the wiring check; one ETH door is a market-path property, the owner path can still register an aeWETH pair, so the package registers native and USDG only and the live verifier flags any aeWETH-keyed pair.

**What to attack first, in my view**: the opener's trust boundary (hook-only `lightBeacon`, exact pull verified against the BalanceDelta, the reciprocal wiring check); the beacon inside `beforeSwap` against v4's accounting (the opener's delta nets to zero within the call; the hook already synced inside `beforeSwap` in Gen-5); `_plan` against the Gen-5 free-door path; and whether 400k on the listing floor is where you want it.

## 4. Release shape (the package is scripted, not built)

1. Contracts first: PR 61 and 62 deploy through your toolkit (the jup-771 manifest already redeploys both listing contracts). The Gen-6 identity is mined only after that, because the hook binds to the new settlement.
2. Opener by plain CREATE from the deployer at a predicted nonce, then the hook through the CREATE2 factory; the hook's constructor refuses a mis-wired opener, so a nonce slip fails loudly.
3. Safe A: eight `registerPair` (native ETH and USDG for CASHCAT, HOODRAT, TENDIES, V4; Hamish's decision, revised the same day from twelve to one ETH door) plus `setResellerCode`. Each registration initialises its pool: no deployer init sends. Safe B: schedule and execute `setTrustedHook`. Safe C: retire Gen-5's eight pairs.
4. Canaries measured on the first fill (beacon) and the second; the Hooklist bar is 1.30.
5. Scripts in `gen6_redeploy_2026-10-24/scripts/` are adapted and shape-tested live in scratch; `fork_rehearsal.js` with the exact Safe envelopes is written once the identity exists.

## 5. Loose ends that need a line in a runbook

- Discovery switch-on (`setDiscovery(true)`, timelock) belongs in the JUP-771 deploy runbook; without it part D of JUP-771 does nothing and new tokens still need `registerVenue` from the Safe.
- The aeWETH dollar reference (`setQuoteReference(aeWETH, 0x69BfaF19)`, Safe) is still a JUP-770 activation call; aeWETH-venue candidates rank at zero in discovery until it is set.
- Hooklist re-approval for the new address (Angela) and 0x's allowlist (Josh) after the deploy; Sourcify and Blockscout for the hook and the opener.
