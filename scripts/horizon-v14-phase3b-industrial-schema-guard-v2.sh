#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: run from inside horizon-core repository" >&2
  exit 1
}
cd "$ROOT"

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_ROOT="${HOME}/horizon-v14-backups/phase3b-industrial-schema-guard-v2-${TS}"
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
  "internal/industrial/smart_alerts_schema_guard_test.go"
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
	"regexp"
	"strings"
)

func replaceRegex(path, pattern, replacement string, expected int) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	re := regexp.MustCompile(pattern)
	locs := re.FindAllIndex(b, -1)
	if len(locs) != expected {
		return fmt.Errorf("%s: expected %d matches, found %d", path, expected, len(locs))
	}
	out := re.ReplaceAll(b, []byte(replacement))
	if err := os.WriteFile(path, out, 0644); err != nil {
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
	if len(os.Args) != 2 {
		panic("usage: patcher <repo-root>")
	}
	root := os.Args[1]
	must := func(err error) {
		if err != nil {
			fmt.Fprintln(os.Stderr, "PATCH ERROR:", err)
			os.Exit(1)
		}
	}

	// Flexible whitespace patterns intentionally handle tabs, spaces and CRLF.
	must(replaceRegex(root+"/cmd/switch/industrial_anchor.go",
		`func startIndustrialAnchorWorker\(\) \{\s*anchorMutex\.Lock\(\)`,
		"func startIndustrialAnchorWorker() {\n\tif err := requireExistingSwitchTables(db, &AnchorState{}, &industrial.Reading{}); err != nil {\n\t\tlog.Printf(\"[INDUSTRIAL] anchor worker disabled; schema preflight failed: %v\", err)\n\t\treturn\n\t}\n\tanchorMutex.Lock()", 1))

	must(replaceRegex(root+"/cmd/switch/industrial_anchor.go",
		`(?m)^[ \t]*if err := db\.AutoMigrate\(&AnchorState\{\}\); err != nil \{\r?\n[ \t]*log\.Printf\([^\r\n]*anchor: migrate failed[^\r\n]*\)\r?\n[ \t]*return\r?\n[ \t]*\}`,
		"", 1))

	must(replaceRegex(root+"/cmd/switch/industrial_handler.go",
		`import\s*\(\s*"net/http"\s*"time"`,
		"import (\n\t\"log\"\n\t\"net/http\"\n\t\"time\"", 1))

	must(replaceRegex(root+"/cmd/switch/industrial_handler.go",
		`func registerIndustrialRoutes\(api \*gin\.RouterGroup\) \{\s*_ = db\.AutoMigrate\(\s*&industrial\.Site\{\},\s*&industrial\.Sensor\{\},\s*&industrial\.Reading\{\},\s*&industrial\.Alert\{\},\s*&industrial\.TamperEvent\{\},\s*&industrial\.ControlCommand\{\},\s*&industrial\.SensorState\{\},\s*\)\s*ind := api\.Group\("/industrial"\)`,
		"func registerIndustrialRoutes(api *gin.RouterGroup) {\n\tind := api.Group(\"/industrial\")\n\tif err := requireExistingSwitchTables(db, &industrial.Site{}, &industrial.Sensor{}, &industrial.Reading{}, &industrial.Alert{}, &industrial.TamperEvent{}, &industrial.ControlCommand{}, &industrial.SensorState{}); err != nil {\n\t\tlog.Printf(\"[INDUSTRIAL] routes disabled; schema preflight failed: %v\", err)\n\t\tind.Use(func(c *gin.Context) {\n\t\t\tc.AbortWithStatusJSON(http.StatusServiceUnavailable, gin.H{\"error\": \"industrial service unavailable: required schema is incomplete\"})\n\t\t})\n\t}", 1))

	must(replaceRegex(root+"/internal/industrial/smart_alerts.go",
		`func StartBackgroundJobs\(db \*gorm\.DB\) \{\s*db\.AutoMigrate\(&SensorState\{\}\)\s*StartHeartbeatMonitor\(db, 1\*time\.Minute\)`,
		"func backgroundJobsSchemaReady(db *gorm.DB) bool {\n\tif db == nil {\n\t\treturn false\n\t}\n\treturn db.Migrator().HasTable(&Sensor{}) &&\n\t\tdb.Migrator().HasTable(&Reading{}) &&\n\t\tdb.Migrator().HasTable(&Alert{}) &&\n\t\tdb.Migrator().HasTable(&SensorState{})\n}\n\nfunc StartBackgroundJobs(db *gorm.DB) {\n\tif !backgroundJobsSchemaReady(db) {\n\t\tlog.Printf(\"[INDUSTRIAL] background jobs disabled: required schema is incomplete\")\n\t\treturn\n\t}\n\tStartHeartbeatMonitor(db, 1*time.Minute)", 1))

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

	switchTest := `package main

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
	must(writeNew(root+"/cmd/switch/industrial_schema_guard_test.go", switchTest))

	industrialTest := `package industrial

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestBackgroundJobsSchemaReadyFailsClosedWithoutCreatingTables(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil { t.Fatalf("open isolated sqlite: %v", err) }
	if backgroundJobsSchemaReady(db) {
		t.Fatal("empty schema must not enable industrial background jobs")
	}
	if db.Migrator().HasTable(&SensorState{}) {
		t.Fatal("schema readiness check unexpectedly created SensorState")
	}
}

func TestBackgroundJobsSchemaReadyWithRequiredTables(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil { t.Fatalf("open isolated sqlite: %v", err) }
	if err := db.AutoMigrate(&Sensor{}, &Reading{}, &Alert{}, &SensorState{}); err != nil {
		t.Fatalf("prepare isolated fixture: %v", err)
	}
	if !backgroundJobsSchemaReady(db) {
		t.Fatal("complete schema should enable industrial background jobs")
	}
}
`
	must(writeNew(root+"/internal/industrial/smart_alerts_schema_guard_test.go", industrialTest))

	// Avoid accidentally introducing a duplicate import when source differs.
	b, err := os.ReadFile(root + "/cmd/switch/industrial_handler.go")
	if err != nil { panic(err) }
	if strings.Count(string(b), `"log"`) != 1 {
		panic("industrial_handler.go must contain exactly one log import after patch")
	}
}
GO

cat > "$BACKUP_ROOT/phase3b-report.txt" <<EOF2
HORIZON v1.4 PHASE 3B v2 — INDUSTRIAL SCHEMA GUARD
Started: $(date -Iseconds)
Repository: $ROOT
Backup: $BACKUP_ROOT
Go: $(go version)
Branch: $(git branch --show-current)
Commit: $(git rev-parse HEAD)
Database access: NONE
Runtime restart: NONE
EOF2

restore_sources() {
  echo "RESTORING ORIGINAL PHASE 3B TARGETS" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  for f in "${TARGETS[@]}"; do
    if [[ -f "$BACKUP_ROOT/source-before/$f" ]]; then
      mkdir -p "$(dirname "$f")"
      cp -p "$BACKUP_ROOT/source-before/$f" "$f"
    fi
  done
  for f in "${NEW_FILES[@]}"; do rm -f "$f"; done
  echo "RESTORE=COMPLETED" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
}

PATCHER="$BACKUP_ROOT/patcher/main.go"
if command -v cygpath >/dev/null 2>&1; then GO_ROOT="$(cygpath -w "$ROOT")"; else GO_ROOT="$ROOT"; fi
if ! go run "$PATCHER" "$GO_ROOT"; then
  echo "PATCH FAILED" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  restore_sources
  exit 1
fi

if ! gofmt -w \
  cmd/switch/industrial_anchor.go \
  cmd/switch/industrial_handler.go \
  internal/industrial/smart_alerts.go \
  cmd/switch/industrial_schema_guard.go \
  cmd/switch/industrial_schema_guard_test.go \
  internal/industrial/smart_alerts_schema_guard_test.go; then
  echo "GOFMT FAILED" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  restore_sources
  exit 1
fi

if grep -nE 'AutoMigrate' \
  cmd/switch/industrial_anchor.go \
  cmd/switch/industrial_handler.go \
  internal/industrial/smart_alerts.go; then
  echo "ERROR: production AutoMigrate remains in industrial startup files" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  restore_sources
  exit 1
fi

if ! git diff --check; then
  echo "DIFF CHECK FAILED" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  restore_sources
  exit 1
fi

echo "===== INDUSTRIAL SCHEMA GUARD PATCH ====="
git diff --stat -- "${TARGETS[@]}"
echo "===== NO INDUSTRIAL PRODUCTION AUTOMIGRATE ====="
echo "PASS: no AutoMigrate in industrial anchor/routes/background files"
echo "===== TARGETED TESTS ====="
if ! go test -count=1 -timeout=180s ./cmd/switch ./internal/industrial; then
  echo "TESTS FAILED" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  restore_sources
  exit 1
fi

if ! git diff --check; then
  echo "FINAL DIFF CHECK FAILED" | tee -a "$BACKUP_ROOT/phase3b-report.txt"
  restore_sources
  exit 1
fi

cat >> "$BACKUP_ROOT/phase3b-report.txt" <<EOF2
Result: PASS
Production AutoMigrate removed from industrial anchor/routes/background jobs.
Missing industrial tables disable industrial routes with HTTP 503 and prevent background workers from starting.
No database opened or modified.
No runtime restart performed.
EOF2

echo "RESULT=PASS"
echo "Backup retained: $BACKUP_ROOT"
echo "Report: $BACKUP_ROOT/phase3b-report.txt"
echo "Operational note: missing industrial tables cause HTTP 503 and background workers remain disabled; no schema is auto-created."
