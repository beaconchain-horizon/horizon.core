#!/usr/bin/env bash
set -Eeuo pipefail

# Horizon Core v1.4 - Phase 4I
# Materialize the already-locked primary chain identity as runtime config,
# record a versioned signature policy, build with the pinned Go toolchain,
# and test ONLY against the existing Phase 4G read-only clone.
# No production DB writes, no key generation, no Genesis/ledger edits, no deploy.

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
CREATED_CONFIG=0
CREATED_POLICY=0
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

say "HORIZON v1.4 PHASE 4I - CANONICAL CONFIG + READ-ONLY RUNTIME"
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
  sha256sum -c SHA256SUMS
) || fail

say "CANONICAL PRIMARY CHAIN CONFIG"
mkdir -p "$ROOT/config"
if [[ -e "$CONFIG" ]]; then
  echo "Existing config/chain.json found; refusing to overwrite it."
  if grep -Fq "$EXPECTED_CHAIN" "$CONFIG" && grep -Fq "$EXPECTED_GENESIS" "$CONFIG"; then
    echo "Existing primary config contains both locked identifiers."
  else
    echo "Existing config does not match locked v1.4 identity. Manual reconciliation required."
    fail
  fi
else
  cat > "$CONFIG" <<JSON
{
  "chain_id": "$EXPECTED_CHAIN",
  "network_name": "Horizon Core v1.4",
  "version": "1.4",
  "genesis_hash": "$EXPECTED_GENESIS",
  "genesis_timestamp_utc": "2026-10-31T18:43:01.8552524Z",
  "description": "Locked primary Horizon Core v1.4 protocol identity. Historical ledger bytes and signatures are immutable."
}
JSON
  CREATED_CONFIG=1
  echo "Created: $CONFIG"
fi

if ! grep -Fq "$EXPECTED_CHAIN" "$CONFIG" || ! grep -Fq "$EXPECTED_GENESIS" "$CONFIG"; then
  echo "Canonical config verification failed"
  fail
fi
sha256sum "$CONFIG" | tee "$OUT/chain-config.sha256"
cp "$CONFIG" "$WORK/chain.json"

say "VERSIONED SIGNATURE POLICY (NOT AN ACTIVATION)"
if [[ -e "$POLICY" ]]; then
  echo "Existing signature policy found; refusing to overwrite: $POLICY"
  fail
fi
cat > "$POLICY" <<'JSON'
{
  "document_type": "Horizon Core v1.4 signature policy",
  "protocol_version": "1.4",
  "activation_state": "DESIGN_ONLY_NOT_ACTIVE",
  "historical_blocks": {
    "algorithm": "ECDSA-secp256k1",
    "verification": "preserve_existing_signature_encoding_and_keys",
    "rewrite_or_resign": false
  },
  "future_block_extension": {
    "mode": "HYBRID_DUAL_SIGNATURE_PROPOSED",
    "legacy_signature": "ECDSA-secp256k1",
    "post_quantum_signature": "SLH-DSA-FIPS205",
    "slh_dsa_parameter_set": "NOT_SELECTED_PENDING_SECURITY_AND_PERFORMANCE_REVIEW",
    "require_both_signatures": false,
    "activation_height": null,
    "authority_transition": "REQUIRES_EXPLICIT_CHECKPOINT_SIGNED_BY_CURRENT_AUTHORITY"
  },
  "wots_plus": {
    "status": "NOT_ACTIVE",
    "role": "ONE_TIME_SIGNATURE_PRIMITIVE_ONLY",
    "allowed_profile": "XMSS_OR_XMSS_MT_WITH_RFC8391_STATE_AND_AUTHENTICATION_PATH",
    "key_reuse": "FORBIDDEN",
    "persistent_index_and_rollback_protection": "REQUIRED_BEFORE_ANY_ACTIVATION"
  },
  "network_separation": {
    "secondary_network": "SEPARATE_ARCHIVE_ONLY_UNTIL_CHAIN_ID_GENESIS_AND_SIGNATURE_PROFILE_ARE_PROVEN",
    "cross_network_merge": false,
    "cross_network_transaction_replay": false
  }
}
JSON
CREATED_POLICY=1
sha256sum "$POLICY" | tee "$OUT/signature-policy.sha256"
cp "$POLICY" "$WORK/signature-policy.v1.4.json"

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
echo "Canonical config: $CONFIG"
echo "Signature policy: $POLICY"
echo "Build: $BIN"
echo "Binary SHA256: $BIN_SHA"
echo "Report: $LOG"
echo "Artifacts: $OUT"
echo "SOURCE DB WRITE: NONE"
echo "PRODUCTION RUNTIME RESTART: NONE"
echo "DEPLOYMENT: NONE"
echo "WOTS+: NOT ACTIVATED; SLH-DSA: POLICY PROPOSED ONLY"
echo "RESULT=PASS"
echo "Meaning: canonical primary identity config exists; targeted tests and isolated build passed; binary started only against the Phase 4G read-only clone; HTTP write probe returned 503; clone row counts remained identical. This does NOT implement or activate PQ signatures and does NOT cryptographically validate all historical blocks."
