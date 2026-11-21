#!/usr/bin/env bash
set -Eeuo pipefail

say() { printf '%s\n' "$*"; }
fail() { say "ERROR: $*" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "Run inside the Horizon Core git repository."
cd "$ROOT"
ROOT_WIN="$(cygpath -w "$ROOT" 2>/dev/null || printf '%s' "$ROOT")"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$HOME/horizon-v14-backups/phase3c-tenant-schema-guard-v3-$STAMP"
mkdir -p "$BACKUP/source-before/internal/tenant" "$BACKUP/source-before/cmd/switch" "$BACKUP/tmp"

TENANT_FILE="internal/tenant/tenant.go"
HANDLER_FILE="cmd/switch/tenant_handler.go"
TENANT_TEST="internal/tenant/tenant_schema_guard_test.go"

for f in "$TENANT_FILE" "$HANDLER_FILE"; do
  [ -f "$f" ] || fail "Required source file missing: $f"
done
[ ! -e "$TENANT_TEST" ] || fail "Refusing to overwrite existing test: $TENANT_TEST"

say "===== HORIZON v1.4 PHASE 3C — TENANT SCHEMA GUARD v3 ====="
say "Started: $(date --iso-8601=seconds 2>/dev/null || date)"
say "Repository: $ROOT_WIN"
say "Backup: $BACKUP"
say "DATABASE ACCESS: NONE"
say "RUNTIME RESTART: NONE"
say "Go: $(go version)"
say "Branch: $(git branch --show-current)"
say "Commit: $(git rev-parse HEAD)"

cp -p "$TENANT_FILE" "$BACKUP/source-before/internal/tenant/tenant.go"
cp -p "$HANDLER_FILE" "$BACKUP/source-before/cmd/switch/tenant_handler.go"
(
  cd "$BACKUP/source-before"
  sha256sum internal/tenant/tenant.go cmd/switch/tenant_handler.go
) | tee "$BACKUP/source-before.sha256"

cat > "$BACKUP/tmp/patch.go" <<'GO'
package main

import (
    "fmt"
    "os"
    "regexp"
    "strings"
)

func replaceOnce(path string, re *regexp.Regexp, replacement string, label string) error {
    b, err := os.ReadFile(path)
    if err != nil { return err }
    src := strings.ReplaceAll(string(b), "\r\n", "\n")
    locs := re.FindAllStringIndex(src, -1)
    if len(locs) != 1 {
        return fmt.Errorf("%s: expected exactly 1 match, found %d", label, len(locs))
    }
    out := re.ReplaceAllString(src, replacement)
    if out == src { return fmt.Errorf("%s: replacement produced no change", label) }
    return os.WriteFile(path, []byte(out), 0644)
}

func main() {
    if len(os.Args) != 3 { fmt.Fprintln(os.Stderr, "usage: patch <tenant.go> <tenant_handler.go>"); os.Exit(2) }
    tenantPath, handlerPath := os.Args[1], os.Args[2]

    // Add imports without depending on tab/space formatting.
    b, err := os.ReadFile(tenantPath); if err != nil { panic(err) }
    src := strings.ReplaceAll(string(b), "\r\n", "\n")
    if !strings.Contains(src, "\"fmt\"") {
        re := regexp.MustCompile(`(?m)^import \(\n`)
        if len(re.FindAllStringIndex(src, -1)) != 1 { panic("tenant.go: import block not found uniquely") }
        src = re.ReplaceAllString(src, "import (\n\t\"fmt\"\n\t\"strings\"\n")
    } else if !strings.Contains(src, "\"strings\"") {
        re := regexp.MustCompile(`(?m)^import \(\n`)
        src = re.ReplaceAllString(src, "import (\n\t\"strings\"\n")
    }
    oldInit := regexp.MustCompile(`(?s)func Init\(db \*gorm\.DB\) error \{\s*return db\.AutoMigrate\(&Tenant\{\},\s*&Heartbeat\{\}\)\s*\}`)
    newInit := `func Init(db *gorm.DB) error {
	if db == nil {
		return fmt.Errorf("tenant schema preflight: nil database")
	}
	missing := make([]string, 0, 2)
	if !db.Migrator().HasTable(&Tenant{}) {
		missing = append(missing, "tenants")
	}
	if !db.Migrator().HasTable(&Heartbeat{}) {
		missing = append(missing, "heartbeats")
	}
	if len(missing) != 0 {
		return fmt.Errorf("tenant schema incomplete; automatic migration is disabled; missing tables: %s", strings.Join(missing, ", "))
	}
	return nil
}`
    locs := oldInit.FindAllStringIndex(src, -1)
    if len(locs) != 1 { panic(fmt.Sprintf("tenant.go: expected exactly one legacy Init AutoMigrate function, found %d", len(locs))) }
    src = oldInit.ReplaceAllString(src, newInit)
    if strings.Contains(src, "db.AutoMigrate(&Tenant{}, &Heartbeat{})") { panic("tenant.go: AutoMigrate remains") }
    if err := os.WriteFile(tenantPath, []byte(src), 0644); err != nil { panic(err) }
    fmt.Println("PATCHED internal/tenant/tenant.go: Init is now read-only schema preflight")

    // If tenant schema is missing, do not register routes that would hit absent tables.
    handlerRe := regexp.MustCompile(`(?s)(if err := tenant\.Init\(db\); err != nil \{\s*log\.Printf\([^\n]*tenant\.Init failed[^\n]*\)\s*)(\})`)
    if err := replaceOnce(handlerPath, handlerRe, "${1}\t\t\treturn\n\t\t}", "tenant route fail-closed guard"); err != nil { panic(err) }
    fmt.Println("PATCHED cmd/switch/tenant_handler.go: tenant routes are not registered on schema failure")
}
GO

restore() {
  local reason="$1"
  say "PATCH/TEST FAILED: $reason"
  if [ -f "$BACKUP/source-before/internal/tenant/tenant.go" ]; then
    cp -p "$BACKUP/source-before/internal/tenant/tenant.go" "$TENANT_FILE"
  fi
  if [ -f "$BACKUP/source-before/cmd/switch/tenant_handler.go" ]; then
    cp -p "$BACKUP/source-before/cmd/switch/tenant_handler.go" "$HANDLER_FILE"
  fi
  rm -f "$TENANT_TEST"
  say "RESTORE=COMPLETED (only Phase 3C target files)"
  exit 1
}

# Build the patcher first, then execute the binary. Passing target .go files
# directly to `go run` makes the Go tool treat them as additional source files
# and fails when they live in different directories.
PATCHER_EXE="$BACKUP/tmp/tenant-schema-patcher.exe"
if ! go build -o "$PATCHER_EXE" "$BACKUP/tmp/patch.go"; then
  restore "could not build isolated source patcher"
fi
if ! "$PATCHER_EXE" \
  "$(cygpath -w "$TENANT_FILE" 2>/dev/null || printf '%s' "$TENANT_FILE")" \
  "$(cygpath -w "$HANDLER_FILE" 2>/dev/null || printf '%s' "$HANDLER_FILE")"; then
  restore "source patcher failed"
fi

cat > "$TENANT_TEST" <<'GO'
package tenant

import (
    "testing"

    "github.com/glebarez/sqlite"
    "gorm.io/gorm"
)

func openTenantGuardTestDB(t *testing.T) *gorm.DB {
    t.Helper()
    db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
    if err != nil { t.Fatalf("open sqlite test DB: %v", err) }
    sqlDB, err := db.DB()
    if err != nil { t.Fatalf("get sql DB: %v", err) }
    t.Cleanup(func() { _ = sqlDB.Close() })
    return db
}

func TestInitFailsClosedWithoutCreatingTenantTables(t *testing.T) {
    db := openTenantGuardTestDB(t)
    if err := Init(db); err == nil { t.Fatal("expected missing tenant schema to fail closed") }
    if db.Migrator().HasTable(&Tenant{}) { t.Fatal("Init unexpectedly created tenants table") }
    if db.Migrator().HasTable(&Heartbeat{}) { t.Fatal("Init unexpectedly created heartbeats table") }
}

func TestInitAcceptsExistingTenantSchema(t *testing.T) {
    db := openTenantGuardTestDB(t)
    if err := db.Migrator().CreateTable(&Tenant{}, &Heartbeat{}); err != nil { t.Fatalf("create test schema: %v", err) }
    if err := Init(db); err != nil { t.Fatalf("existing tenant schema should pass: %v", err) }
}

func TestInitRejectsNilDatabase(t *testing.T) {
    if err := Init(nil); err == nil { t.Fatal("expected nil DB to be rejected") }
}
GO

gofmt -w "$TENANT_FILE" "$HANDLER_FILE" "$TENANT_TEST" || restore "gofmt failed"

git diff --check || restore "git diff --check failed"

say "===== TENANT MIGRATION CHECK ====="
# The source retains a historical comment saying "// AutoMigrate" above Init.
# Inspect the Init function body only, so comments cannot trigger a false failure.
INIT_BODY="$(sed -n '/^func Init(db \*gorm\.DB) error {/,/^}/p' "$TENANT_FILE")"
if [ -z "$INIT_BODY" ]; then restore "tenant.Init function not found"; fi
if printf '%s\n' "$INIT_BODY" | grep -nE '\.[[:space:]]*AutoMigrate[[:space:]]*\('; then
  restore "tenant.Init still contains an AutoMigrate call"
else
  say "PASS: tenant.Init contains no AutoMigrate call (documentation comment is allowed)"
fi
say "===== ROUTE FAIL-CLOSED CHECK ====="
grep -n -A5 -B2 'tenant.Init(db)' "$HANDLER_FILE" || restore "tenant route guard not found"

say "===== TARGETED TESTS ====="
if ! go test -count=1 -timeout=180s ./internal/tenant ./cmd/switch; then restore "targeted Go tests failed"; fi

say "===== PATCH SUMMARY ====="
git diff --stat -- "$TENANT_FILE" "$HANDLER_FILE"
git diff --check
say "RESULT=PASS"
say "Backup retained: $BACKUP"
say "Report: $BACKUP/phase3c-v3-report.txt"
{
  say "HORIZON v1.4 PHASE 3C — TENANT SCHEMA GUARD v3"
  say "Result: PASS"
  say "Database access: NONE"
  say "Runtime restart: NONE"
  say "Tenant.Init is a read-only table preflight; its function body has no AutoMigrate call. Tenant routes fail closed on schema failure."
  say "Tests: go test -count=1 -timeout=180s ./internal/tenant ./cmd/switch"
  say "Backup: $BACKUP"
} > "$BACKUP/phase3c-v3-report.txt"
