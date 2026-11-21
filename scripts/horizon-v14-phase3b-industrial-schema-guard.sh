#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: run this script from inside horizon-core repository" >&2
  exit 1
}
cd "$ROOT"

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_ROOT="${HOME}/horizon-v14-backups/phase3b-industrial-schema-guard-${TS}"
mkdir -p "$BACKUP_ROOT/source-before/cmd/switch" \
         "$BACKUP_ROOT/source-before/internal/industrial" \
         "$BACKUP_ROOT/patcher"

TARGETS=(
  "cmd/switch/industrial_anchor.go"
  "cmd/switch/industrial_handler.go"
  "internal/industrial/smart_alerts.go"
)
NEW_FILES=(
  "cmd/switch/industrial_schema_guard.go"
  "cmd/switch/industrial_schema_guard_test.go"
)

for f in "${TARGETS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: required source file missing: $f" >&2
    exit 1
  fi
  mkdir -p "$BACKUP_ROOT/source-before/$(dirname "$f")"
  cp -p "$f" "$BACKUP_ROOT/source-before/$f"
done

for f in "${NEW_FILES[@]}"; do
  if [[ -e "$f" ]]; then
    echo "ERROR: refusing to overwrite existing file: $f" >&2
    exit 1
  fi
done

(
  cd "$BACKUP_ROOT/source-before"
  sha256sum "${TARGETS[@]}"
) | tee "$BACKUP_ROOT/source-before.sha256"

cat > "$BACKUP_ROOT/patcher/main.go" <<'GO'
package main

import (
	"fmt"
	"os"
	"strings"
)

func replaceExact(path, old, replacement string, expected int) error {
	b, err := os.ReadFile(path)
	if err != nil { return fmt.Errorf("read %s: %w", path, err) }
	s := string(b)
	count := strings.Count(s, old)
	if count != expected {
		return fmt.Errorf("%s: expected %d occurrences, found %d", path, expected, count)
	}
	s = strings.Replace(s, old, replacement, expected)
	if err := os.WriteFile(path, []byte(s), 0644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	fmt.Println("PATCHED", path)
	return nil
}

func writeNew(path, content string) error {
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("refusing to overwrite existing file: %s", path)
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		return fmt.Errorf("create %s: %w", path, err)
	}
	fmt.Println("CREATED", path)
	return nil
}

func main() {
	if len(os.Args) != 2 { panic("usage: patcher <repo-root>") }
	root := os.Args[1]
	must := func(err error) { if err != nil { fmt.Fprintln(os.Stderr, "PATCH ERROR:", err); os.Exit(1) } }

	// Anchor worker: preflight existing tables before setting the started flag;
	// never create AnchorState automatically.
	must(replaceExact(root+"/cmd/switch/industrial_anchor.go",
		"func startIndustrialAnchorWorker() {\n\tanchorMutex.Lock()",
		"func startIndustrialAnchorWorker() {\n\tif err := requireExistingSwitchTables(db, &AnchorState{}, &industrial.Reading{}); err != nil {\n\t\tlog.Printf(\"[INDUSTRIAL] anchor worker disabled; schema preflight failed: %v\", err)\n\t\treturn\n\t}\n\tanchorMutex.Lock()", 1))
	must(replaceExact(root+"/cmd/switch/industrial_anchor.go",
		"\n\tif err := db.AutoMigrate(&AnchorState{}); err != nil {\n\t\tlog.Printf(\"⚠️  anchor: migrate failed: %v\", err)\n\t\treturn\n\t}\n",
		"\n", 1))

	// Industrial routes: fail closed with an explicit 503 wildcard when any
	// required table is absent. Do not run AutoMigrate from route registration.
	must(replaceExact(root+"/cmd/switch/industrial_handler.go",
		"import (\n\t\"net/http\"\n\t\"time\"",
		"import (\n\t\"log\"\n\t\"net/http\"\n\t\"time\"", 1))
	must(replaceExact(root+"/cmd/switch/industrial_handler.go",
		"func registerIndustrialRoutes(api *gin.RouterGroup) {\n\t_ = db.AutoMigrate(\n\t\t&industrial.Site{},\n\t\t&industrial.Sensor{},\n\t\t&industrial.Reading{},\n\t\t&industrial.Alert{},\n\t\t&industrial.TamperEvent{},\n\t\t&industrial.ControlCommand{},\n\t\t&industrial.SensorState{},\n\t)\n\n\tind := api.Group(\"/industrial\")",
		"func registerIndustrialRoutes(api *gin.RouterGroup) {\n\tind := api.Group(\"/industrial\")\n\tif err := requireExistingSwitchTables(db, &industrial.Site{}, &industrial.Sensor{}, &industrial.Reading{}, &industrial.Alert{}, &industrial.TamperEvent{}, &industrial.ControlCommand{}, &industrial.SensorState{}); err != nil {\n\t\tlog.Printf(\"[INDUSTRIAL] routes disabled; schema preflight failed: %v\", err)\n\t\tind.Any(\"/*path\", func(c *gin.Context) {\n\t\t\tc.JSON(http.StatusServiceUnavailable, gin.H{\"error\": \"industrial service unavailable: required schema is incomplete\"})\n\t\t})\n\t\treturn\n\t}", 1))

	// Background jobs: remove SensorState migration and refuse to start unless
	// all tables they use already exist.
	must(replaceExact(root+"/internal/industrial/smart_alerts.go",
		"func StartBackgroundJobs(db *gorm.DB) {\n\tdb.AutoMigrate(&SensorState{})\n\tStartHeartbeatMonitor(db, 1*time.Minute)",
		"func StartBackgroundJobs(db *gorm.DB) {\n\tif db == nil {\n\t\tlog.Printf(\"[INDUSTRIAL] background jobs disabled: nil database\")\n\t\treturn\n\t}\n\tmissing := make([]string, 0, 4)\n\tfor _, model := range []interface{}{&Sensor{}, &Reading{}, &Alert{}, &SensorState{}} {\n\t\tif !db.Migrator().HasTable(model) {\n\t\t\tmissing = append(missing, fmt.Sprintf(\"%T\", model))\n\t\t}\n\t}\n\tif len(missing) != 0 {\n\t\tlog.Printf(\"[INDUSTRIAL] background jobs disabled; missing tables: %v\", missing)\n\t\treturn\n\t}\n\tStartHeartbeatMonitor(db, 1*time.Minute)", 1))

	guard := `package main

import (
	"fmt"
	"strings"

	"gorm.io/gorm"
)

// requireExistingSwitchTables performs a read-only schema preflight. It never
// creates or alters tables; feature owners must disable their feature if this fails.
func requireExistingSwitchTables(db *gorm.DB, models ...interface{}) error {
	if db == nil {
		return fmt.Errorf("schema preflight: nil database")
	}
	missing := make([]string, 0)
	for _, model := range models {
		if !db.Migrator().HasTable(model) {
			missing = append(missing, fmt.Sprintf("%T", model))
		}
	}
	if len(missing) != 0 {
		return fmt.Errorf("required tables are missing; automatic migration is disabled: %s", strings.Join(missing, ", "))
	}
	return nil
}
`
	must(writeNew(root+"/cmd/switch/industrial_schema_guard.go", guard))

	test := `package main

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"horizon-core/internal/industrial"
)

func TestIndustrialSchemaGuardFailsClosedWithoutCreatingTables(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil { t.Fatalf("open isolated sqlite: %v", err) }
	if err := requireExistingSwitchTables(db, &industrial.Site{}, &industrial.Sensor{}); err == nil {
		t.Fatal("expected missing industrial tables to fail closed")
	}
	if db.Migrator().HasTable(&industrial.Site{}) || db.Migrator().HasTable(&industrial.Sensor{}) {
		t.Fatal("schema guard unexpectedly created tables")
	}
}

func TestIndustrialSchemaGuardAcceptsExistingTables(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil { t.Fatalf("open isolated sqlite: %v", err) }
	if err := db.AutoMigrate(&industrial.Site{}, &industrial.Sensor{}); err != nil {
		t.Fatalf("prepare isolated fixture: %v", err)
	}
	if err := requireExistingSwitchTables(db, &industrial.Site{}, &industrial.Sensor{}); err != nil {
		t.Fatalf("existing tables should pass: %v", err)
	}
}
`
	must(writeNew(root+"/cmd/switch/industrial_schema_guard_test.go", test))
}
GO

cat > "$BACKUP_ROOT/phase3b-report.txt" <<EOF
HORIZON v1.4 PHASE 3B — INDUSTRIAL SCHEMA GUARD
Started: $(date -Iseconds)
Repository: $ROOT
Backup: $BACKUP_ROOT
Go: $(go version)
Branch: $(git branch --show-current)
Commit: $(git rev-parse HEAD)
Database access: NONE
Runtime restart: NONE
EOF

PATCHER="$BACKUP_ROOT/patcher/main.go"
if command -v cygpath >/dev/null 2>&1; then
  GO_ROOT="$(cygpath -w "$ROOT")"
else
  GO_ROOT="$ROOT"
fi
if ! go run "$PATCHER" "$GO_ROOT"; then
  echo "PATCH FAILED; restoring backed-up source files" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  for f in "${TARGETS[@]}"; do cp -p "$BACKUP_ROOT/source-before/$f" "$f"; done
  rm -f "${NEW_FILES[@]}"
  echo "RESTORE=COMPLETED" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  exit 1
fi

if ! gofmt -w \
  cmd/switch/industrial_anchor.go \
  cmd/switch/industrial_handler.go \
  internal/industrial/smart_alerts.go \
  cmd/switch/industrial_schema_guard.go \
  cmd/switch/industrial_schema_guard_test.go; then
  echo "GOFMT FAILED; restoring backed-up source files" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  for f in "${TARGETS[@]}"; do cp -p "$BACKUP_ROOT/source-before/$f" "$f"; done
  rm -f "${NEW_FILES[@]}"
  echo "RESTORE=COMPLETED" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  exit 1
fi

if grep -nE 'AutoMigrate' cmd/switch/industrial_anchor.go cmd/switch/industrial_handler.go internal/industrial/smart_alerts.go; then
  echo "ERROR: unexpected production AutoMigrate remains in industrial startup files" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  for f in "${TARGETS[@]}"; do cp -p "$BACKUP_ROOT/source-before/$f" "$f"; done
  rm -f "${NEW_FILES[@]}"
  echo "RESTORE=COMPLETED" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  exit 1
fi

if ! git diff --check; then
  echo "DIFF CHECK FAILED; restoring backed-up source files" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  for f in "${TARGETS[@]}"; do cp -p "$BACKUP_ROOT/source-before/$f" "$f"; done
  rm -f "${NEW_FILES[@]}"
  echo "RESTORE=COMPLETED" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  exit 1
fi

echo "===== INDUSTRIAL SCHEMA GUARD PATCH ====="
git diff --stat -- cmd/switch/industrial_anchor.go cmd/switch/industrial_handler.go internal/industrial/smart_alerts.go
echo "===== ENSURE NO INDUSTRIAL AUTO MIGRATIONS ====="
echo "PASS: no AutoMigrate in industrial startup/route/background files"
echo "===== TARGETED TESTS ====="
if ! go test -count=1 -timeout=180s ./cmd/switch ./internal/industrial; then
  echo "TESTS FAILED; restoring backed-up source files" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  for f in "${TARGETS[@]}"; do cp -p "$BACKUP_ROOT/source-before/$f" "$f"; done
  rm -f "${NEW_FILES[@]}"
  echo "RESTORE=COMPLETED" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  exit 1
fi

echo "===== FINAL DIFF CHECK ====="
git diff --check
cat >> "$BACKUP_ROOT/phase3b-report.txt" <<EOF
Result: PASS
Production AutoMigrate removed from industrial anchor/routes/background jobs.
Missing industrial tables now cause the industrial surface/workers to fail closed.
No database opened or modified.
No runtime restart performed.
EOF

echo "RESULT=PASS"
echo "Backup retained: $BACKUP_ROOT"
echo "Report: $BACKUP_ROOT/phase3b-report.txt"
echo "Operational note: if required industrial tables are missing, routes respond HTTP 503 and industrial workers remain disabled; no schema is auto-created."
