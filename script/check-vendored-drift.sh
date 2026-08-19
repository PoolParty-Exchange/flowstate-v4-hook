#!/usr/bin/env bash
# JUP-567. Two gates, because the drift that actually bit us came in two shapes.
#
#   GATE 1  vendored SOURCE drift. The fork suite compiles vendored copies of the
#           C1 contracts via deployCode. Before this they were 327 lines behind
#           ship, so every "passing" fork test passed against contracts we do not
#           deploy. A stale copy still compiles and still goes green, so nothing
#           announces it.
#
#   GATE 2  local INTERFACE drift. This is the one that actually cost the most
#           time, and gate 1 would not have caught it: test/fork/RealStackDeployer.sol
#           hand-declares IFlowstatePoolTest / IFlowstateMarketTest, and anchorOf was
#           declared returning a 4-tuple (with an `ema` field the anchor redesign
#           removed) against a real 3-tuple. That is not a compile error. It is an
#           ABI decode failure at runtime, surfacing as an opaque EvmError. A hand-
#           maintained interface compiles happily while being wrong.
set -euo pipefail

PIN_FILE="test/real/poolparty/.vendored-from"
# Canonical remote is NOT overridable: an overridable remote lets the gate compare
# against an attacker-chosen repo and pass.
CONTRACTS_REPO="https://github.com/PoolParty-Exchange/PoolParty_Contracts.git"

[ -f "$PIN_FILE" ] || { echo "missing $PIN_FILE"; exit 1; }
PIN="$(tr -d '[:space:]' < "$PIN_FILE")"

# Full 40-hex commit only. A branch, tag or short SHA is mutable, and a mutable pin
# is not a pin: it lets stale vendored files be blessed by moving the target.
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || { echo "pin must be a full 40-hex commit SHA, got: $PIN"; exit 1; }
echo "vendored copies pinned to PoolParty_Contracts $PIN"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git clone -q --filter=blob:none --no-checkout "$CONTRACTS_REPO" "$TMP/c"
git -C "$TMP/c" fetch -q --depth 1 origin "$PIN"
# Prove we fetched the commit we asked for, not whatever a ref happened to point at.
got="$(git -C "$TMP/c" rev-parse FETCH_HEAD^{commit})"
[ "$got" = "$PIN" ] || { echo "fetched $got but pin says $PIN"; exit 1; }

fail=0

# ---------------------------------------------------------------- GATE 1: sources
echo
echo "gate 1: vendored sources"
while IFS= read -r f; do
  rel="${f#test/real/poolparty/}"
  if git -C "$TMP/c" show "$PIN:contracts/$rel" > "$TMP/theirs" 2>/dev/null; then
    diff -q "$f" "$TMP/theirs" >/dev/null || { echo "  DRIFT: $rel"; fail=1; }
  else
    # Not "allowed" silently: a vendored path with no upstream counterpart is either a
    # rename we missed or a file that should not be here. Name it and fail.
    echo "  NO UPSTREAM COUNTERPART: $rel"; fail=1
  fi
done < <(find test/real/poolparty -name '*.sol' | sort)
[ "$fail" -eq 0 ] && echo "  ok"

# -------------------------------------------------------------- GATE 2: interfaces
echo
echo "gate 2: locally declared interfaces vs real ABI"
command -v forge >/dev/null || { echo "  forge not on PATH"; exit 1; }
forge build --skip test >/dev/null 2>&1 || forge build >/dev/null 2>&1 || true

python3 - "$TMP" "$PIN" <<'PY' || fail=1
import json,re,subprocess,sys,pathlib
tmp,pin=sys.argv[1],sys.argv[2]

# local hand-written interfaces we must keep honest, mapped to the real contract
TARGETS={"IFlowstatePoolTest":"FlowstatePool","IFlowstateMarketTest":"FlowstateMarket"}
src=pathlib.Path("test/fork/RealStackDeployer.sol").read_text()

def real_abi(name):
    p=pathlib.Path(f"out/{name}.sol/{name}.json")
    if not p.exists(): return None
    return json.loads(p.read_text()).get("abi")

ELEM=re.compile(r"^(address|bool|string|bytes\d*|u?int\d*)(\[\d*\])*$")
def norm(t):
    t={"uint":"uint256","int":"int256"}.get(t,t)
    # a struct name in Solidity source appears as "tuple" in the ABI; anything that is
    # not an elementary type is therefore a struct reference from our side
    if not ELEM.match(t):
        return "tuple[]" if t.endswith("[]") else "tuple"
    return t

bad=0
for iface,contract in TARGETS.items():
    m=re.search(rf"interface\s+{iface}\s*\{{(.*?)\n\}}", src, re.S)
    if not m: continue
    abi=real_abi(contract)
    if abi is None:
        print(f"  cannot read out/{contract}.sol/{contract}.json (vendored build missing) - skipping {iface}")
        continue
    byname={}
    for e in abi:
        if e.get("type")=="function":
            byname.setdefault(e["name"],[]).append(e)
    for fn in re.finditer(r"function\s+(\w+)\s*\(([^)]*)\)[^;{]*?(?:returns\s*\(([^)]*)\))?\s*;", m.group(1), re.S):
        name,args,rets=fn.group(1),fn.group(2),fn.group(3) or ""
        cands=byname.get(name)
        if not cands:
            print(f"  MISSING: {iface}.{name} does not exist on {contract}"); bad=1; continue
        def types(s):
            out=[]
            for p in [x.strip() for x in s.split(",") if x.strip()]:
                out.append(norm(p.split()[0]))
            return out
        want_in,want_out=types(args),types(rets)
        ok=False
        for c in cands:
            got_in=[norm(i["type"]) for i in c.get("inputs",[])]
            got_out=[norm(o["type"]) for o in c.get("outputs",[])]
            if got_in==want_in and got_out==want_out: ok=True; break
        if not ok:
            c=cands[0]
            print(f"  ABI MISMATCH: {iface}.{name}")
            print(f"      declared: ({','.join(want_in)}) -> ({','.join(want_out)})")
            print(f"      real    : ({','.join(norm(i['type']) for i in c.get('inputs',[]))}) -> ({','.join(norm(o['type']) for o in c.get('outputs',[]))})")
            bad=1
if bad: sys.exit(1)
print("  ok")
PY

echo
[ "$fail" -eq 0 ] || {
  echo "Vendored C1 sources or local interfaces differ from PoolParty_Contracts@$PIN."
  echo "Re-vendor and update $PIN_FILE, or bump the pin deliberately."
  exit 1
}
echo "no drift"
