# Gen-4 hook: gas limit versus gas used, and which constants clear Uniswap's 130% rule (measured 20 Oct 2026)

Trigger: Uniswap (Angela, 20 Oct) will not allowlist the Gen-4 hook for routing while a swap needs a gas limit above 130% of what it uses. Their reading: the 1M gasleft() check (GEN4_FINALIZATION_GAS_RESERVE 200k + GEN4_MIN_ATTEMPT_GAS 800k) runs well into the swap; they suggested lowering it "to around 800k".

## Method

- Source: the verified standard JSON input for the deployed hook (hook_verification/FlowstateC1Hook.standard-input.json, commit 86c7eb7), compiled with solc 0.8.26, via-IR, 200 runs, cancun. The reference compile reproduces the live runtime byte for byte outside the 32-byte metadata hash (checked).
- Variants: only the gas constants changed (build_variants.py); each variant's runtime has its seven immutables copied from the live code at the compiler-reported offsets.
- Fork: anvil at the block before each live canary (chain id 4663, ArbSys stub at 0x64), the variant runtime set at the hook address, the canary's exact calldata from the canary wallet. For each variant: eth_estimateGas, the minimum passing gas limit by binary search on eth_call, and gasUsed from sending the transaction.
- Validation: the unmodified hook on the fork gives estimate 1,426,504 and used 770,284 against the live 1,427,945 and 768,570 (canary 2).

## Canary 2 (aeWETH exact-in 0.0005, one deposit node), limit/used

| Variant (constants changed from 800k attempt / 200k reserve / 450k leg base / 60k return) | estimateGas | min limit | gas used | limit/used |
|---|---|---|---|---|
| deployed Gen-4 | 1,426,504 | 1,426,524 | 770,284 | 1.85 |
| attempt 600k (check at 800k, Uniswap's suggestion) | 1,323,096 | 1,322,794 | 770,284 | 1.72 |
| attempt 500k | 1,323,096 | 1,322,794 | 770,284 | 1.72 |
| attempt 400k, leg base 300k | 1,163,343 | 1,163,394 | 770,284 | 1.51 |
| attempt 300k, leg base 250k, reserve 150k | 1,056,842 | 1,056,414 | 770,284 | 1.37 |
| attempt 400k, leg base 300k, reserve 100k | 1,056,842 | 1,056,414 | 770,284 | 1.37 |
| attempt 400k, leg base 250k, reserve 100k | 1,003,590 | 1,003,546 | 770,284 | 1.30 |
| attempt 300k, leg base 250k, reserve 100k | 1,003,590 | 1,003,546 | 770,284 | 1.30 |
| attempt 300k, leg base 300k, reserve 100k, return 30k | 1,024,892 | 1,024,947 | 770,284 | 1.33 |
| **attempt 300k, leg base 250k, reserve 100k, return 30k** | **971,641** | **971,604** | **770,284** | **1.26** |
| attempt 250k, leg base 200k, reserve 100k, return 30k | 918,388 | 918,127 | 770,284 | 1.19 |
| attempt 200k, leg base 200k, reserve 80k, return 20k | 886,438 | 886,093 | 770,284 | 1.15 |

Reading: lowering the attempt check alone does nothing below 600k because the pool-leg planning floor binds next (a leg is only started if the gas it can be given exceeds GEN4_POOL_LEG_BASE_GAS 450k plus one node), then the finalisation reserve and the per-leg return allowance. All four move together to get under 1.30. Uniswap's "around 800k" clears nothing on its own (1.72).

## What the constants protect, and what lowering them changes

- None of them is a safety property. Exact input is all-or-nothing and exact output reverts on shortfall; a leg that runs out of gas is caught by try/catch and the swap reverts. Lowering the constants cannot cause a partial fill or a fund movement. It changes at what gas limit a tight swap fails, and where (inside a leg instead of at the check).
- The measured floors they were sized from: finalisation about 40k (reserve 100k is 2.5x), the live pool leg 225k including its oracle read (leg base 250k is above it; the 450k came from an estimateGas probe that counted 63/64 retention), per-node 56k to 109k (unchanged).
- Review B of the Hashlock scope names "gas thresholds" in the hook explicitly, so a constants-only Gen-5 is a Review B delta.
- The constants are compile-time; the hook is immutable. This needs a new hook deployment: CREATE2 with mined flags, verification, setTrustedHook through the timelock, six pair registrations and six new V4 pool initialisations, Gen-4 pairs retired, Hooklist issue, 0x allowlist and Uniswap routing approval again for the new address. The 12 to 14 Oct GO1/GO2/wiring scripts cover every step.

## All three Thursday fills, limit/used (fork at the block before each; used is the fork's gasUsed)

| Variant | aeWETH exact-in (canary 2) | native exact-in (canary 1) | native exact-out (canary 3) |
|---|---|---|---|
| deployed Gen-4 (800k / 200k / 450k / 60k) | 1.85 (1,426,504 / 770,284) | 1.65 (1,445,595 / 878,250) | 1.72 (1,395,562 / 811,118) |
| 300k / 250k / 100k / 30k (recommended) | 1.26 (971,641) | 1.14 (996,039 / 878,154) | 1.19 (948,913 / 801,231) |
| 250k / 200k / 100k / 30k | 1.19 (918,388) | 1.11 (973,187) | 1.14 (910,666) |
| 200k / 200k / 80k / 20k | 1.15 (886,438) | 1.07 (941,237) | 1.10 (878,716) |
| 300k / 300k / 100k / 30k | 1.33 | 1.20 | 1.25 |
| 400k / 250k / 100k / 60k | 1.30 | 1.17 | 1.22 |

Order of constants: GEN4_MIN_ATTEMPT_GAS / GEN4_POOL_LEG_BASE_GAS / GEN4_FINALIZATION_GAS_RESERVE / GEN4_LEG_RETURN_GAS. The exact-output path uses the same constants through its own requiredGas check and the same leg sizing; it behaves the same. Gas used moves by under 10k between variants (a different number of gas-check branches), the fill amounts are unchanged.

## A fill served by a listing (measured 20 Oct 2026, later the same day)

Setup: anvil fork at block 89,963,046 (before canary 1; market unpaused, CASHCAT pool unpaused, lane open), ArbSys stub, the deployer's whole position withdrawn so the deposit queue is empty, a seller (anvil account 0) funded with 5,000 CASHCAT from the V3 pool, token approved to Permit2, unlimited Permit2 allowance to the settlement, registry.list of 2,000 CASHCAT (id 1, floors 1 wei on both seeded assets, 24 h expiry). Swap = canary 1's exact calldata (native exact-in 0.0005 ETH, the main door, the only door that sells listings). Each row sold 10.1823 CASHCAT out of the seller's wallet, so the fill came from the listing.

| Hook | estimateGas | min limit | gas used | limit/used |
|---|---|---|---|---|
| deployed Gen-4 | 1,709,304 | 1,709,424 | 1,035,586 | 1.65 |
| Gen-5 deposit floors, listing floor 800k (unchanged) | 1,570,851 | 1,571,189 | 1,038,778 | 1.51 |
| listing floor 600k | 1,357,846 | 1,358,078 | 1,038,778 | 1.31 |
| **listing floor 500k** | **1,251,345** | **1,251,472** | **1,038,778** | **1.21** |
| listing floor 400k | 1,151,755 | 1,152,440 | 1,038,778 | 1.11 |
| listing floor 350k / 300k | 1,151,755 | 1,152,440 | 1,034,800 to 1,038,778 | 1.11 |

Chosen: GEN4_LISTING_LEG_MIN_GAS 500k. It clears 1.30 with margin and sits inside the measured listing-leg range (335k to 542k with attribution on), below its maximum: a leg started with only the floor can still run out of gas on the largest measured listings, in which case the leg is caught and the swap reverts atomically with no partial fill. The floor therefore trades availability at a tight gas limit (a swap that would have needed a larger leg fails instead of filling) for the routing ratio; it is not a guarantee that every leg completes. 400k buys another 0.10 of ratio at the cost of starting more legs below the largest measured leg. Below 400k the binding constraint moves elsewhere (the ratio stops improving). (Wording corrected 21 Oct 2026 on Wilko's review of PR 19; the earlier text claimed a leg started at the floor does not run out of gas, which the 542k measurement contradicts.)

Raw rows: variant_results_listing_native_exactin.json.

Recommendation as of 20 Oct: 300k / 250k / 100k / 30k for the deposit path and 500k for the listing floor. SUPERSEDED 21 Oct (see the section below): the deposit set is 250k / 200k / 100k / 30k. These five values are the Gen-5 branch feat/gen5-gas-floors (clone at flowstate-workspace/flowstate-v4-hook-gen5). It clears 1.30 on every shape with the smallest departure from the measured floors (reserve 2.5x the 40k finalisation, leg base above the 225k live leg, attempt check above one cold read set of about 320k minus the reads already done before the check). The two tighter sets also pass and are kept here for the review.

Raw rows: variant_results.json (canary 2), variant_results_canary1_native_exactin.json, variant_results_canary3_native_exactout.json. Scripts and pinned inputs: docs/gen5-gas-evidence/ (README.md there gives the reproduction sequence from a clean checkout).

## 21 Oct 2026: the pricing branch moves the ratio; deposit set tightened to 250k / 200k / 100k / 30k

Re-running the Gen-5 fork rehearsal at a later block put the aeWETH exact-in canary at 1.313 (913,879 / 695,933) with the 300k / 250k / 100k / 30k set, against 1.272 the day before. The difference is the pricing branch: on 20 Oct the Rev 4 rule priced in CATCH_UP (spot under the averages), on 21 Oct in CLEAR (spot level with the averages, the normal flat-market state). CLEAR executes 50k to 70k cheaper while the hook's required limit barely moves, so the ratio rises. The live canaries of 16 Oct were all CATCH_UP, which is why the first measurements looked comfortable. Probe over both states and five constant sets (deployment-ledger/gen5_redeploy_2026-10-20/fork_rehearsal/ratio_probe/RATIO_PROBE_2026-10-21.md, scripts/probe_ratios.js):

| constants (attempt / leg base / reserve / return) | CATCH_UP branch (pin 93,052,471): native in / aeWETH in / native out | CLEAR branch (pin 93,864,832) |
|---|---|---|
| deployed Gen-4 (800k / 450k / 200k / 60k) | 1.844 / 1.845 / 1.726 | 1.948 / 1.950 / 1.819 |
| 20 Oct draft (300k / 250k / 100k / 30k) | 1.261 / 1.246 / 1.164 | 1.300 / 1.284 / 1.195 (1.313 on fresh pools in the full rehearsal) |
| **chosen (250k / 200k / 100k / 30k)** | **1.192 / 1.177 / 1.113** | **1.226 / 1.210 / 1.124** |
| 200k / 200k / 80k / 20k | 1.151 / 1.135 / 1.073 | 1.182 / 1.165 / 1.081 |
| 400k / 250k / 100k / 60k | 1.303 / 1.288 / 1.204 | 1.344 / 1.329 / 1.238 |

Chosen: 250k / 200k / 100k / 30k, about 0.07 of headroom to 1.30 in the worst measured state. What it costs: the leg base 200k is below the 225k live pool leg, so a swap sent with a gas limit just above the minimum can start a leg that runs short on a cold oracle read; the leg is caught and the swap reverts with no partial fill, exactly as with every other floor. The listing floor stays 500k (its 1.21 was measured with the 20 Oct deposit set; the tighter deposit set lowers the required limit further, so the listing ratio does not get worse; not re-measured on a listing fork on 21 Oct).
