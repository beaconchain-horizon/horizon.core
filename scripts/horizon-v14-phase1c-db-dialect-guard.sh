#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: run this script from inside horizon-core repository" >&2
  exit 1
}
cd "$ROOT"

DB_FILE="cmd/switch/db.go"
TEST_FILE="cmd/switch/db_dialect_guard_test.go"
CHAIN_FILE="cmd/switch/license_chain.go"
EXISTING_TEST="cmd/switch/license_chain_genesis_guard_test.go"

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$HOME/horizon-v14-backups/phase1c-db-dialect-$STAMP"
mkdir -p "$BACKUP_DIR"
REPORT="$BACKUP_DIR/phase1c-report.txt"
exec > >(tee "$REPORT") 2>&1

rollback() {
  local rc=$?
  if [[ ${PATCH_APPLIED:-0} -eq 1 && $rc -ne 0 ]]; then
    echo "TEST/VALIDATION FAILED: restoring only files changed by this script"
    cp "$BACKUP_DIR/db.go.before" "$DB_FILE"
    rm -f "$TEST_FILE"
    echo "Restored: $DB_FILE"
    echo "Removed newly-created: $TEST_FILE"
    echo "Backup retained: $BACKUP_DIR"
  fi
  exit "$rc"
}
trap rollback EXIT

 echo "===== HORIZON v1.4 PHASE 1C — DB DIALECT GUARD ====="
echo "Started: $(date --iso-8601=seconds 2>/dev/null || date)"
echo "Repository: $ROOT"
echo "Backup/report: $BACKUP_DIR"
echo "Database access: NONE"
go version
git branch --show-current
git rev-parse HEAD

[[ -f "$DB_FILE" ]] || { echo "ERROR: missing $DB_FILE"; exit 1; }
[[ -f "$CHAIN_FILE" ]] || { echo "ERROR: missing $CHAIN_FILE"; exit 1; }
[[ -f "$EXISTING_TEST" ]] || { echo "ERROR: expected existing Genesis guard test not found"; exit 1; }
[[ ! -e "$TEST_FILE" ]] || { echo "ERROR: refusing to overwrite $TEST_FILE"; exit 1; }

grep -q 'licenseChainSchemaMigrationAllowed' "$CHAIN_FILE" || { echo "ERROR: Schema guard marker missing"; exit 1; }
grep -q 'licenseChainGenesisBootstrapAllowed' "$CHAIN_FILE" || { echo "ERROR: Genesis guard marker missing"; exit 1; }

FUNC_COUNT="$(grep -F -c 'func configureSQLite(db *gorm.DB) error {' "$DB_FILE" || true)"
[[ "$FUNC_COUNT" == "1" ]] || {
  echo "ERROR: expected exactly one configureSQLite function; found $FUNC_COUNT"
  exit 1
}
if grep -q 'db.Dialector.Name() != "sqlite"' "$DB_FILE"; then
  echo "ERROR: dialect guard already exists; refusing duplicate patch"
  exit 1
fi

# Confirm the already-present Genesis/Schema environment-gate test before proceeding.
go test -count=1 -timeout=180s -run '^TestLicenseChainSafetyGatesFailClosed$' ./cmd/switch

cp "$DB_FILE" "$BACKUP_DIR/db.go.before"
PATCH_APPLIED=1
echo "Backup SHA256:"
sha256sum "$BACKUP_DIR/db.go.before"

# Guard configureSQLite at its entry point. Non-SQLite dialectors (notably PostgreSQL)
# must not receive SQLite PRAGMAs or have their connection pool reset to one connection.
sed -i '/^func configureSQLite(db \*gorm.DB) error {$/a\	if db.Dialector.Name() != "sqlite" {\
\	\treturn nil\
\	}' "$DB_FILE"

cat > "$TEST_FILE" <<'GOEOF'
package main

import (
	"path/filepath"
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

func TestConfigureSQLiteSkipsPostgres(t *testing.T) {
	db, err := gorm.Open(postgres.Open("host=127.0.0.1 port=1 user=horizon_test dbname=horizon_test sslmode=disable"), &gorm.Config{DisableAutomaticPing: true})
	if err != nil {
		t.Fatalf("open postgres dialector without connecting: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get postgres sql.DB: %v", err)
	}
	defer sqlDB.Close()

	if err := configureSQLite(db); err != nil {
		t.Fatalf("configureSQLite should be a no-op for PostgreSQL: %v", err)
	}
	if got := sqlDB.Stats().MaxOpenConnections; got != 0 {
		t.Fatalf("PostgreSQL pool max-open was changed to %d; want unchanged default 0", got)
	}
}

func TestConfigureSQLiteStillConfiguresSQLite(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "switch-test.db")
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		t.Fatalf("open temporary SQLite DB: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get SQLite sql.DB: %v", err)
	}
	defer sqlDB.Close()

	if err := configureSQLite(db); err != nil {
		t.Fatalf("configure SQLite: %v", err)
	}
	if got := sqlDB.Stats().MaxOpenConnections; got != 1 {
		t.Fatalf("SQLite pool max-open = %d, want 1", got)
	}
}

func TestCreateGenesisBlockFailsClosedWithoutOptIn(t *testing.T) {
	t.Setenv(licenseChainGenesisBootstrapEnv, "")
	block, err := createGenesisBlock(nil, nil)
	if err == nil {
		t.Fatal("expected Genesis creation to be refused without explicit opt-in")
	}
	if block != nil {
		t.Fatalf("expected no Genesis block, got %#v", block)
	}
}

func TestMigrateChainDoesNotCreateMissingTablesByDefault(t *testing.T) {
	t.Setenv(licenseChainSchemaMigrationEnv, "")
	dbPath := filepath.Join(t.TempDir(), "empty-registry.db")
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		t.Fatalf("open temporary SQLite DB: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get SQLite sql.DB: %v", err)
	}
	defer sqlDB.Close()

	if err := migrateChain(db); err == nil {
		t.Fatal("expected missing Schema to fail closed")
	}
	if db.Migrator().HasTable(&ChainBlock{}) || db.Migrator().HasTable(&ChainTx{}) {
		t.Fatal("migrateChain unexpectedly created registry tables")
	}
}

func TestMigrateChainAcceptsExistingTablesWithoutOptIn(t *testing.T) {
	t.Setenv(licenseChainSchemaMigrationEnv, "")
	dbPath := filepath.Join(t.TempDir(), "existing-registry.db")
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		t.Fatalf("open temporary SQLite DB: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get SQLite sql.DB: %v", err)
	}
	defer sqlDB.Close()

	if err := db.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil {
		t.Fatalf("prepare isolated test Schema: %v", err)
	}
	if err := migrateChain(db); err != nil {
		t.Fatalf("existing Schema should pass without migration opt-in: %v", err)
	}
}
GOEOF

gofmt -w "$DB_FILE" "$TEST_FILE"

echo "===== PATCH SUMMARY ====="
git diff --check
git diff -- "$DB_FILE"
echo "New isolated tests: $TEST_FILE"

echo "===== TARGETED TESTS ====="
go test -count=1 -timeout=180s \
  -run '^(TestLicenseChainSafetyGatesFailClosed|TestConfigureSQLiteSkipsPostgres|TestConfigureSQLiteStillConfiguresSQLite|TestCreateGenesisBlockFailsClosedWithoutOptIn|TestMigrateChainDoesNotCreateMissingTablesByDefault|TestMigrateChainAcceptsExistingTablesWithoutOptIn)$' \
  ./cmd/switch

# Keep changes only after all isolated guard tests pass.
PATCH_APPLIED=0
echo "RESULT=PASS"
echo "Backup retained: $BACKUP_DIR"
echo "Report: $REPORT"
echo "No database was opened or modified by this script."
