# Beacon hook deploy runbook (per chain, per pair)

Status: staging-proven on Robinhood Chain (4663). Production reruns repeat the same
sequence with production addresses; the mined salt and hook address change per chain
and per constructor args by design.

Context: the hook admits exactly ONE liquidityDelta == 1 dust add per pool
(JUP-519), because GMGN's routing index admits pools by ModifyLiquidity history
(JUP-516 measurement). The dust is paid by the seeding caller, never by Flowstate
(no-protocol-capital rule): in production the first depositor lights the beacon
inside `seedAndDeposit`; on staging the ops wallet acts as the holder.

## Sequence

All commands run from `flowstate-v4-hook` on the target branch, with `RH_RPC_URL`
exported and the broadcaster key supplied by the operator (`--private-key` or a
keystore; the key never lives in this repo).

Staging values used below (Robinhood 4663). Verified on-chain 2026-08-19
(JUP-570 sweep: an earlier revision of this table pointed at the market retired
on 2026-08-16 — re-verify FS_MARKET and MARKET_POOL against the live chain
before every run; MARKET_POOL is `market.poolByToken(PAIR_TOKEN)`):

| name | value |
|---|---|
| V4_POOL_MANAGER | 0x8366a39CC670B4001A1121B8F6A443A643e40951 |
| FS_MARKET | 0x8eFb662F738D0f5d9f146803FD02A36c6B67e60d |
| HOOK_OWNER (ops) | 0x5F29890B5b1d005E2dA78aA1687a690562CE5f1b |
| AEWETH | 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 |
| PAIR_TOKEN (CASHCAT) | 0x020bfC650A365f8BB26819deAAbF3E21291018b4 |
| MARKET_POOL (C1) | 0x1c8Fe931c9be6583d9a2E5C05712a0F6d1e4faeD |

The mined salt, hook address and resulting poolId are regenerated at every
deploy (step 2) and are deliberately NOT tabled here.

1. **Reseller code on the market first** (once per market): `deploy/manage-reseller.js`
   in PoolParty_Contracts, so hook buys attribute from the first fill.
2. **Mine** (no broadcast, CPU only):
   `V4_POOL_MANAGER=.. FS_MARKET=.. HOOK_OWNER=.. AEWETH=.. forge script script/MineHookAddress.s.sol`
   Record the printed salt + expected hook address. The mask is 0x28cc, unchanged by
   the beacon gate. Re-mine whenever bytecode or constructor args change.
3. **Deploy hook + register pair + reseller code**:
   `SALT=.. EXPECTED_HOOK=.. V4_POOL_MANAGER=.. FS_MARKET=.. HOOK_OWNER=.. AEWETH=.. PAIR_TOKEN=.. MARKET_POOL=.. RESELLER_CODE=v4hook BASE_SPREAD_BPS=30 forge script script/DeployHook.s.sol --rpc-url $RH_RPC_URL --broadcast`
   The script reverts if the deployed address differs from the mined one.
   `registerPair` first verifies the Market recognizes `MARKET_POOL`, binds it to
   `PAIR_TOKEN`, and currently approves the resolved quote asset; it then performs the
   market `forceApprove`, so no separate approval step exists or is needed. Confirm
   `isPairReady` before initialization. A later quote-asset revocation or a
   `baseSpreadFloorBps` increase above the stored spread makes the pair non-ready until
   the Market approval is restored or `setBaseSpread` retunes it.
4. **Deploy the seeder** (unprivileged, stateless, once per chain):
   `V4_POOL_MANAGER=.. FS_MARKET=.. forge script script/DeployBeaconSeeder.s.sol --rpc-url $RH_RPC_URL --broadcast`
5. **Initialize the V4 pool** (starts the discovery clock):
   `HOOK=.. PAIR_TOKEN=.. AEWETH=.. V4_POOL_MANAGER=.. RATE_RAW=<oracle raw rate> PROBE_AMOUNT=<raw wei or 0 to skip> forge script script/InitPoolAndProbe.s.sol --rpc-url $RH_RPC_URL --broadcast`
   The probe (optional) proves the live swap path with a dust buy; it needs the C1
   pool to hold at least a few tokens of inventory and the broadcaster to hold the
   probe amount in aeWETH.
6. **Light the beacon** (once per pool; any payer):
   `HOOK=.. SEEDER=.. PAIR_TOKEN=.. AEWETH=.. PAY_TOKEN=<one of the two currencies> forge script script/SeedBeacon.s.sol --rpc-url $RH_RPC_URL --broadcast`
   The broadcaster pays a few wei of PAY_TOKEN (the script wraps 16 wei of native
   automatically when paying in the WETH9 wrapper). Verify: script asserts
   `beaconSeeded(poolId)` true; the PoolManager `ModifyLiquidity` event in the
   receipt is the beacon itself.
7. **Verify + record**: hook address (flags end 0x...28cc), poolId from the
   Initialize event, seeder address, beacon tx hash. Update the monitor's
   `MONITOR_CHAINS` env (JUP-508) to include the NEW pool and hook addresses
   alongside the old ones.

## Old-pool coexistence (decided 9 Aug, PR #3 review thread)

Keep BOTH pools live. The old pool (0x626d6ca4..., hook 0x9ffc18e5...) can never be
beacon-seeded (its `beforeAddLiquidity` reverts unconditionally) and keeps serving
0x's simulation-based routing, which measurably routes it. The new pool adds the
GMGN-visible surface. Both front the SAME C1 inventory through the market's FIFO —
sequential pulls, depositors unaffected, nothing to double-spend. Deprecation of the
old pool is optional later cleanup once the new pool has fill history.

## Production notes

- The beacon seed in production is the FIRST DEPOSITOR's `seedAndDeposit`
  (one approval: seeder, amount + a few wei; one transaction). Standalone `seed()`
  stays available to any payer if a pool should be lit before inventory arrives.
- Native-quoted pools: seeder is ERC-20-only in v1 (`NativePayUnsupported`);
  wrap-inside-seeder is v2 scope if native-quoted pools become material.
- Engagement B audit scope includes the gate + seeder + their tests
  (JUP-519; note sent to Hashlock before Engagement B starts).
- Dust cost is price-dependent in units (1 wei at the live CASHCAT price), always
  value-negligible; regression-bounded in `BeaconDustCost.t.sol`.
