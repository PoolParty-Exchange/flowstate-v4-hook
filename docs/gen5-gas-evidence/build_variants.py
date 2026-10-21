#!/usr/bin/env python3
"""Compile the Gen-4 hook with alternative gas constants and fill in the live immutables.

Reproducible from a clean checkout. Inputs are pinned under inputs/ (see README.md):
  inputs/gen4_86c7eb7_standard-input.json   the verified standard JSON input of the deployed Gen-4 hook (commit 86c7eb7)
  inputs/gen4_live_runtime_0x3f7C2bEA.hex   the runtime code read from the live hook (eth_getCode)
Outputs go to the work directory (default: ./work next to this script; override with --work):
  work/variant_<name>.hex   one runtime per variant, immutables copied from the live code at the compiler-reported offsets
  work/variants.json        the explicit list of variants written, in order (the measure scripts read this, not a glob)

Usage: python3 build_variants.py [--solc PATH] [--work DIR] [--set deposit|listing|all]
solc 0.8.26 is taken from --solc, the SOLC environment variable, or `solc` on PATH (must report 0.8.26).
"""
import argparse, copy, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("--solc", default=os.environ.get("SOLC", "solc"))
ap.add_argument("--work", default=os.path.join(HERE, "work"))
ap.add_argument("--set", default="all", choices=["deposit", "listing", "all"])
ap.add_argument("--standard-input", default=os.path.join(HERE, "inputs", "gen4_86c7eb7_standard-input.json"))
ap.add_argument("--live-runtime", default=os.path.join(HERE, "inputs", "gen4_live_runtime_0x3f7C2bEA.hex"))
args = ap.parse_args()
os.makedirs(args.work, exist_ok=True)

ver = subprocess.run([args.solc, "--version"], capture_output=True, text=True).stdout
assert "0.8.26" in ver, "need solc 0.8.26, got: " + ver.strip().splitlines()[-1]

inp = json.load(open(args.standard_input))
inp["settings"]["outputSelection"] = {"*": {"FlowstateC1Hook": ["evm.deployedBytecode.object", "evm.deployedBytecode.immutableReferences"]}}
HOOK = [k for k in inp["sources"] if k.endswith("src/FlowstateC1Hook.sol")][0]
live = open(args.live_runtime).read().strip()
live = live[2:] if live.startswith("0x") else live

# the five constants as they read in the deployed Gen-4 source (86c7eb7)
CONSTS = {"ATTEMPT": "GEN4_MIN_ATTEMPT_GAS = 800_000", "RESERVE": "GEN4_FINALIZATION_GAS_RESERVE = 200_000", "LEGBASE": "GEN4_POOL_LEG_BASE_GAS = 450_000", "LISTMIN": "GEN4_LISTING_LEG_MIN_GAS = 800_000", "RETURN": "GEN4_LEG_RETURN_GAS = 60_000"}

def compile(subs):
    d = copy.deepcopy(inp); src = d["sources"][HOOK]["content"]
    for k, v in subs.items():
        name, _ = CONSTS[k].split(" = "); pat = re.escape(CONSTS[k])
        assert len(re.findall(pat, src)) == 1, k
        src = re.sub(pat, f"{name} = {v}", src)
    d["sources"][HOOK]["content"] = src
    r = subprocess.run([args.solc, "--standard-json"], input=json.dumps(d), capture_output=True, text=True)
    out = json.loads(r.stdout)
    errs = [e for e in out.get("errors", []) if e["severity"] == "error"]
    assert not errs, errs[:2]
    c = out["contracts"][HOOK]["FlowstateC1Hook"]["evm"]["deployedBytecode"]
    return c["object"], c["immutableReferences"]

ref_code, ref_imm = compile({})
print("reference runtime bytes", len(ref_code) // 2, "| live", len(live) // 2, "| immutable ids", len(ref_imm))
diff = [i for i in range(0, min(len(ref_code), len(live)), 2) if ref_code[i:i + 2] != live[i:i + 2]]
imm_pos = set()
for _id, refs in ref_imm.items():
    for r in refs:
        for b in range(r["start"], r["start"] + r["length"]): imm_pos.add(b)
non_imm = [i // 2 for i in diff if i // 2 not in imm_pos]
print("bytes differing outside the immutables:", len(non_imm), "(all inside the 53-byte metadata tail starting at", len(live) // 2 - 53, "):", all(b >= len(live) // 2 - 53 for b in non_imm))

def fill(code, imm):
    code = bytearray.fromhex(code); liveb = bytes.fromhex(live)
    for _id, refs in imm.items():
        r0 = ref_imm[_id][0]; val = liveb[r0["start"]:r0["start"] + r0["length"]]
        for r in refs:
            assert r["length"] == len(val)
            code[r["start"]:r["start"] + r["length"]] = val
    return code.hex()

# Deposit-path variants (W): the rows of the canary tables in GEN5_GAS_FLOORS_2026-10-20.md, in table order.
DEPOSIT = {
    "W0_ref": {},
    "W1_attempt600k": {"ATTEMPT": "600_000"},
    "W2_attempt500k": {"ATTEMPT": "500_000"},
    "W3_attempt400k_leg300k": {"ATTEMPT": "400_000", "LEGBASE": "300_000"},
    "W4_attempt300k_leg250k_res150k": {"ATTEMPT": "300_000", "LEGBASE": "250_000", "RESERVE": "150_000"},
    "W5_attempt400k_leg300k_res100k": {"ATTEMPT": "400_000", "LEGBASE": "300_000", "RESERVE": "100_000"},
    "W6_attempt400k_leg250k_res100k": {"ATTEMPT": "400_000", "LEGBASE": "250_000", "RESERVE": "100_000"},
    "W7_attempt300k_leg250k_res100k": {"ATTEMPT": "300_000", "LEGBASE": "250_000", "RESERVE": "100_000"},
    "W8_attempt300k_leg300k_res100k_ret30k": {"ATTEMPT": "300_000", "LEGBASE": "300_000", "RESERVE": "100_000", "RETURN": "30_000"},
    "W9_GEN5_attempt300k_leg250k_res100k_ret30k": {"ATTEMPT": "300_000", "LEGBASE": "250_000", "RESERVE": "100_000", "RETURN": "30_000"},
    "W10_attempt250k_leg200k_res100k_ret30k": {"ATTEMPT": "250_000", "LEGBASE": "200_000", "RESERVE": "100_000", "RETURN": "30_000"},
    "W11_attempt200k_leg200k_res80k_ret20k": {"ATTEMPT": "200_000", "LEGBASE": "200_000", "RESERVE": "80_000", "RETURN": "20_000"},
    "W12_attempt400k_leg250k_res100k_ret60k": {"ATTEMPT": "400_000", "LEGBASE": "250_000", "RESERVE": "100_000", "RETURN": "60_000"},
}
# Listing-floor variants (X): the Gen-5 deposit constants with the listing floor swept.
G5 = {"ATTEMPT": "300_000", "LEGBASE": "250_000", "RESERVE": "100_000", "RETURN": "30_000"}
LISTING = {"W0_ref": {}}
for k in ["800_000", "600_000", "500_000", "400_000", "350_000", "300_000"]:
    LISTING["X_list" + k.replace("_000", "k")] = dict(G5, LISTMIN=k)

variants = {"deposit": DEPOSIT, "listing": LISTING, "all": {**DEPOSIT, **LISTING}}[args.set]
written = []
for name, subs in variants.items():
    code, imm = compile(subs); filled = fill(code, imm)
    path = os.path.join(args.work, f"variant_{name}.hex"); open(path, "w").write("0x" + filled)
    written.append({"name": name, "file": os.path.basename(path), "constants": subs})
    print(f"{name:44} bytes {len(filled) // 2}  identical to live: {filled == live}")
json.dump(written, open(os.path.join(args.work, "variants.json"), "w"), indent=1)
print("written", len(written), "variants ->", os.path.join(args.work, "variants.json"))
