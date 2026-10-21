# Gen-5 gas evidence: how to reproduce the measurements from a clean checkout

The numbers in ../GEN5_GAS_FLOORS_2026-10-20.md were measured on 20 Oct 2026 on anvil forks of Robinhood Chain. The checked-in result files (variant_results*.json) are the rows of record. This folder holds everything needed to regenerate them. No step touches the live chain; the fork needs an archive-capable RPC URL for chain 4663 (RH_RPC_URL in the operator's environment, never committed).

Requirements: python3 (standard library only), solc 0.8.26 (`svm install 0.8.26` or any 0.8.26 binary; pass it with --solc or SOLC=), anvil (foundry 1.7.x), an RPC URL.

## 1. Pinned inputs (inputs/)

| File | What it is | sha256 |
|---|---|---|
| gen4_86c7eb7_standard-input.json | the standard JSON input the deployed Gen-4 hook 0x3f7C2bEA was verified with on Sourcify and Blockscout (commit 86c7eb7, 32 sources, solc 0.8.26, cancun, via-IR, 200 runs) | 9261530a4faf339ec035e0ede7c02ad13518faccd53732fd495a1ce7aa1e4a06 |
| gen4_live_runtime_0x3f7C2bEA.hex | eth_getCode of the live Gen-4 hook (24,013 bytes); source of the seven immutable values | abdfdff7d3c57c8065c788c1cc9ebe0259203d97564d174448ccd3f2cc1d7ebc |
| canary1_native_exactin_calldata.hex | exact Universal Router calldata of live canary 1 (tx 0xad23d6de..., block 89,963,047, value 0.0005 ETH) | 63dc0c58f2f6e97e980e85b31ac104e8df976f6e1bba68616f0c842544260fb3 |
| canary2_aeweth_exactin_calldata.hex | exact calldata of live canary 2 (tx 0x791eaf8a..., block 89,964,425, value 0) | 82ee9b13b3c9e108b3c9743ab178296c1ed51adfae70d10e12fc5e9748ef3c6f |

Canary 3 (native exact-output 5 CASHCAT with SWEEP, tx 0x301d6feb..., block 89,965,325) was measured from its live calldata read off the chain at the time; fetch it with `cast tx 0x301d6feb8a2301a6fa5d511a824266bd15f54ae2c9ac1587666ef20de456d024 input --rpc-url $RH_RPC_URL` and its value (0.000246752639246189 ETH) from the same transaction.

## 2. Deposit-path measurements (the canary tables)

```bash
python3 build_variants.py --set deposit          # compiles 13 variants (W0 reference + W1..W12), writes work/variants.json
anvil --fork-url "$RH_RPC_URL" --fork-block-number 89964424 --chain-id 4663 --port 8547 &   # block before canary 2
python3 measure_variants.py --label canary2_aeweth_exactin --calldata inputs/canary2_aeweth_exactin_calldata.hex --value 0
```

Repeat with the fork pinned at 89,963,046 and canary1_native_exactin_calldata.hex (value 500000000000000) for canary 1, and at 89,965,324 with the canary 3 calldata and value for canary 3. The reference row (W0_ref, live code untouched) must reproduce the live receipt's gasUsed within 0.1% (canary 2: fork 770,284 against live 768,570) before the other rows mean anything. Variant names map to the table rows: W9 is the Gen-5 set (300k / 250k / 100k / 30k).

## 3. Listing-fill measurement

The listing row needs a fork state with no deposit inventory and one live listing, prepared by hand on 20 Oct (the preparation was done interactively through cast against the fork and is described here rather than scripted; the resulting measurement is in variant_results_listing_native_exactin.json):

1. `anvil --fork-url "$RH_RPC_URL" --fork-block-number 89963046 --chain-id 4663 --port 8547` (market unpaused, CASHCAT pool unpaused, lane open at that block).
2. Stub ArbSys: `cast rpc anvil_setCode 0x0000000000000000000000000000000000000064 0x4360005260206000f3`.
3. Empty the deposit queue: impersonate the deployer 0x5F29890B (the only depositor) and withdraw its whole CASHCAT position from the pool through the market's withdrawal call, so maxBuy reads 0 from deposits.
4. Fund the seller (anvil account 0, 0xf39Fd6e5...) with 5,000 CASHCAT by impersonating the 1% CASHCAT/aeWETH V3 pool 0xA70fc67C and transferring.
5. Seller: CASHCAT.approve(Permit2, max); Permit2.approve(CASHCAT, listing settlement 0xAF888340, max, 48 h); C1ListingRegistry 0x882DD9b6 .list(CASHCAT pool, 2,000e18, floors of 1 wei on USDG and aeWETH, 24 h expiry). Listing id 1.
6. `python3 build_variants.py --set listing` (W0 reference + X_list800k..X_list300k), then `python3 measure_tx.py --label listing_native_exactin --calldata inputs/canary1_native_exactin_calldata.hex --value 500000000000000 --seller 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`. Every row must show the seller's balance falling by the fill amount (10.1823 CASHCAT), proving the fill came from the listing.

## 4. Reading the results

limit/used is minLimit divided by gasUsed, where minLimit is the smallest gas limit at which eth_call succeeds (binary search to 1,000 gas) and is within a few hundred gas of eth_estimateGas on every row. Uniswap's routing rule is estimateGas under 130% of execution; both columns are reported. gasUsed moves by under 10k between variants (different gas-check branches); fill amounts do not move.

Limits of this evidence: fork measurements, not live receipts (the live Gen-5 canaries after deployment are the figures of record); the listing row covers one listing shape (2,000 CASHCAT, attribution on, one leg); Uniswap measures with its own tooling.
