#!/usr/bin/env bash
# verify-authority.sh — READ-ONLY verification
set -euo pipefail

GENESIS_EXPECTED="${1:-8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603}"
AUTHORITY_EXPECTED="${2:-}"

fail=0; pass=0
check() {
  local name="$1" cond="$2" detail="${3:-}"
  if eval "$cond"; then
    printf "  [PASS] %s %s\n" "$name" "$detail"; pass=$((pass+1))
  else
    printf "  [FAIL] %s %s\n" "$name" "$detail"; fail=$((fail+1))
  fi
}

echo "=== Horizon Authority — READ-ONLY VERIFY ==="

GENESIS_FILE=""
for f in GENESIS.json data/genesis.json genesis/GENESIS.json; do
  [[ -f "$f" ]] && { GENESIS_FILE="$f"; break; }
done
if [[ -z "$GENESIS_FILE" ]]; then
  echo "  [SKIP] no GENESIS file found"
elif command -v jq >/dev/null; then
  echo "  file: $GENESIS_FILE"
  ACTUAL=$(jq -r '.genesis_hash // .hash // empty' "$GENESIS_FILE")
  check "genesis_hash" "[[ \"$ACTUAL\" == \"$GENESIS_EXPECTED\" ]]" "($ACTUAL)"
fi

if [[ -n "$AUTHORITY_EXPECTED" ]]; then
  LEN=${#AUTHORITY_EXPECTED}
  echo "  authority length: $LEN hex chars"
  case $LEN in
    128) echo "    -> 64 bytes (standard ECDSA R||S)" ;;
    130) echo "    -> 65 bytes (R||S||recovery_id — UNUSUAL)" ;;
    64)  echo "    -> 32 bytes (too short)" ;;
    *)   echo "    -> non-standard length" ;;
  esac
fi

echo "=== RESULT ==="
echo "  passed: $pass"; echo "  failed: $fail"
[[ "$fail" -eq 0 ]] && echo "  status: OK (format only)"
exit $(( fail > 0 ? 1 : 0 ))
