#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$HOME/Beaconchain/horizon-core"
BUILD_DIR="$HOME/horizon-v14-builds/phase4e-verify-20261120_153557"
BIN="$BUILD_DIR/horizon-switch.exe"
STAMP="$(date +%Y%m%d_%H%M%S)"
SMOKE_DIR="$HOME/horizon-v14-smoke/phase4f-${STAMP}"
DB_FILE="$SMOKE_DIR/empty-isolated.db"
LOG="$SMOKE_DIR/startup.log"

fail() {
  echo "RESULT=FAIL"
  echo "No production database, source files, or existing process was intentionally changed."
  exit 1
}

mkdir -p "$SMOKE_DIR"
cd "$ROOT" || fail

printf '%s\n' '===== HORIZON v1.4 PHASE 4F — ISOLATED STARTUP SMOKE ====='
echo "Started: $(date -Iseconds)"
echo "Binary: $BIN"
echo "Isolated DB: $DB_FILE"
echo "Log: $LOG"
echo "PRODUCTION DATABASE: NOT USED"
echo "SOURCE MODIFICATION: NONE"
echo "EXISTING RUNTIME RESTART: NONE"

[[ -s "$BIN" ]] || { echo "Phase 4E binary missing or empty"; fail; }
[[ ! -e "$DB_FILE" ]] || { echo "Refusing to reuse an existing smoke DB"; fail; }
command -v timeout >/dev/null 2>&1 || {
  echo "GNU timeout is required in Git Bash; no process was started."
  fail
}
command -v cygpath >/dev/null 2>&1 || {
  echo "cygpath is required to pass a Windows-native SQLite path; no process was started."
  fail
}
BIN_WIN="$(cygpath -w "$BIN")"
DB_FILE_WIN="$(cygpath -w "$DB_FILE")"

# Require the executable to use a fresh local SQLite file and disable all
# opt-in schema/genesis migration flags. The application should fail closed
# because the isolated database has none of the required Horizon tables.
set +e
timeout 20s env \
  DB_ENGINE=sqlite \
  DB_DSN= \
  DATABASE_URL= \
  SWITCH_DB="$DB_FILE_WIN" \
  SWITCH_PORT=18094 \
  ADMIN_TOKEN=phase4f-isolated-smoke-only-not-a-production-secret \
  API_KEY= \
  HORIZON_ALLOW_SWITCH_SCHEMA_MIGRATION= \
  HORIZON_ALLOW_LICENSE_CHAIN_SCHEMA_MIGRATION= \
  HORIZON_ALLOW_LICENSE_CHAIN_GENESIS_BOOTSTRAP= \
  "$BIN_WIN" >"$LOG" 2>&1
RC=$?
set -e

echo "PROCESS_EXIT_CODE=$RC"
echo "AUTH: dummy isolated ADMIN_TOKEN supplied; no production token used"

if [[ "$RC" -eq 124 || "$RC" -eq 137 ]]; then
  echo "FAIL: isolated process did not fail closed within 20 seconds; timeout stopped only this smoke-test process."
  sed -n '1,180p' "$LOG" || true
  fail
fi

if [[ "$RC" -eq 0 ]]; then
  echo "FAIL: binary exited successfully against an empty schema; expected fail-closed startup."
  sed -n '1,180p' "$LOG" || true
  fail
fi

if grep -Eiq 'ADMIN_TOKEN .* must be set|API_KEY .* must be set|Refusing to start with open auth' "$LOG"; then
  echo "FAIL: authentication precondition was not satisfied; inspect the environment variable handling."
  sed -n '1,180p' "$LOG" || true
  fail
fi

if ! grep -Eiq 'schema preflight failed|missing required tables|missing tables' "$LOG"; then
  echo "FAIL: process exited nonzero, but expected schema-preflight failure was not found."
  sed -n '1,180p' "$LOG" || true
  fail
fi

if grep -Eiq 'genesis (block )?(created|bootstrapped)|created (a )?genesis|genesis bootstrap succeeded' "$LOG"; then
  echo "FAIL: unexpected Genesis creation/bootstrap message found."
  sed -n '1,180p' "$LOG" || true
  fail
fi

echo "===== STARTUP LOG (FIRST 100 LINES) ====="
sed -n '1,100p' "$LOG"
echo "===== BINARY SHA256 ====="
sha256sum "$BIN"
cat <<REPORT

===== PHASE 4F SUMMARY =====
RESULT=PASS
Meaning: isolated empty SQLite database was rejected by startup schema preflight.
Genesis bootstrap success message: NOT FOUND
Production database: NOT used
Source files: not modified
Existing runtime: not restarted or stopped
Smoke directory: $SMOKE_DIR
REPORT
