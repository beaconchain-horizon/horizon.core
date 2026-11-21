#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$HOME/Beaconchain/horizon-core"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$HOME/horizon-v14-builds/phase4e-verify-${STAMP}"
LOG="$OUT/phase4e-report.txt"

mkdir -p "$OUT"
exec > >(tee "$LOG") 2>&1

fail() { echo "RESULT=FAIL"; echo "No deployment or runtime restart was performed."; exit 1; }

cd "$ROOT" || fail

echo "===== HORIZON v1.4 PHASE 4E — VERIFY + ISOLATED BUILD ====="
echo "Started: $(date -Iseconds)"
echo "Repository: $(pwd)"
echo "Output: $OUT"
echo "DATABASE ACCESS: NONE"
echo "RUNTIME RESTART: NONE"
echo "DEPLOYMENT: NONE"

echo "===== TOOLCHAIN ====="
go version
[[ "$(go env GOVERSION)" == "go1.24.4" ]] || { echo "Expected Go 1.24.4"; fail; }
export GOTOOLCHAIN=local

# Confirm the recovery gate and its tests are present before building.
for f in cmd/switch/runtime_write_gate.go cmd/switch/runtime_write_gate_test.go cmd/switch/switch.go cmd/switch/customer.go; do
  [[ -f "$f" ]] || { echo "Missing required file: $f"; fail; }
done

echo "===== LICENSE/AUDIT FINDINGS (SOURCE-LEVEL) ====="
echo "checkLicenseNow body: reads active license and updates in-memory enforcement state."
echo "addAudit body: appends to in-memory auditLog; no database call in the shown implementation."
echo "Renewal handlers contain GORM writes; HTTP recovery middleware rejects mutation methods while runtimeWritesAllowed=false."
echo "This is not proof against every possible internal DB write path."

echo "===== TARGETED TESTS ====="
go test -count=1 ./cmd/switch ./internal/chain ./internal/industrial ./internal/tenant ./internal/crypto ./internal/crypto/wots ./internal/merkle || fail

echo "===== ISOLATED BUILD ====="
go build -trimpath -buildvcs=false -o "$OUT/horizon-switch.exe" ./cmd/switch || fail

[[ -s "$OUT/horizon-switch.exe" ]] || { echo "Build output missing or empty"; fail; }
echo "===== BINARY VERIFICATION ====="
sha256sum "$OUT/horizon-switch.exe"
go version -m "$OUT/horizon-switch.exe" | sed -n '1,24p'

cat <<REPORT

===== PHASE 4E SUMMARY =====
RESULT=PASS
Build: $OUT/horizon-switch.exe
Tests: 7 targeted packages passed
Go: $(go version)
Database access: NONE
Runtime restart: NONE
Deployment: NONE
Production database and existing process were not touched.
REPORT
