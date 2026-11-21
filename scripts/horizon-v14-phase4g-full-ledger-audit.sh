#!/usr/bin/env bash
set -Eeuo pipefail

# Horizon Core v1.4 - Phase 4G
# Full logical backup + isolated restore + row-count audit + read-only runtime probe.
# Source databases are never targeted by DDL/DML. All creates/restores/settings
# apply only to uniquely named audit-clone databases.

ROOT="$HOME/Beaconchain/horizon-core"
PG_BIN="/c/Program Files/PostgreSQL/18/bin"
PSQL="$PG_BIN/psql.exe"
PG_DUMP="$PG_BIN/pg_dump.exe"
PG_RESTORE="$PG_BIN/pg_restore.exe"
CREATEDB="$PG_BIN/createdb.exe"
BIN="$HOME/horizon-v14-builds/phase4e-verify-20261120_153557/horizon-switch.exe"
EXPECTED_BIN_SHA="90b15079c175add804fb111d361d7b83814ba78316943e51646de5aa9a70961b"
HOST="127.0.0.1"
PORT="5432"
DB_USER="postgres"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$HOME/horizon-v14-backups/phase4g-full-ledger-audit-$STAMP"
DUMP_DIR="$OUT/dumps"
MANIFEST_DIR="$OUT/manifests"
RUNTIME_WORK="$OUT/runtime-workdir"
CLONE_SWITCH="hzn4g_${STAMP//_/}sw"
CLONE_REGISTRY="hzn4g_${STAMP//_/}rg"
CLONE_ARCHIVE="hzn4g_${STAMP//_/}ar"
APP_PORT="18091"

mkdir -p "$DUMP_DIR" "$MANIFEST_DIR" "$RUNTIME_WORK/config"
LOG="$OUT/phase4g-report.txt"
exec > >(tee "$LOG") 2>&1

cleanup() {
  unset PGPASSWORD 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  echo "RESULT=FAIL"
  echo "Source databases were not intentionally modified."
  echo "Any completed backups and audit clones are retained at: $OUT"
  exit 1
}

say() { printf '\n===== %s =====\n' "$1"; }

cd "$ROOT" || fail

say "HORIZON v1.4 PHASE 4G - FULL LEDGER AUDIT + ISOLATED RUNTIME"
echo "Started: $(date -Iseconds)"
echo "Repository: $(pwd)"
echo "Output: $OUT"
echo "PostgreSQL: $HOST:$PORT / client 18.6 expected"
echo "SOURCE DATABASES: horizon_switch, horizon_v14_registry, horizon_v14_archive"
echo "SOURCE WRITE OPERATIONS: NONE"
echo "EXISTING RUNTIME PID 24380: WILL NOT BE STOPPED OR RESTARTED"
echo "DEPLOYMENT: NONE"
echo "BINARY: $BIN"

say "PREFLIGHT"
for f in "$PSQL" "$PG_DUMP" "$PG_RESTORE" "$CREATEDB"; do
  [[ -x "$f" ]] || { echo "Missing PostgreSQL tool: $f"; fail; }
done
[[ -s "$BIN" ]] || { echo "Phase 4E binary not found: $BIN"; fail; }
ACTUAL_BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
echo "Binary SHA256: $ACTUAL_BIN_SHA"
[[ "$ACTUAL_BIN_SHA" == "$EXPECTED_BIN_SHA" ]] || { echo "Binary hash mismatch; refusing to run."; fail; }
"$PG_BIN/pg_dump.exe" --version
"$PG_BIN/pg_restore.exe" --version
"$PG_BIN/pg_isready.exe" -h "$HOST" -p "$PORT"

# Ask once; password is kept in this process environment only and never written to disk.
read -r -s -p "PostgreSQL password for $DB_USER (input hidden): " PGPASSWORD
printf '\n'
[[ -n "$PGPASSWORD" ]] || { echo "An empty password was supplied; use a password-authenticated session."; fail; }
export PGPASSWORD

PSQL_BASE=("$PSQL" -X -w -h "$HOST" -p "$PORT" -U "$DB_USER" -v ON_ERROR_STOP=1 -P pager=off)

say "AUTHENTICATED CONNECTION + SOURCE DATABASE INVENTORY"
DB_INFO="$("${PSQL_BASE[@]}" -d postgres -A -t -F '|' -c \
  "SELECT datname, pg_database_size(datname) FROM pg_database WHERE datname IN ('horizon_switch','horizon_v14_registry','horizon_v14_archive') ORDER BY datname;")" || fail
printf '%s\n' "$DB_INFO"
for db in horizon_switch horizon_v14_registry horizon_v14_archive; do
  grep -q "^${db}|" <<< "$DB_INFO" || { echo "Required source database is missing: $db"; fail; }
done
"${PSQL_BASE[@]}" -d horizon_switch -c \
  "SELECT current_database() AS database, current_user AS db_user, pg_size_pretty(pg_database_size(current_database())) AS size, current_setting('default_transaction_read_only') AS read_only;" || fail

TOTAL_BYTES="$(awk -F'|' '{s += $2} END {printf "%.0f", s}' <<< "$DB_INFO")"
FREE_KB="$(df -Pk "$HOME" | awk 'END {print $4}')"
# Keep at least 2x source DB size plus 5 GiB free for dumps, clones and working space.
NEEDED_KB=$(( (TOTAL_BYTES / 1024) * 2 + 5 * 1024 * 1024 ))
echo "Source DB total bytes: $TOTAL_BYTES"
echo "Free KiB: $FREE_KB"
echo "Required safety reserve KiB: $NEEDED_KB"
(( FREE_KB > NEEDED_KB )) || { echo "Insufficient free space for safe backup + restore."; fail; }

# Refuse any clone-name collision. Do not reuse or overwrite prior audit data.
for clone in "$CLONE_SWITCH" "$CLONE_REGISTRY" "$CLONE_ARCHIVE"; do
  EXISTS="$("${PSQL_BASE[@]}" -d postgres -A -t -c "SELECT count(*) FROM pg_database WHERE datname = '$clone';")" || fail
  [[ "$EXISTS" == "0" ]] || { echo "Clone database already exists: $clone"; fail; }
done

# Exact row-count manifest for all user tables and materialized views.
# ONLY counts physical partition members separately, avoiding partition double-counting.
row_manifest() {
  local db="$1" out="$2"
  "${PSQL_BASE[@]}" -d "$db" -A -t -F '|' > "$out" <<'SQL'
SELECT format(
  'SELECT %L, count(*)::bigint FROM ONLY %I.%I;',
  n.nspname || '.' || c.relname, n.nspname, c.relname
)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p','m')
  AND c.relpersistence <> 't'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND n.nspname NOT LIKE 'pg_temp_%'
ORDER BY n.nspname, c.relname;
\gexec
SQL
  [[ -s "$out" ]] || { echo "No user-table row counts returned for $db"; return 1; }
  LC_ALL=C sort -t'|' -k1,1 "$out" -o "$out"
}

# Backup and restore each known database. pg_dump provides a transactionally
# consistent snapshot of each DB even while the existing service is online.
backup_restore_one() {
  local source="$1" clone="$2"
  local dump="$DUMP_DIR/${source}.dump"
  local pre="$MANIFEST_DIR/${source}.source-before.tsv"
  local post="$MANIFEST_DIR/${source}.source-after-dump.tsv"
  local restored="$MANIFEST_DIR/${source}.clone.tsv"
  local toc="$OUT/${source}.toc.txt"

  say "SOURCE ROW COUNTS BEFORE BACKUP: $source"
  row_manifest "$source" "$pre" || fail
  echo "Tables/views counted: $(wc -l < "$pre" | tr -d ' ')"

  say "FULL LOGICAL BACKUP: $source"
  if ! "$PG_DUMP" -h "$HOST" -p "$PORT" -U "$DB_USER" -w \
    --format=custom --compress=6 --verbose \
    --file="$dump" "$source" 2>"$OUT/${source}.pgdump.log"; then
    echo "pg_dump failed for $source; last log lines:"
    tail -100 "$OUT/${source}.pgdump.log" || true
    fail
  fi
  [[ -s "$dump" ]] || { echo "Backup file is empty: $dump"; fail; }
  sha256sum "$dump" | tee "$OUT/${source}.dump.sha256"
  "$PG_RESTORE" --list "$dump" > "$toc" || fail
  echo "Archive TOC entries: $(wc -l < "$toc" | tr -d ' ')"

  say "RESTORE INTO ISOLATED CLONE: $clone"
  "$CREATEDB" -h "$HOST" -p "$PORT" -U "$DB_USER" -w \
    --template=template0 "$clone" || fail
  if ! "$PG_RESTORE" -h "$HOST" -p "$PORT" -U "$DB_USER" -w \
    --exit-on-error --verbose --no-owner --no-acl \
    --dbname="$clone" "$dump" 2>"$OUT/${source}.pgrestore.log"; then
    echo "pg_restore failed for $clone; last log lines:"
    tail -100 "$OUT/${source}.pgrestore.log" || true
    fail
  fi

  # The clone is explicitly made read-only before the application is pointed at it.
  "${PSQL_BASE[@]}" -d postgres -c \
    "ALTER DATABASE \"$clone\" SET default_transaction_read_only = on;" || fail
  local clone_ro
  clone_ro="$("${PSQL_BASE[@]}" -d "$clone" -A -t -c "SHOW default_transaction_read_only;")" || fail
  echo "Clone default_transaction_read_only: $clone_ro"
  [[ "$clone_ro" == "on" ]] || { echo "Read-only database default was not applied to clone $clone; refusing to run application."; return 1; }

  say "CLONE ROW COUNTS: $clone"
  row_manifest "$clone" "$restored" || fail
  echo "Tables/views counted: $(wc -l < "$restored" | tr -d ' ')"

  say "SOURCE ROW COUNTS AFTER BACKUP: $source"
  row_manifest "$source" "$post" || fail
  if cmp -s "$pre" "$post"; then
    if cmp -s "$pre" "$restored"; then
      echo "ROW_COUNT_COMPARISON=$source: MATCH (source counts stable around dump; clone counts match)"
      echo "$source|ROW_COUNTS_MATCH" >> "$OUT/row-count-status.txt"
    else
      echo "ROW_COUNT_COMPARISON=$source: MISMATCH (restore/count discrepancy; investigate report)"
      echo "$source|ROW_COUNTS_MISMATCH" >> "$OUT/row-count-status.txt"
      return 1
    fi
  else
    echo "ROW_COUNT_COMPARISON=$source: SOURCE COUNTS CHANGED DURING BACKUP WINDOW"
    echo "The pg_dump archive remains a consistent PostgreSQL snapshot; row-count equality is not asserted against the moving source."
    echo "$source|SOURCE_DRIFT_DURING_BACKUP" >> "$OUT/row-count-status.txt"
  fi
}

: > "$OUT/row-count-status.txt"
backup_restore_one horizon_switch "$CLONE_SWITCH" || fail
backup_restore_one horizon_v14_registry "$CLONE_REGISTRY" || fail
backup_restore_one horizon_v14_archive "$CLONE_ARCHIVE" || fail

say "CRITICAL LEDGER TABLE COUNTS IN SWITCH CLONE"
"${PSQL_BASE[@]}" -d "$CLONE_SWITCH" -c \
  "SELECT schemaname, tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY schemaname, tablename;" \
  > "$OUT/switch-clone-table-inventory.txt" || fail
# Print known ledger counts where present; don't fail on schema variants/missing table names.
"${PSQL_BASE[@]}" -d "$CLONE_SWITCH" -A -t -F '|' -c \
  "SELECT format('SELECT %L, count(*) FROM %I.%I;', schemaname||'.'||tablename, schemaname, tablename) FROM pg_tables WHERE tablename IN ('blocks','chain_blocks','chain_txes','transactions') ORDER BY schemaname, tablename;" \
  > "$OUT/critical-count-queries.txt" || fail
# Execute each generated safe SELECT via psql's \gexec.
"${PSQL_BASE[@]}" -d "$CLONE_SWITCH" -A -t -F '|' > "$OUT/critical-ledger-counts.tsv" <<'SQL'
SELECT format(
  'SELECT %L, count(*)::bigint FROM %I.%I;',
  schemaname || '.' || tablename, schemaname, tablename
)
FROM pg_tables
WHERE tablename IN ('blocks','chain_blocks','chain_txes','transactions')
ORDER BY schemaname, tablename;
\gexec
SQL
cat "$OUT/critical-ledger-counts.tsv"

say "ISOLATED READ-ONLY RUNTIME PREPARATION"
# Give the test process an isolated working directory so runtime logs or
# relative-path outputs cannot touch the repository. Copy only the public
# chain configuration required for startup; never copy key/config secrets.
[[ -s "$ROOT/config/chain.json" ]] || { echo "Missing config/chain.json required for isolated runtime."; fail; }
cp "$ROOT/config/chain.json" "$RUNTIME_WORK/config/chain.json"
# Confirm port is free before launching anything.
PORT_BUSY="$(powershell.exe -NoProfile -Command "if (Get-NetTCPConnection -LocalPort $APP_PORT -State Listen -ErrorAction SilentlyContinue) { 'busy' } else { 'free' }" | tr -d '\r')"
[[ "$PORT_BUSY" == "free" ]] || { echo "Isolated test port $APP_PORT is already in use; refusing to start binary."; fail; }

# Snapshot table counts immediately before and after the application probe.
row_manifest "$CLONE_SWITCH" "$MANIFEST_DIR/switch-clone.before-runtime.tsv" || fail

PS_DRIVER="$OUT/phase4g-run-isolated-app.ps1"
cat > "$PS_DRIVER" <<'PS1'
param(
  [Parameter(Mandatory=$true)][string]$Binary,
  [Parameter(Mandatory=$true)][string]$WorkDir,
  [Parameter(Mandatory=$true)][string]$Database,
  [Parameter(Mandatory=$true)][string]$Stdout,
  [Parameter(Mandatory=$true)][string]$Stderr,
  [Parameter(Mandatory=$true)][string]$ResultFile,
  [Parameter(Mandatory=$true)][string]$AppPort
)
$ErrorActionPreference = 'Stop'
$env:DB_ENGINE = 'postgres'
$env:DB_DSN = "host=127.0.0.1 port=5432 user=postgres dbname=$Database sslmode=disable"
$env:SWITCH_PORT = $AppPort
$env:ADMIN_TOKEN = 'PHASE4G-ISOLATED-ONLY-NOT-A-REAL-SECRET'
$env:API_KEY = 'PHASE4G-ISOLATED-ONLY-NOT-A-REAL-SECRET'
$env:GIN_MODE = 'release'
$env:HORIZON_ALLOW_SWITCH_SCHEMA_MIGRATION = 'false'
$env:HORIZON_ALLOW_LICENSE_CHAIN_SCHEMA_MIGRATION = 'false'
$env:HORIZON_ALLOW_LICENSE_CHAIN_GENESIS_BOOTSTRAP = 'false'
$env:SWITCH_DB = ''
$env:DATABASE_URL = ''
$proc = $null
$gateStatus = 0
$getStatus = 0
$portListening = $false
$exitEarly = $false
$exitCode = -999
try {
  $proc = Start-Process -FilePath $Binary -WorkingDirectory $WorkDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
  Start-Sleep -Seconds 18
  $proc.Refresh()
  if ($proc.HasExited) {
    $exitEarly = $true
    $exitCode = $proc.ExitCode
  } else {
    $listener = Get-NetTCPConnection -LocalPort ([int]$AppPort) -State Listen -ErrorAction SilentlyContinue
    $portListening = ($null -ne $listener)
    if ($portListening) {
      try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$AppPort/__phase4g_write_probe")
        $req.Method = 'POST'
        $req.Timeout = 5000
        $req.ContentLength = 0
        $resp = $req.GetResponse()
        $gateStatus = [int]$resp.StatusCode
        $resp.Close()
      } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
          $gateStatus = [int]$_.Exception.Response.StatusCode
          $_.Exception.Response.Close()
        }
      }
      try {
        $req2 = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$AppPort/__phase4g_read_probe")
        $req2.Method = 'GET'
        $req2.Timeout = 5000
        $resp2 = $req2.GetResponse()
        $getStatus = [int]$resp2.StatusCode
        $resp2.Close()
      } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
          $getStatus = [int]$_.Exception.Response.StatusCode
          $_.Exception.Response.Close()
        }
      }
    }
  }
} catch {
  $_ | Out-String | Set-Content -Encoding UTF8 $Stderr -Append
} finally {
  if ($null -ne $proc) {
    $proc.Refresh()
    if (-not $proc.HasExited) {
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      $proc.WaitForExit()
    }
  }
}
@(
  "APP_EXIT_EARLY=$exitEarly"
  "APP_EXIT_CODE=$exitCode"
  "PORT_LISTENING=$portListening"
  "POST_WRITE_PROBE_HTTP=$gateStatus"
  "GET_READ_PROBE_HTTP=$getStatus"
  "APP_PID=$($proc.Id)"
) | Set-Content -Encoding ASCII $ResultFile
if ($exitEarly -or -not $portListening -or $gateStatus -ne 503 -or $getStatus -eq 503) { exit 2 }
exit 0
PS1

APP_OUT="$OUT/runtime-stdout.log"
APP_ERR="$OUT/runtime-stderr.log"
APP_RESULT="$OUT/runtime-probe-result.txt"
WIN_BIN="$(cygpath -w "$BIN")"
WIN_ROOT="$(cygpath -w "$RUNTIME_WORK")"
WIN_APP_OUT="$(cygpath -w "$APP_OUT")"
WIN_APP_ERR="$(cygpath -w "$APP_ERR")"
WIN_APP_RESULT="$(cygpath -w "$APP_RESULT")"
WIN_PSDRIVER="$(cygpath -w "$PS_DRIVER")"

say "RUN PHASE 4E BINARY ONLY AGAINST READ-ONLY CLONE"
if powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PSDRIVER" \
  -Binary "$WIN_BIN" -WorkDir "$WIN_ROOT" -Database "$CLONE_SWITCH" \
  -Stdout "$WIN_APP_OUT" -Stderr "$WIN_APP_ERR" \
  -ResultFile "$WIN_APP_RESULT" -AppPort "$APP_PORT"; then
  cat "$APP_RESULT"
  echo "HTTP_WRITE_GATE=PASS (POST returned 503)"
  echo "HTTP_READ_METHOD=PASS (GET was not blocked with 503)"
else
  [[ -f "$APP_RESULT" ]] && cat "$APP_RESULT" || true
  echo "===== RUNTIME STDOUT (LAST 100 LINES) ====="
  [[ -f "$APP_OUT" ]] && tail -100 "$APP_OUT" || true
  echo "===== RUNTIME STDERR (LAST 100 LINES) ====="
  [[ -f "$APP_ERR" ]] && tail -100 "$APP_ERR" || true
  echo "Runtime probe did not meet all pass conditions; backups and clones remain available."
  fail
fi

say "VERIFY CLONE DATA UNCHANGED BY RUNTIME"
row_manifest "$CLONE_SWITCH" "$MANIFEST_DIR/switch-clone.after-runtime.tsv" || fail
if cmp -s "$MANIFEST_DIR/switch-clone.before-runtime.tsv" "$MANIFEST_DIR/switch-clone.after-runtime.tsv"; then
  echo "CLONE_ROW_COUNTS_BEFORE_AFTER=IDENTICAL"
else
  echo "CLONE_ROW_COUNTS_BEFORE_AFTER=CHANGED"
  diff -u "$MANIFEST_DIR/switch-clone.before-runtime.tsv" "$MANIFEST_DIR/switch-clone.after-runtime.tsv" | head -100 || true
  fail
fi

say "FINAL ARTIFACT HASHES"
(
  cd "$DUMP_DIR"
  sha256sum *.dump > "$OUT/all-dumps.sha256"
)
cat "$OUT/all-dumps.sha256"
echo "Binary SHA256: $ACTUAL_BIN_SHA"
echo ""
echo "Source DBs: horizon_switch, horizon_v14_registry, horizon_v14_archive"
echo "Clone DBs: $CLONE_SWITCH, $CLONE_REGISTRY, $CLONE_ARCHIVE"
echo "Backup directory: $OUT"
echo "pg_dump/pg_restore logs: $OUT/*.pgdump.log ; $OUT/*.pgrestore.log"
echo "Report: $LOG"
echo "Runtime workdir (isolated): $RUNTIME_WORK"
echo "Runtime logs: $APP_OUT ; $APP_ERR"
echo "Row count status:"
cat "$OUT/row-count-status.txt"
echo ""
echo "RESULT=PASS"
echo "Meaning: all three source databases were logically dumped and restored to separate clones; the Phase 4E binary was probed only against the read-only switch clone; POST write was rejected with HTTP 503; GET was not rejected with 503; clone row counts remained unchanged."
echo "No source database DDL/DML, no deployment, and no stop/restart of existing PID 24380 was performed."
