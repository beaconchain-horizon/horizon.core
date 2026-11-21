#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$HOME/horizon-v14-backups/phase4d-runtime-readonly-gate-$STAMP"
mkdir -p "$BACKUP/source-before/cmd/switch" "$BACKUP/source-before"
REPORT="$BACKUP/phase4d-report.txt"
exec > >(tee "$REPORT") 2>&1

printf '===== HORIZON v1.4 PHASE 4D — STARTUP RECOVERY READ-ONLY GATE =====\n'
printf 'Started: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
printf 'Repository: %s\n' "$ROOT"
printf 'Backup: %s\n' "$BACKUP"
printf 'DATABASE ACCESS: NONE\nRUNTIME RESTART: NONE\n'
go version
git branch --show-current
git rev-parse HEAD

TARGETS=(
  "cmd/switch/switch.go"
  "cmd/switch/customer.go"
)
NEWFILES=(
  "cmd/switch/runtime_write_gate.go"
  "cmd/switch/runtime_write_gate_test.go"
)

for f in "${TARGETS[@]}"; do
  test -f "$f" || { echo "ERROR: missing target $f"; exit 1; }
  mkdir -p "$BACKUP/source-before/$(dirname "$f")"
  cp -p "$f" "$BACKUP/source-before/$f"
done
for f in "${NEWFILES[@]}"; do
  if [ -e "$f" ]; then
    echo "ERROR: refusing to overwrite existing $f"
    exit 1
  fi
done

sha256sum "${TARGETS[@]}" | tee "$BACKUP/source-before.sha256"

PATCHDIR="$BACKUP/patcher"
mkdir -p "$PATCHDIR"
cat > "$PATCHDIR/main.go" <<'GO'
package main

import (
    "fmt"
    "os"
    "path/filepath"
    "regexp"
    "strings"
)

func mustRead(root, rel string) string {
    b, err := os.ReadFile(filepath.Join(root, rel))
    if err != nil { panic(err) }
    return strings.ReplaceAll(string(b), "\r\n", "\n")
}
func mustWrite(root, rel, s string) {
    p := filepath.Join(root, rel)
    if err := os.WriteFile(p, []byte(s), 0644); err != nil { panic(err) }
}
func replaceRegexOnce(src, pattern, replacement, label string) string {
    re := regexp.MustCompile(pattern)
    locs := re.FindAllStringIndex(src, -1)
    if len(locs) != 1 { panic(fmt.Sprintf("%s: expected exactly 1 match, got %d", label, len(locs))) }
    return re.ReplaceAllString(src, replacement)
}
func main() {
    if len(os.Args) != 2 { panic("usage: patcher ROOT") }
    root := os.Args[1]

    sw := mustRead(root, "cmd/switch/switch.go")
    if strings.Contains(sw, "recoveryWriteGateMiddleware()") || strings.Contains(sw, "configureRuntimeWriteReadiness(db)") {
        panic("switch.go already contains Phase 4D markers")
    }

    // Establish write readiness only after loading the configured chain ID and validating BOTH persisted ledgers.
    sw = replaceRegexOnce(sw,
        `(?m)^\s*if err := initLicenseChain\(db\); err != nil \{\n\s*log\.Printf\("⚠️  license chain init: %v", err\)\n\s*\}\n\s*initChainConfig\(\)\n\s*initCustomers\(\)`,
        "\t\tinitChainConfig()\n\t\tif err := configureRuntimeWriteReadiness(db); err != nil {\n\t\t\tlog.Printf(\"[RECOVERY] READ-ONLY MODE: %v\", err)\n\t\t}\n\t\tinitCustomers()",
        "startup ledger readiness block")

    // A batcher must never run when the canonical chains have not passed the recovery gate.
    sw = replaceRegexOnce(sw,
        `(?s)[ \t]*InitBatcher\(db, BatcherConfig\{\n[ \t]*MaxSize:\s*50000,\n[ \t]*FlushInterval:\s*200 \* time\.Millisecond,\n[ \t]*\}\)`,
        "\t\tif runtimeWritesAllowed.Load() {\n\t\t\tInitBatcher(db, BatcherConfig{\n\t\t\t\tMaxSize:       50000,\n\t\t\t\tFlushInterval: 200 * time.Millisecond,\n\t\t\t})\n\t\t} else {\n\t\t\tlog.Printf(\"[RECOVERY] batcher disabled: canonical chain validation has not passed\")\n\t\t}",
        "batcher startup gate")

    sw = replaceRegexOnce(sw,
        `(?m)^(\s*)startIndustrialAnchorWorker\(\)\s*$`,
        "${1}if runtimeWritesAllowed.Load() {\n${1}\tstartIndustrialAnchorWorker()\n${1}} else {\n${1}\tlog.Printf(\"[RECOVERY] industrial anchor worker disabled\")\n${1}}",
        "industrial anchor startup gate")

    sw = replaceRegexOnce(sw,
        `(?m)^(\s*)startLedgerLoops\(ledger, ledgerStop\)\s*$`,
        "${1}if runtimeWritesAllowed.Load() {\n${1}\tstartLedgerLoops(ledger, ledgerStop)\n${1}} else {\n${1}\tlog.Printf(\"[RECOVERY] ledger write loops disabled\")\n${1}}",
        "ledger write-loop startup gate")

    sw = replaceRegexOnce(sw,
        `(?m)^(\s*)startIndustrialBackgroundJobs\(\)\s*$`,
        "${1}if runtimeWritesAllowed.Load() {\n${1}\tstartIndustrialBackgroundJobs()\n${1}} else {\n${1}\tlog.Printf(\"[RECOVERY] industrial background jobs disabled\")\n${1}}",
        "industrial background startup gate")

    sw = replaceRegexOnce(sw,
        `(?m)^(\s*)r := gin\.Default\(\)\s*$`,
        "${1}r := gin.Default()\n${1}r.Use(recoveryWriteGateMiddleware())",
        "global recovery middleware")

    mustWrite(root, "cmd/switch/switch.go", sw)
    fmt.Println("PATCHED cmd/switch/switch.go: readiness gate, worker gates, and HTTP write gate")

    customer := mustRead(root, "cmd/switch/customer.go")
    if strings.Contains(customer, "customer seed disabled by recovery write gate") {
        panic("customer.go already contains Phase 4D marker")
    }
    customer = replaceRegexOnce(customer,
        `(?s)(if count > 0 \{\n\s*log\.Printf\("customers: %d already exist", count\)\n\s*return\n\s*\}\n)(\n\s*path := os\.Getenv\("CUSTOMERS_CONFIG"\))`,
        "${1}\n\t\tif !runtimeWritesAllowed.Load() {\n\t\t\tlog.Printf(\"[RECOVERY] customer seed disabled by recovery write gate\")\n\t\t\treturn\n\t\t}\n${2}",
        "customer seed gate")
    mustWrite(root, "cmd/switch/customer.go", customer)
    fmt.Println("PATCHED cmd/switch/customer.go: no automatic customer seeding in recovery mode")

    gate := `package main

import (
    "fmt"
    "net/http"
    "strings"
    "sync/atomic"

    "github.com/gin-gonic/gin"
    "gorm.io/gorm"
)

// runtimeWritesAllowed remains false until the configured chain ID and both
// persisted ledgers pass the locked v1.4 startup checks.
var runtimeWritesAllowed atomic.Bool

func configureRuntimeWriteReadiness(db *gorm.DB) error {
    runtimeWritesAllowed.Store(false)
    if db == nil {
        return fmt.Errorf("nil database")
    }

    var issues []string
    cfg := GetChainConfig()
    if cfg == nil || cfg.ChainID != "horizon-core-v1.4" {
        actual := "<nil>"
        if cfg != nil { actual = cfg.ChainID }
        issues = append(issues, fmt.Sprintf("configured Chain ID %q does not match locked horizon-core-v1.4", actual))
    }

    initErr := initLicenseChain(db)
    if initErr != nil {
        issues = append(issues, fmt.Sprintf("license registry initialization check failed: %v", initErr))
    }
    if err := validateMainBlockChainForWrite(db); err != nil {
        issues = append(issues, fmt.Sprintf("main ledger is not canonical: %v", err))
    }
    if initErr == nil {
        if err := validateLicenseChainForWrite(db); err != nil {
            issues = append(issues, fmt.Sprintf("license ledger is not canonical: %v", err))
        }
    }
    if len(issues) != 0 {
        return fmt.Errorf("%s", strings.Join(issues, "; "))
    }

    // Structural continuity is not cryptographic verification. Do not reopen
    // writes until every historical block hash and signature, plus transaction
    // membership, has been independently verified against locked v1.4 rules.
    return fmt.Errorf("cryptographic history verification is not yet implemented; recovery write gate remains closed")
}

// recoveryWriteGateMiddleware leaves read-only methods available and rejects
// all HTTP mutations until both ledgers and the Chain ID pass startup checks.
func recoveryWriteGateMiddleware() gin.HandlerFunc {
    return func(c *gin.Context) {
        if runtimeWritesAllowed.Load() {
            c.Next()
            return
        }
        switch c.Request.Method {
        case http.MethodGet, http.MethodHead, http.MethodOptions:
            c.Next()
            return
        default:
            c.AbortWithStatusJSON(http.StatusServiceUnavailable, gin.H{
                "error": "Horizon is in recovery read-only mode",
                "code": "CANONICAL_CHAIN_VALIDATION_REQUIRED",
            })
            return
        }
    }
}
`
    mustWrite(root, "cmd/switch/runtime_write_gate.go", gate)

    test := `package main

import (
    "net/http"
    "net/http/httptest"
    "testing"

    "github.com/gin-gonic/gin"
    "github.com/glebarez/sqlite"
    "gorm.io/gorm"
)

func TestRuntimeReadinessFailsClosedOnEmptySchema(t *testing.T) {
    db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
    if err != nil { t.Fatalf("open isolated sqlite: %v", err) }
    sqlDB, err := db.DB()
    if err != nil { t.Fatalf("get isolated sqlite DB: %v", err) }
    defer sqlDB.Close()
    old := runtimeWritesAllowed.Load()
    runtimeWritesAllowed.Store(false)
    t.Cleanup(func() { runtimeWritesAllowed.Store(old) })
    if err := configureRuntimeWriteReadiness(db); err == nil {
        t.Fatal("empty schema unexpectedly passed runtime readiness")
    }
    if runtimeWritesAllowed.Load() {
        t.Fatal("runtime writes became enabled with empty schema")
    }
}

func TestRecoveryWriteGateBlocksMutationUntilReady(t *testing.T) {
    old := runtimeWritesAllowed.Load()
    runtimeWritesAllowed.Store(false)
    t.Cleanup(func() { runtimeWritesAllowed.Store(old) })
    gin.SetMode(gin.TestMode)
    called := false
    r := gin.New()
    r.Use(recoveryWriteGateMiddleware())
    r.POST("/mutate", func(c *gin.Context) { called = true; c.Status(http.StatusOK) })
    w := httptest.NewRecorder()
    r.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/mutate", nil))
    if w.Code != http.StatusServiceUnavailable { t.Fatalf("status=%d, want 503", w.Code) }
    if called { t.Fatal("mutation handler ran while recovery gate was closed") }
}

func TestRecoveryWriteGateAllowsReadMethodsUntilReady(t *testing.T) {
    old := runtimeWritesAllowed.Load()
    runtimeWritesAllowed.Store(false)
    t.Cleanup(func() { runtimeWritesAllowed.Store(old) })
    gin.SetMode(gin.TestMode)
    r := gin.New()
    r.Use(recoveryWriteGateMiddleware())
    r.GET("/read", func(c *gin.Context) { c.Status(http.StatusOK) })
    w := httptest.NewRecorder()
    r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/read", nil))
    if w.Code != http.StatusOK { t.Fatalf("status=%d, want 200", w.Code) }
}

func TestRecoveryWriteGateAllowsMutationAfterCanonicalReadiness(t *testing.T) {
    old := runtimeWritesAllowed.Load()
    runtimeWritesAllowed.Store(true)
    t.Cleanup(func() { runtimeWritesAllowed.Store(old) })
    gin.SetMode(gin.TestMode)
    called := false
    r := gin.New()
    r.Use(recoveryWriteGateMiddleware())
    r.POST("/mutate", func(c *gin.Context) { called = true; c.Status(http.StatusOK) })
    w := httptest.NewRecorder()
    r.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/mutate", nil))
    if w.Code != http.StatusOK || !called { t.Fatalf("status=%d called=%v, want 200/true", w.Code, called) }
}
`
    mustWrite(root, "cmd/switch/runtime_write_gate_test.go", test)
    fmt.Println("CREATED runtime_write_gate.go and runtime_write_gate_test.go")
}
GO

export GOTOOLCHAIN=local
if ! go build -o "$PATCHDIR/patcher.exe" "$PATCHDIR/main.go"; then
  echo "PATCHER_BUILD=FAIL"
  exit 1
fi

restore_targets() {
  echo "RESTORE: restoring Phase 4D targets only"
  for f in "${TARGETS[@]}"; do
    cp -p "$BACKUP/source-before/$f" "$f"
  done
  for f in "${NEWFILES[@]}"; do
    rm -f "$f"
  done
  echo "RESTORE=COMPLETED"
}

if ! "$PATCHDIR/patcher.exe" "$ROOT"; then
  echo "PATCHER=FAIL"
  restore_targets
  exit 1
fi

gofmt -w cmd/switch/switch.go cmd/switch/customer.go cmd/switch/runtime_write_gate.go cmd/switch/runtime_write_gate_test.go

echo "===== STATIC STARTUP WRITE GATE CHECK ====="
grep -nE 'configureRuntimeWriteReadiness|runtimeWritesAllowed|recoveryWriteGateMiddleware|batcher disabled|ledger write loops disabled|customer seed disabled' \
  cmd/switch/switch.go cmd/switch/customer.go cmd/switch/runtime_write_gate.go

if ! grep -q 'r.Use(recoveryWriteGateMiddleware())' cmd/switch/switch.go; then
  echo "ERROR: recovery middleware not registered"
  restore_targets
  exit 1
fi
if ! grep -q 'if runtimeWritesAllowed.Load()' cmd/switch/switch.go; then
  echo "ERROR: startup worker gates missing"
  restore_targets
  exit 1
fi

echo "===== DIFF CHECK ====="
if ! git diff --check; then
  restore_targets
  exit 1
fi

echo "===== TARGETED TESTS ====="
if ! go test -count=1 -timeout=180s ./cmd/switch; then
  restore_targets
  exit 1
fi

echo "===== PHASE 4D SUMMARY ====="
git diff --stat -- cmd/switch/switch.go cmd/switch/customer.go
git status --short -- cmd/switch/switch.go cmd/switch/customer.go cmd/switch/runtime_write_gate.go cmd/switch/runtime_write_gate_test.go

echo "RESULT=PASS"
echo "Backup retained: $BACKUP"
echo "Report: $REPORT"
echo "DATABASE WRITES: NONE"
echo "RUNTIME RESTART: NONE"
echo "Operational behavior: HTTP mutations return 503; batcher and identified write-capable workers remain disabled. Structural checks alone never reopen writes; independent cryptographic history verification is still required. Read-only GET/HEAD/OPTIONS stay available."
