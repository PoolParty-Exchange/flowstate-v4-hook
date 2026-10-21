#!/usr/bin/env python3
"""Measure estimateGas, the minimum passing gas limit and gasUsed for one swap against every variant runtime.

Needs an anvil fork of Robinhood Chain (chain id 4663) pinned at the block BEFORE the fill being replayed, for example
  anvil --fork-url $RH_RPC_URL --fork-block-number 89964424 --chain-id 4663 --port 8547
(89,964,424 is the block before live canary 2; canary 1 was at 89,963,047, canary 3 at 89,965,325). The script stubs ArbSys
at 0x64, funds and impersonates the sender, and for each variant in work/variants.json: sets the variant runtime at the
hook address (the reference variant leaves the live code in place), eth_estimateGas, binary-searches the minimum passing
gas limit with eth_call, sends the transaction and reads gasUsed, then reverts the fork to the snapshot.

Usage: python3 measure_variants.py --label <name> --calldata inputs/<file>.hex [--value WEI] [--sender ADDR] [--url http://127.0.0.1:8547] [--work DIR]
Writes work/variant_results_<label>.json. Nothing touches the live chain.
"""
import argparse, json, os, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("--label", required=True)
ap.add_argument("--calldata", required=True, help="hex file with the exact router calldata of the fill")
ap.add_argument("--value", default="0", help="msg.value in wei (0 for aeWETH exact-in)")
ap.add_argument("--sender", default="0xb221Ee086882D295B0EC67ffA2c66f2a69f52ca8", help="the canary wallet")
ap.add_argument("--url", default=os.environ.get("FORK_URL", "http://127.0.0.1:8547"))
ap.add_argument("--work", default=os.path.join(HERE, "work"))
ap.add_argument("--hook", default="0x3f7C2bEA8cA39E7fd1E07B63294544369ef268cC")
ap.add_argument("--router", default="0x8876789976dEcBfCbBbe364623C63652db8C0904")
args = ap.parse_args()

DATA = open(args.calldata).read().strip()
_id = 0
def rpc(m, p=[]):
    global _id; _id += 1
    r = urllib.request.Request(args.url, data=json.dumps({"jsonrpc": "2.0", "id": _id, "method": m, "params": p}).encode(), headers={"content-type": "application/json"})
    o = json.loads(urllib.request.urlopen(r, timeout=600).read())
    return {"error": o["error"]} if "error" in o else o["result"]

assert rpc("eth_chainId") == "0x1237", "fork must run chain id 4663"
rpc("anvil_setCode", ["0x0000000000000000000000000000000000000064", "0x4360005260206000f3"])
rpc("anvil_setBalance", [args.sender, hex(10 ** 19)]); rpc("anvil_impersonateAccount", [args.sender]); rpc("anvil_setBlockTimestampInterval", [1])
tx = {"from": args.sender, "to": args.router, "data": DATA, "value": hex(int(args.value))}

def passes(gas):
    return not isinstance(rpc("eth_call", [dict(tx, gas=hex(gas)), "latest"]), dict)
def min_limit(lo, hi):
    while hi - lo > 1000:
        mid = (lo + hi) // 2
        if passes(mid): hi = mid
        else: lo = mid
    return hi

variants = json.load(open(os.path.join(args.work, "variants.json")))
rows = []
for v in variants:
    name = v["name"]; snap = rpc("evm_snapshot")
    if not name.endswith("_ref"): rpc("anvil_setCode", [args.hook, open(os.path.join(args.work, v["file"])).read().strip()])
    est = rpc("eth_estimateGas", [tx])
    if isinstance(est, dict): rows.append({"variant": name, "error": "estimate failed: " + json.dumps(est)[:300]}); rpc("evm_revert", [snap]); continue
    est = int(est, 16); ml = min_limit(300_000, est + 50_000)
    h = rpc("eth_sendTransaction", [dict(tx, gas=hex(est + 20_000))])
    if isinstance(h, dict): rows.append({"variant": name, "error": "send failed: " + str(h)[:200]}); rpc("evm_revert", [snap]); continue
    rpc("evm_mine"); rc = None
    for _ in range(20):
        rc = rpc("eth_getTransactionReceipt", [h])
        if rc: break
        rpc("evm_mine")
    used = int(rc["gasUsed"], 16); ok = rc["status"] == "0x1"
    rows.append({"variant": name, "constants": v["constants"], "estimateGas": est, "minLimit": ml, "gasUsed": used, "status1": ok, "ratio": round(ml / used, 3)})
    rpc("evm_revert", [snap])

print(f"== {args.label}\n{'variant':44} {'estimateGas':>12} {'min limit':>10} {'gas used':>9} ok  limit/used")
for r in rows:
    if "error" in r: print(f"{r['variant']:44} {r['error']}"); continue
    print(f"{r['variant']:44} {r['estimateGas']:>12,} {r['minLimit']:>10,} {r['gasUsed']:>9,} {str(r['status1']):4} {r['ratio']}")
out = os.path.join(args.work, f"variant_results_{args.label}.json"); json.dump(rows, open(out, "w"), indent=1); print("written", out)
