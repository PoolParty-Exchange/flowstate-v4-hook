#!/usr/bin/env python3
"""Listing-fill measurement: like measure_variants.py, but also reports how many tokens the seller's wallet lost, which
proves the fill was served by the listing and not by a deposit. Run it against a fork prepared by prepare_listing_fork.md
(README.md section 3): deposit queue emptied, one 2,000 CASHCAT listing from the seller, the market and pool unpaused.

Usage: python3 measure_tx.py --label listing_native_exactin --calldata inputs/canary1_native_exactin_calldata.hex --value 500000000000000 --seller 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 [--url ...] [--work DIR]
Only the reference variant and the X_* (listing floor) variants from work/variants.json are measured.
"""
import argparse, json, os, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("--label", required=True); ap.add_argument("--calldata", required=True); ap.add_argument("--value", default="500000000000000")
ap.add_argument("--seller", default="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", help="the listing seller on the fork (anvil account 0)")
ap.add_argument("--sender", default="0xb221Ee086882D295B0EC67ffA2c66f2a69f52ca8"); ap.add_argument("--url", default=os.environ.get("FORK_URL", "http://127.0.0.1:8547")); ap.add_argument("--work", default=os.path.join(HERE, "work"))
ap.add_argument("--hook", default="0x3f7C2bEA8cA39E7fd1E07B63294544369ef268cC"); ap.add_argument("--router", default="0x8876789976dEcBfCbBbe364623C63652db8C0904"); ap.add_argument("--token", default="0x020bfc650a365f8bb26819deaabf3e21291018b4")
args = ap.parse_args()

DATA = open(args.calldata).read().strip(); _id = 0
def rpc(m, p=[]):
    global _id; _id += 1
    r = urllib.request.Request(args.url, data=json.dumps({"jsonrpc": "2.0", "id": _id, "method": m, "params": p}).encode(), headers={"content-type": "application/json"})
    o = json.loads(urllib.request.urlopen(r, timeout=600).read()); return {"error": o["error"]} if "error" in o else o["result"]
assert rpc("eth_chainId") == "0x1237", "fork must run chain id 4663"
rpc("anvil_setCode", ["0x0000000000000000000000000000000000000064", "0x4360005260206000f3"]); rpc("anvil_setBalance", [args.sender, hex(10 ** 18)]); rpc("anvil_impersonateAccount", [args.sender])
tx = {"from": args.sender, "to": args.router, "data": DATA, "value": hex(int(args.value))}
def passes(gas): return not isinstance(rpc("eth_call", [dict(tx, gas=hex(gas)), "latest"]), dict)
def min_limit(lo, hi):
    while hi - lo > 1000:
        mid = (lo + hi) // 2
        if passes(mid): hi = mid
        else: lo = mid
    return hi
def bal(a): return int(rpc("eth_call", [{"to": args.token, "data": "0x70a08231" + a[2:].lower().rjust(64, "0")}, "latest"]), 16)
variants = [v for v in json.load(open(os.path.join(args.work, "variants.json"))) if v["name"].endswith("_ref") or v["name"].startswith("X_")]
rows = []
for v in variants:
    name = v["name"]; snap = rpc("evm_snapshot")
    if not name.endswith("_ref"): rpc("anvil_setCode", [args.hook, open(os.path.join(args.work, v["file"])).read().strip()])
    b0 = bal(args.seller); est = rpc("eth_estimateGas", [tx])
    if isinstance(est, dict): rows.append({"variant": name, "error": "estimate failed: " + json.dumps(est)[:300]}); rpc("evm_revert", [snap]); continue
    est = int(est, 16); ml = min_limit(300_000, est + 50_000)
    h = rpc("eth_sendTransaction", [dict(tx, gas=hex(est + 20_000))])
    if isinstance(h, dict): rows.append({"variant": name, "error": "send failed"}); rpc("evm_revert", [snap]); continue
    rpc("evm_mine"); rc = rpc("eth_getTransactionReceipt", [h])
    used = int(rc["gasUsed"], 16); sold = (b0 - bal(args.seller)) / 1e18
    rows.append({"variant": name, "constants": v["constants"], "estimateGas": est, "minLimit": ml, "gasUsed": used, "status1": rc["status"] == "0x1", "ratio": round(ml / used, 3), "sellerSoldTokens": sold}); rpc("evm_revert", [snap])
print(f"== {args.label}\n{'variant':34} {'estimateGas':>12} {'min limit':>10} {'gas used':>9} ok  limit/used  seller sold")
for r in rows:
    if "error" in r: print(f"{r['variant']:34} {r['error']}"); continue
    print(f"{r['variant']:34} {r['estimateGas']:>12,} {r['minLimit']:>10,} {r['gasUsed']:>9,} {str(r['status1']):4} {r['ratio']}  {r['sellerSoldTokens']:.4f}")
out = os.path.join(args.work, f"variant_results_{args.label}.json"); json.dump(rows, open(out, "w"), indent=1); print("written", out)
