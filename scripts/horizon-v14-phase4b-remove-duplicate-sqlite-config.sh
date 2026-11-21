#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: run this script from inside horizon-core"
  exit 1
}
cd "$ROOT"

TARGET="cmd/switch/switch.go"
if [ ! -f "$TARGET" ]; then
  echo "ERROR: missing $TARGET"
  exit 1
fi

GO_VERSION="$(go version)"
if [ "$GO_VERSION" != "go version go1.24.4 windows/amd64" ]; then
  echo "ERROR: expected go1.24.4 windows/amd64; found: $GO_VERSION"
  exit 1
fi

COUNT="$(grep -cF 'if err := configureSQLite(db); err != nil {' "$TARGET" || true)"
if [ "$COUNT" != "1" ]; then
  echo "ERROR: expected exactly one redundant configureSQLite block in $TARGET; found $COUNT"
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$HOME/horizon-v14-backups/phase4b-remove-duplicate-sqlite-config-$STAMP"
mkdir -p "$BACKUP/source-before/cmd/switch"
cp -p "$TARGET" "$BACKUP/source-before/$TARGET"
sha256sum "$BACKUP/source-before/$TARGET" | tee "$BACKUP/source-before.sha256"

restore_target() {
  cp -p "$BACKUP/source-before/$TARGET" "$TARGET"
  echo "RESTORE=COMPLETED"
}
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "PATCH/TEST FAILED (exit=$rc)"; restore_target; fi' EXIT

echo "===== REMOVE REDUNDANT SQLITE CONFIGURATION CALL ====="
# openDB() already configures SQLite in its SQLite branch. The call in
# switch.go repeats all PRAGMAs and pool settings for SQLite. The dialect
# guard makes it a no-op for PostgreSQL, but it is redundant for SQLite.
sed -i '/if err := configureSQLite(db); err != nil {/,/^[[:space:]]*}/d' "$TARGET"
gofmt -w "$TARGET"

if grep -qF 'configureSQLite(db)' "$TARGET"; then
  echo "ERROR: duplicate configureSQLite call remains in switch.go"
  exit 1
fi
if ! grep -qF 'if err := configureSQLite(db); err != nil {' cmd/switch/db_open.go; then
  echo "ERROR: expected SQLite configuration in openDB() is missing"
  exit 1
fi

echo "PASS: SQLite is configured only in openDB(); PostgreSQL remains protected by dialect guard"

echo "===== DIFF CHECK ====="
git diff --check

echo "===== TARGETED SWITCH TEST ====="
go test -count=1 -timeout=180s ./cmd/switch

echo "===== PATCH SUMMARY ====="
git diff -- "$TARGET"

echo "RESULT=PASS"
echo "BACKUP=$BACKUP"
trap - EXIT
