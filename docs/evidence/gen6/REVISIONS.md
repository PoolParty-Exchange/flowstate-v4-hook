# Gen-6 fork evidence: exact revisions

Fork of Robinhood Chain (chain id 4663) at block 96,649,360 (run 2) via hardhat, port 8546.

| Piece | Revision |
|---|---|
| Hook + opener under test (run 3, 26 Oct, per-fill opener allowance) | flowstate-v4-hook feat/gen6 at the commit that adds `docs/evidence/gen6/fork_e2e_run3_2026-10-26` (PR 20); fork block 97,912,567 from the public RPC |
| Hook + opener under test (run 2) | flowstate-v4-hook `e212a40` (feat/gen6, PR 20) |
| Hook + opener under test (run 1, Gen-5 constants) | flowstate-v4-hook `deb928f` |
| Contracts applied to the fork | PoolParty_Contracts worktree `4280085` (feat/jup-772-settlement-band, PR 62, stacked on feat/jup-771-permissionless-lane `cd0ef59`, PR 61); JUP-771 manifest applied through the live timelocks by `deploy/gen6_apply_771_fork.js` |
| Market impl before / after | 0x077Ec02DBb862Dd1Da3abaE8f87EAae77943e0bC / 0xdE2fb1C8d668de51b3e43BBb3E7dfe5319c7e2fF |
| Pool impl before / after | 0x1f201e8ea410d832863Fb8A768bE6ddF0C3D4a20 / 0xc283ac50e1590D297D01587b10754fCd0C3407e0 |
| Gen-6 hook on the fork | 0x62B4ab3AFeC1a270fe1C0Ed8d68fe70Aba99E8Cc |
| Test driver | `test/stack/gen6-fork-e2e.cjs`; ratio probe `test/stack/gen6-ratio-probe.cjs` |

Run 2: 36 of 36 checks. Run 1 (Gen-5 constants 250/200/100/30/500): 34 of 36, the two misses were the steady-state gas ratios that led to the retune.

Run 3 (26 Oct 2026, after the opener allowance became a per-fill grant): 36 of 36 checks; steady-state ratios 1.12 / 1.066 / 1.169 (unchanged from run 2); first fills light their beacons with the allowance zeroed in the same transaction; createPool(ROBINCAT) 1,791,700 gas (run 2: 1,809,725; the unlimited approve at registration is gone).
