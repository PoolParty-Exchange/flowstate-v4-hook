#!/usr/bin/env bash
# JUP-567. The fork suite compiles VENDORED copies of the C1 contracts. Left
# unchecked they drift: before this gate they were 327 lines behind, so every
# fork test "passing" was passing against contracts we do not ship. Drift is
# silent because a stale copy still compiles and still goes green.
set -euo pipefail
PIN_FILE="test/real/poolparty/.vendored-from"
CONTRACTS_REPO="${CONTRACTS_REPO:-https://github.com/PoolParty-Exchange/PoolParty_Contracts.git}"
[ -f "$PIN_FILE" ] || { echo "missing $PIN_FILE"; exit 1; }
PIN="$(tr -d '[:space:]' < "$PIN_FILE")"
echo "vendored copies pinned to PoolParty_Contracts $PIN"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git clone -q --filter=blob:none --no-checkout "$CONTRACTS_REPO" "$TMP/c"
git -C "$TMP/c" fetch -q origin "$PIN" --depth 1
drift=0
while IFS= read -r f; do
  rel="${f#test/real/poolparty/}"
  if git -C "$TMP/c" show "$PIN:contracts/$rel" > "$TMP/theirs" 2>/dev/null; then
    if ! diff -q "$f" "$TMP/theirs" >/dev/null; then echo "DRIFT: $rel"; drift=1; fi
  else
    echo "NOT IN CONTRACTS AT PIN (hook-local, allowed): $rel"
  fi
done < <(find test/real/poolparty -name '*.sol')
[ "$drift" -eq 0 ] || { echo; echo "Vendored C1 sources differ from PoolParty_Contracts@$PIN."; echo "Re-vendor and update $PIN_FILE, or bump the pin deliberately."; exit 1; }
echo "no drift"
