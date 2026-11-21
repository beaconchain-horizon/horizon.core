#!/usr/bin/env bash
set -Eeuo pipefail

# Horizon Core v1.4 - Phase 4I
# Verify the already-created canonical chain identity and design-only signature
# policy without overwriting either file; build with pinned Go and test ONLY
# against the existing Phase 4G read-only clone. No production DB writes,
# no key generation, no Genesis/ledger edits, no deploy.

ROOT="$HOME/Beaconchain/horizon-core"
PG_BIN="/c/Program Files/PostgreSQL/18/bin"
PSQL="$PG_BIN/psql.exe"
CLONE_SWITCH="hzn4g_20261120155646sw"
LOCK_DIR="$HOME/horizon-v14-protocol/phase4h-separation-lock-20261120_165149"
EXPECTED_CHAIN="horizon-core-v1.4"
EXPECTED_GENESIS="8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"
EXPECTED_GO="go1.24.4"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$HOME/horizon-v14-builds/phase4i-canonical-runtime-$STAMP"
WORK="$OUT/runtime-workdir"
CONFIG="$ROOT/config/chain.json"
POLICY="$ROOT/config/signature-policy.v1.4.json"
EXPECTED_CONFIG_SHA="46a8a7bca06b6fe87e5b5c981f0ec606e7b43fef5c963b8c330d2e71e44bdbbc"
EXPECTED_POLICY_SHA="4ac5a8c679b6b67c26110afbb2495d5e9cdda853bc579a5d531d7bcda2074889"
APP_PID=""

mkdir -p "$OUT" "$WORK"
LOG="$OUT/phase4i-report.txt"
exec > >(tee "$LOG") 2>&1

say() { printf '\n===== %s =====\n' "$1"; }
fail() { echo "RESULT=FAIL"; echo "Artifacts retained: $OUT"; echo "Production DB/runtime were not intentionally modified."; exit 1; }

cleanup() {
  # Only stop the exact isolated process launched by this script.
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

say "HORIZON v1.4 PHASE 4I v4 - VERIFY EXISTING LOCKS + READ-ONLY RUNTIME"
echo "Started: $(date -Iseconds)"
echo "Repository: $ROOT"
echo "Output: $OUT"
echo "Existing read-only clone: $CLONE_SWITCH"
echo "Go must remain: $EXPECTED_GO"
echo "Production DB write: NONE"
echo "Private key generation/reading: NONE"
echo "Existing PID 24380: WILL NOT BE STOPPED OR RESTARTED"
echo "Deployment: NONE"

[[ -d "$ROOT/.git" ]] || { echo "Repository not found: $ROOT"; fail; }
[[ -s "$LOCK_DIR/protocol-lock.json" ]] || { echo "Phase 4H protocol lock not found"; fail; }
[[ -s "$LOCK_DIR/SHA256SUMS" ]] || { echo "Phase 4H checksum manifest not found"; fail; }
command -v go >/dev/null 2>&1 || fail
GO_NOW="$(go version | awk '{print $3}')"
echo "Go: $(go version)"
[[ "$GO_NOW" == "$EXPECTED_GO" ]] || { echo "Wrong Go toolchain; refusing to change toolchain"; fail; }
[[ -x "$PSQL" ]] || { echo "psql.exe not found"; fail; }

say "VERIFY PHASE 4H LOCK"
(
  cd "$LOCK_DIR"
  # phase4h-report.txt is the live tee log. Phase 4H generated SHA256SUMS
  # before printing its final summary, so that one append-only log naturally
  # changed afterward. Verify every immutable artifact and exclude only it.
  awk '$2 !~ /(^|\/)phase4h-report\.txt$/ { print }' SHA256SUMS | sha256sum -c -
) || fail
if [[ ! -s "$LOCK_DIR/phase4h-report.txt" ]]; then
  echo "Phase 4H execution report is missing."
  fail
fi

say "VERIFY CANONICAL PRIMARY CHAIN CONFIG (NO OVERWRITE)"
[[ -s "$CONFIG" ]] || { echo "Canonical config missing: $CONFIG"; fail; }
CONFIG_SHA="$(sha256sum "$CONFIG" | awk '{print $1}')"
echo "chain.json SHA256=$CONFIG_SHA"
[[ "$CONFIG_SHA" == "$EXPECTED_CONFIG_SHA" ]] || { echo "Existing chain.json differs from the reviewed canonical artifact; refusing to continue."; fail; }
grep -Fq "$EXPECTED_CHAIN" "$CONFIG" || fail
grep -Fq "$EXPECTED_GENESIS" "$CONFIG" || fail
sha256sum "$CONFIG" | tee "$OUT/chain-config.sha256"

say "VERIFY EXISTING VERSIONED SIGNATURE POLICY (DESIGN ONLY; NO OVERWRITE)"
[[ -s "$POLICY" ]] || { echo "Signature policy missing: $POLICY"; fail; }
POLICY_SHA="$(sha256sum "$POLICY" | awk '{print $1}')"
echo "signature-policy.v1.4.json SHA256=$POLICY_SHA"
[[ "$POLICY_SHA" == "$EXPECTED_POLICY_SHA" ]] || { echo "Existing signature policy differs from reviewed design-only artifact; refusing to continue."; fail; }
grep -Fq '"activation_state": "DESIGN_ONLY_NOT_ACTIVE"' "$POLICY" || fail
grep -Fq '"status": "NOT_ACTIVE"' "$POLICY" || fail
grep -Fq '"key_reuse": "FORBIDDEN"' "$POLICY" || fail
sha256sum "$POLICY" | tee "$OUT/signature-policy.sha256"

# Put configuration in the app's conventional config/ path and also at the
# workdir root for older loader variants. These are test-workdir copies only.
mkdir -p "$WORK/config"
cp "$CONFIG" "$WORK/config/chain.json"
cp "$CONFIG" "$WORK/chain.json"
cp "$POLICY" "$WORK/config/signature-policy.v1.4.json"
cp "$POLICY" "$WORK/signature-policy.v1.4.json"
echo "Existing canonical config and design-only signature policy verified; no source config overwritten."

say "SOURCE CONFIG LOADER REFERENCES"
grep -Rni --include='*.go' --exclude-dir=vendor -E 'initChainConfig|chain\.json|type ChainConfig struct|json:"chain_id"' "$ROOT/cmd" "$ROOT/internal" 2>/dev/null \
  | head -100 | tee "$OUT/chain-config-source-references.txt" || true

say "TARGETED TESTS"
(
  cd "$ROOT"
  go test -count=1 ./cmd/switch ./internal/chain ./internal/industrial ./internal/tenant ./internal/crypto ./internal/crypto/wots ./internal/merkle
) || fail

say "ISOLATED BUILD"
BIN="$OUT/horizon-switch.exe"
(
  cd "$ROOT"
  go build -trimpath -o "$BIN" ./cmd/switch
) || fail
[[ -s "$BIN" ]] || fail
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
echo "BINARY_SHA256=$BIN_SHA"
go version -m "$BIN" | sed -n '1,35p' | tee "$OUT/binary-build-info.txt"

say "READ-ONLY CLONE PREFLIGHT"
read -r -s -p "PostgreSQL password for postgres (input hidden): " PGPASSWORD
printf '\n'
[[ -n "$PGPASSWORD" ]] || fail
export PGPASSWORD
PSQL_BASE=("$PSQL" -X -w -h 127.0.0.1 -p 5432 -U postgres -v ON_ERROR_STOP=1 -P pager=off)
EXISTS="$("${PSQL_BASE[@]}" -d postgres -A -t -c "SELECT count(*) FROM pg_database WHERE datname='$CLONE_SWITCH';")" || fail
[[ "$EXISTS" == "1" ]] || { echo "Phase 4G switch clone missing"; fail; }
RO="$("${PSQL_BASE[@]}" -d "$CLONE_SWITCH" -A -t -c "SHOW default_transaction_read_only;")" || fail
echo "$CLONE_SWITCH default_transaction_read_only=$RO"
[[ "$RO" == "on" ]] || { echo "Clone is not read-only; refusing runtime probe"; fail; }

row_manifest() {
  local db="$1" dest="$2" sql="$OUT/row-manifest.sql"
  cat > "$sql" <<'SQL'
SELECT format('SELECT %L, count(*)::bigint FROM %I.%I;', schemaname||'.'||tablename, schemaname, tablename)
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog','information_schema')
ORDER BY schemaname, tablename;
\gexec
SQL
  "${PSQL_BASE[@]}" -d "$db" -A -t -F '|' -f "$sql" > "$dest" || return 1
}
row_manifest "$CLONE_SWITCH" "$OUT/clone-before.tsv" || fail

say "ISOLATED RUNTIME STARTUP + HTTP GATE PROBE"
PORT="18149"
PORT_FREE="$(powershell.exe -NoProfile -Command "if (Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue) {'busy'} else {'free'}" | tr -d '\r')"
[[ "$PORT_FREE" == "free" ]] || { echo "Test port $PORT is busy"; fail; }
STDOUT="$OUT/runtime-stdout.log"
STDERR="$OUT/runtime-stderr.log"
RESULT="$OUT/runtime-probe-result.txt"
WIN_BIN="$(cygpath -w "$BIN")"
WIN_WORK="$(cygpath -w "$WORK")"
WIN_STDOUT="$(cygpath -w "$STDOUT")"
WIN_STDERR="$(cygpath -w "$STDERR")"
WIN_RESULT="$(cygpath -w "$RESULT")"

cat > "$OUT/run-probe.ps1" <<'PS1'
param([string]$Binary,[string]$WorkDir,[string]$Database,[string]$Stdout,[string]$Stderr,[string]$ResultFile,[int]$AppPort)
$ErrorActionPreference='Stop'
$env:DB_ENGINE='postgres'
$env:DB_DSN="host=127.0.0.1 port=5432 user=postgres dbname=$Database sslmode=disable options='-c default_transaction_read_only=on'"
$env:PGOPTIONS='-c default_transaction_read_only=on'
$env:SWITCH_PORT=[string]$AppPort
$env:ADMIN_TOKEN='PHASE4I-ISOLATED-ONLY-NOT-A-REAL-SECRET'
$env:API_KEY='PHASE4I-ISOLATED-ONLY-NOT-A-REAL-SECRET'
$env:GIN_MODE='release'
$env:HORIZON_ALLOW_SWITCH_SCHEMA_MIGRATION='false'
$env:HORIZON_ALLOW_LICENSE_CHAIN_SCHEMA_MIGRATION='false'
$env:HORIZON_ALLOW_LICENSE_CHAIN_GENESIS_BOOTSTRAP='false'
$env:SWITCH_DB=''
$env:DATABASE_URL=''
$p=$null; $post=0; $get=0; $listen=$false; $early=$false; $exit=-999
try {
  $p=Start-Process -FilePath $Binary -WorkingDirectory $WorkDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
  Start-Sleep -Seconds 22
  $p.Refresh()
  if($p.HasExited){$early=$true;$exit=$p.ExitCode}
  else {
    $listen=($null -ne (Get-NetTCPConnection -LocalPort $AppPort -State Listen -ErrorAction SilentlyContinue))
    if($listen){
      try{$r=Invoke-WebRequest -Uri "http://127.0.0.1:$AppPort/__phase4i_write_probe" -Method POST -TimeoutSec 5 -UseBasicParsing;$post=[int]$r.StatusCode}
      catch{if($_.Exception.Response){$post=[int]$_.Exception.Response.StatusCode}}
      try{$r=Invoke-WebRequest -Uri "http://127.0.0.1:$AppPort/__phase4i_read_probe" -Method GET -TimeoutSec 5 -UseBasicParsing;$get=[int]$r.StatusCode}
      catch{if($_.Exception.Response){$get=[int]$_.Exception.Response.StatusCode}}
    }
  }
} catch { $_ | Out-String | Add-Content -Path $Stderr }
finally {
  if($null -ne $p){$p.Refresh();if(-not $p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue;$p.WaitForExit()}}
}
@("APP_EXIT_EARLY=$early","APP_EXIT_CODE=$exit","PORT_LISTENING=$listen","POST_WRITE_PROBE_HTTP=$post","GET_READ_PROBE_HTTP=$get","APP_PID=$($p.Id)") | Set-Content -Encoding ASCII $ResultFile
if($early -or -not $listen -or $post -ne 503 -or $get -eq 503){exit 2}
exit 0
PS1
WIN_DRIVER="$(cygpath -w "$OUT/run-probe.ps1")"
if ! powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_DRIVER" \
  -Binary "$WIN_BIN" -WorkDir "$WIN_WORK" -Database "$CLONE_SWITCH" \
  -Stdout "$WIN_STDOUT" -Stderr "$WIN_STDERR" -ResultFile "$WIN_RESULT" -AppPort "$PORT"; then
  [[ -f "$RESULT" ]] && cat "$RESULT" || true
  echo "===== RUNTIME STDOUT ====="
  [[ -f "$STDOUT" ]] && tail -100 "$STDOUT" || true
  echo "===== RUNTIME STDERR ====="
  [[ -f "$STDERR" ]] && tail -100 "$STDERR" || true
  fail
fi
cat "$RESULT"

say "VERIFY CLONE UNCHANGED"
row_manifest "$CLONE_SWITCH" "$OUT/clone-after.tsv" || fail
if cmp -s "$OUT/clone-before.tsv" "$OUT/clone-after.tsv"; then
  echo "CLONE_ROW_COUNTS_BEFORE_AFTER=IDENTICAL"
else
  echo "CLONE_ROW_COUNTS_BEFORE_AFTER=CHANGED"
  diff -u "$OUT/clone-before.tsv" "$OUT/clone-after.tsv" | head -100 || true
  fail
fi

say "FINAL ARTIFACTS"
(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
echo "Canonical config (pre-existing; verified, not changed): $CONFIG"
echo "Signature policy (pre-existing; verified, not changed): $POLICY"
echo "Build: $BIN"
echo "Binary SHA256: $BIN_SHA"
echo "Report: $LOG"
echo "Artifacts: $OUT"
echo "SOURCE DB WRITE: NONE"
echo "PRODUCTION RUNTIME RESTART: NONE"
echo "DEPLOYMENT: NONE"
echo "WOTS+/XMSS: DESIGN ONLY; NOT ACTIVATED"
echo "RESULT=PASS"
echo "Meaning: pre-existing canonical primary identity and design-only signature policy passed exact SHA256 verification without overwrite; targeted tests and isolated build passed; runtime probe used the Phase 4G read-only clone; HTTP write probe returned 503; clone row counts remained identical. This does NOT implement or activate PQ signatures and does NOT cryptographically validate all historical blocks."
