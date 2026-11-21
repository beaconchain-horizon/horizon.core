#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(pwd -P)"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_ROOT="${HOME}/horizon-v14-backups/phase3d-genesis-blocker-${STAMP}"
TMP_DIR="${BACKUP_ROOT}/tmp"
PATCHER_SRC="${TMP_DIR}/patcher.go"
PATCHER_BIN="${TMP_DIR}/patcher.exe"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ "$(basename "$ROOT")" == "horizon-core" ]] || fail "Run from the horizon-core repository root"
command -v go >/dev/null 2>&1 || fail "Go toolchain not found"
[[ "$(go env GOVERSION)" == "go1.24.4" ]] || fail "Expected Go 1.24.4; found $(go env GOVERSION)"

TARGETS=(
  "cmd/switch/switch.go"
  "cmd/switch/license_chain.go"
  "cmd/switch/license_chain_genesis_guard_test.go"
  "internal/chain/genesis.go"
)
for f in "${TARGETS[@]}"; do [[ -f "$f" ]] || fail "Required file missing: $f"; done
[[ ! -e cmd/switch/genesis_no_autocreate_test.go ]] || fail "cmd/switch/genesis_no_autocreate_test.go already exists; refusing to overwrite"
[[ ! -e internal/chain/genesis_no_autocreate_test.go ]] || fail "internal/chain/genesis_no_autocreate_test.go already exists; refusing to overwrite"

mkdir -p "$BACKUP_ROOT/source-before/cmd/switch" "$BACKUP_ROOT/source-before/internal/chain" "$TMP_DIR"
for f in "${TARGETS[@]}"; do
  mkdir -p "$BACKUP_ROOT/source-before/$(dirname "$f")"
  cp -p "$f" "$BACKUP_ROOT/source-before/$f"
done
(
  cd "$ROOT"
  sha256sum "${TARGETS[@]}" > "$BACKUP_ROOT/source-before/SHA256SUMS.txt"
)

echo "===== HORIZON v1.4 PHASE 3D — GENESIS AUTO-CREATION BLOCKER ====="
echo "Started: $(date -Iseconds)"
echo "Repository: $ROOT"
echo "Backup: $BACKUP_ROOT"
echo "Go: $(go version)"
echo "DATABASE ACCESS: NONE"
echo "RUNTIME RESTART: NONE"
echo "SOURCE BACKUP CHECKSUMS:"
cat "$BACKUP_ROOT/source-before/SHA256SUMS.txt"

cat > "$PATCHER_SRC" <<'GO'
package main

import (
    "fmt"
    "go/ast"
    "go/parser"
    "go/token"
    "os"
    "path/filepath"
)

func parse(path string) ([]byte, *token.FileSet, *ast.File, error) {
    src, err := os.ReadFile(path)
    if err != nil { return nil, nil, nil, err }
    fset := token.NewFileSet()
    file, err := parser.ParseFile(fset, path, src, parser.ParseComments)
    if err != nil { return nil, nil, nil, err }
    return src, fset, file, nil
}

func replaceFuncBody(path, name, body string) error {
    src, fset, file, err := parse(path)
    if err != nil { return err }
    found := 0
    var start, end int
    for _, decl := range file.Decls {
        fn, ok := decl.(*ast.FuncDecl)
        if !ok || fn.Recv != nil || fn.Name.Name != name || fn.Body == nil { continue }
        found++
        tf := fset.File(fn.Body.Lbrace)
        start = tf.Offset(fn.Body.Lbrace) + 1
        end = tf.Offset(fn.Body.Rbrace)
    }
    if found != 1 { return fmt.Errorf("%s: expected exactly one function %s, found %d", path, name, found) }
    replacement := append([]byte("\n"), []byte(body)...)
    replacement = append(replacement, '\n')
    out := make([]byte, 0, len(src)-(end-start)+len(replacement))
    out = append(out, src[:start]...)
    out = append(out, replacement...)
    out = append(out, src[end:]...)
    return os.WriteFile(path, out, 0644)
}

func replaceStandaloneCall(path, functionName, callName, replacement string) error {
    src, fset, file, err := parse(path)
    if err != nil { return err }
    var target *ast.FuncDecl
    for _, decl := range file.Decls {
        fn, ok := decl.(*ast.FuncDecl)
        if ok && fn.Recv == nil && fn.Name.Name == functionName { target = fn; break }
    }
    if target == nil { return fmt.Errorf("%s: function %s not found", path, functionName) }
    found := 0
    var start, end int
    ast.Inspect(target.Body, func(n ast.Node) bool {
        stmt, ok := n.(*ast.ExprStmt)
        if !ok { return true }
        call, ok := stmt.X.(*ast.CallExpr)
        if !ok || len(call.Args) != 0 { return true }
        ident, ok := call.Fun.(*ast.Ident)
        if !ok || ident.Name != callName { return true }
        found++
        tf := fset.File(stmt.Pos())
        start = tf.Offset(stmt.Pos())
        end = tf.Offset(stmt.End())
        return true
    })
    if found != 1 { return fmt.Errorf("%s: expected exactly one standalone %s() call in %s, found %d", path, callName, functionName, found) }
    out := make([]byte, 0, len(src)-(end-start)+len(replacement))
    out = append(out, src[:start]...)
    out = append(out, replacement...)
    out = append(out, src[end:]...)
    return os.WriteFile(path, out, 0644)
}

func replaceWholeFile(path, content string) error {
    return os.WriteFile(path, []byte(content), 0644)
}

func writeSwitchTests(root string) error {
    path := filepath.Join(root, "cmd/switch/genesis_no_autocreate_test.go")
    if _, err := os.Stat(path); err == nil { return fmt.Errorf("test file already exists: %s", path) }
    test := `package main

import (
    "testing"

    "github.com/glebarez/sqlite"
    "gorm.io/gorm"
)

func openGenesisNoCreateTestDB(t *testing.T) *gorm.DB {
    t.Helper()
    testDB, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
    if err != nil { t.Fatalf("open test db: %v", err) }
    sqlDB, err := testDB.DB()
    if err != nil { t.Fatalf("get sql db: %v", err) }
    t.Cleanup(func() { _ = sqlDB.Close() })
    return testDB
}

func TestGetLastBlockDoesNotCreateGenesisWhenEmpty(t *testing.T) {
    testDB := openGenesisNoCreateTestDB(t)
    if err := testDB.AutoMigrate(&Block{}); err != nil { t.Fatalf("prepare isolated schema: %v", err) }
    oldDB := db
    db = testDB
    t.Cleanup(func() { db = oldDB })

    block, err := getLastBlock()
    if err == nil { t.Fatal("expected empty ledger to return an error") }
    if block != nil { t.Fatalf("expected nil block, got %#v", block) }
    var count int64
    if err := testDB.Model(&Block{}).Count(&count).Error; err != nil { t.Fatal(err) }
    if count != 0 { t.Fatalf("getLastBlock created %d block(s); want zero", count) }
}

func TestCreateGenesisBlockAlwaysRefusesRuntimeBootstrap(t *testing.T) {
    t.Setenv(licenseChainGenesisBootstrapEnv, "true")
    block, err := createGenesisBlock(nil, nil)
    if err == nil { t.Fatal("runtime Genesis creation must remain disabled even when legacy opt-in is set") }
    if block != nil { t.Fatalf("expected nil block, got %#v", block) }
}

func TestInitLicenseChainDoesNotBootstrapEmptyRegistry(t *testing.T) {
    testDB := openGenesisNoCreateTestDB(t)
    if err := testDB.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil { t.Fatalf("prepare isolated schema: %v", err) }
    t.Setenv(licenseChainSchemaMigrationEnv, "")
    t.Setenv(licenseChainGenesisBootstrapEnv, "true")
    if err := initLicenseChain(testDB); err == nil { t.Fatal("expected empty license chain to fail closed") }
    var count int64
    if err := testDB.Model(&ChainBlock{}).Count(&count).Error; err != nil { t.Fatal(err) }
    if count != 0 { t.Fatalf("initLicenseChain created %d Genesis row(s); want zero", count) }
}

func TestEnsureChainGenesisDoesNotBootstrapEmptyRegistry(t *testing.T) {
    testDB := openGenesisNoCreateTestDB(t)
    if err := testDB.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil { t.Fatalf("prepare isolated schema: %v", err) }
    t.Setenv(licenseChainGenesisBootstrapEnv, "true")
    if err := ensureChainGenesis(testDB, nil); err == nil { t.Fatal("expected empty license chain to fail closed") }
    var count int64
    if err := testDB.Model(&ChainBlock{}).Count(&count).Error; err != nil { t.Fatal(err) }
    if count != 0 { t.Fatalf("ensureChainGenesis created %d Genesis row(s); want zero", count) }
}
`
    return os.WriteFile(path, []byte(test), 0644)
}

func writeChainTests(root string) error {
    path := filepath.Join(root, "internal/chain/genesis_no_autocreate_test.go")
    if _, err := os.Stat(path); err == nil { return fmt.Errorf("test file already exists: %s", path) }
    test := `package chain

import (
    "testing"
    "time"

    "github.com/glebarez/sqlite"
    "gorm.io/gorm"
)

func openLockedGenesisTestDB(t *testing.T) *gorm.DB {
    t.Helper()
    testDB, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
    if err != nil { t.Fatalf("open test db: %v", err) }
    sqlDB, err := testDB.DB()
    if err != nil { t.Fatalf("get sql db: %v", err) }
    t.Cleanup(func() { _ = sqlDB.Close() })
    return testDB
}

func TestEnsureGenesisDoesNotCreateWhenMissing(t *testing.T) {
    testDB := openLockedGenesisTestDB(t)
    if err := testDB.AutoMigrate(&Block{}); err != nil { t.Fatalf("prepare schema: %v", err) }
    block, err := EnsureGenesis(testDB, "ignored-public-key")
    if err == nil { t.Fatal("expected missing locked Genesis to fail closed") }
    if block != nil { t.Fatalf("expected nil block, got %#v", block) }
    var count int64
    if err := testDB.Model(&Block{}).Count(&count).Error; err != nil { t.Fatal(err) }
    if count != 0 { t.Fatalf("EnsureGenesis created %d row(s); want zero", count) }
}

func TestEnsureGenesisAcceptsExactLockedHeader(t *testing.T) {
    testDB := openLockedGenesisTestDB(t)
    if err := testDB.AutoMigrate(&Block{}); err != nil { t.Fatalf("prepare schema: %v", err) }
    ts := time.Unix(lockedV14GenesisUnixSeconds, 855252400).UTC()
    expected := Block{
        Number: 0,
        PreviousHash: lockedV14ZeroHash,
        MerkleRoot: lockedV14GenesisHash,
        MerkleType: "genesis",
        Timestamp: ts,
        TxCount: 0,
        BlockHash: lockedV14GenesisHash,
        CreatedAt: ts,
    }
    if err := testDB.Create(&expected).Error; err != nil { t.Fatalf("insert test fixture: %v", err) }
    got, err := EnsureGenesis(testDB, "ignored-public-key")
    if err != nil { t.Fatalf("exact locked Genesis should be accepted: %v", err) }
    if got.BlockHash != lockedV14GenesisHash { t.Fatalf("unexpected Genesis hash: %s", got.BlockHash) }
}

func TestEnsureGenesisRejectsTimestampMismatch(t *testing.T) {
    testDB := openLockedGenesisTestDB(t)
    if err := testDB.AutoMigrate(&Block{}); err != nil { t.Fatalf("prepare schema: %v", err) }
    ts := time.Unix(1794246431, 0).UTC()
    bad := Block{
        Number: 0,
        PreviousHash: lockedV14ZeroHash,
        MerkleRoot: lockedV14GenesisHash,
        MerkleType: "genesis",
        Timestamp: ts,
        TxCount: 0,
        BlockHash: lockedV14GenesisHash,
        CreatedAt: ts,
    }
    if err := testDB.Create(&bad).Error; err != nil { t.Fatalf("insert test fixture: %v", err) }
    if _, err := EnsureGenesis(testDB, "ignored-public-key"); err == nil {
        t.Fatal("expected Genesis with noncanonical timestamp to be rejected")
    }
}
`
    return os.WriteFile(path, []byte(test), 0644)
}

func main() {
    root, err := os.Getwd()
    must(err)
    sw := filepath.Join(root, "cmd/switch/switch.go")
    lc := filepath.Join(root, "cmd/switch/license_chain.go")
    oldTest := filepath.Join(root, "cmd/switch/license_chain_genesis_guard_test.go")

    must(replaceFuncBody(sw, "getLastBlock", `
    var b Block
    err := db.Order("block_num desc").First(&b).Error
    if err != nil {
        if err == gorm.ErrRecordNotFound {
            return nil, fmt.Errorf("main ledger has no Genesis; automatic Genesis creation is disabled: %w", err)
        }
        return nil, err
    }
    return &b, nil
`))
    must(replaceStandaloneCall(sw, "main", "getLastBlock", `if _, err := getLastBlock(); err != nil {
        log.Printf("[CHAIN] startup ledger preflight failed; no Genesis was created: %v", err)
    }`))

    must(replaceFuncBody(lc, "licenseChainGenesisBootstrapAllowed", `
    // Runtime Genesis bootstrap is permanently disabled. The legacy environment
    // variable is intentionally ignored; only an offline, verified import may
    // establish the locked v1.4 Genesis.
    return false
`))
    must(replaceFuncBody(lc, "createGenesisBlock", `
    return nil, fmt.Errorf("runtime license-chain Genesis creation is permanently disabled; use a separately audited import of the locked v1.4 Genesis artifact")
`))
    must(replaceFuncBody(lc, "initLicenseChain", `
    if err := migrateChain(db); err != nil {
        return err
    }
    var count int64
    if err := db.Model(&ChainBlock{}).Count(&count).Error; err != nil {
        return fmt.Errorf("license-chain startup count: %w", err)
    }
    if count == 0 {
        return fmt.Errorf("license chain is empty; dynamic Genesis creation is disabled")
    }
    chainLoaded = true
    return nil
`))
    must(replaceFuncBody(lc, "ensureChainGenesis", `
    if db == nil {
        return fmt.Errorf("license-chain Genesis check: nil database")
    }
    var count int64
    if err := db.Model(&ChainBlock{}).Count(&count).Error; err != nil {
        return fmt.Errorf("license-chain Genesis check: %w", err)
    }
    if count == 0 {
        return fmt.Errorf("license chain is empty; dynamic Genesis creation is disabled")
    }
    return nil
`))
    must(replaceFuncBody(oldTest, "TestLicenseChainSafetyGatesFailClosed", `
    schemaCases := []struct { value string; want bool }{
        {"", false}, {"false", false}, {"TRUE", false}, {"true", true},
    }
    for _, tc := range schemaCases {
        t.Run("schema_"+tc.value, func(t *testing.T) {
            t.Setenv(licenseChainSchemaMigrationEnv, tc.value)
            if got := licenseChainSchemaMigrationAllowed(); got != tc.want {
                t.Fatalf("schema migration gate = %v, want %v", got, tc.want)
            }
        })
    }
    for _, value := range []string{"", "false", "TRUE", "true"} {
        t.Run("genesis_never_enabled_"+value, func(t *testing.T) {
            t.Setenv(licenseChainGenesisBootstrapEnv, value)
            if licenseChainGenesisBootstrapAllowed() {
                t.Fatal("runtime Genesis bootstrap must never be enabled")
            }
        })
    }
`))

    chainFile := `package chain

import (
    "errors"
    "fmt"
    "time"

    "gorm.io/gorm"
)

// GenesisChainID is the immutable identifier for this protocol chain.
const GenesisChainID = "horizon-core-v1.4"

const (
    lockedV14GenesisHash = "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"
    lockedV14GenesisUnixSeconds = int64(1793472181)
    lockedV14ZeroHash = "0000000000000000000000000000000000000000000000000000000000000000"
)

// EnsureGenesis only loads an existing, exactly matching locked v1.4 Genesis.
// It never creates or rewrites Genesis at runtime.
func EnsureGenesis(db *gorm.DB, _ string) (*Block, error) {
    if db == nil {
        return nil, fmt.Errorf("Genesis verification: nil database")
    }
    var existing Block
    err := db.Where("number = ?", 0).First(&existing).Error
    if err != nil {
        if errors.Is(err, gorm.ErrRecordNotFound) {
            return nil, fmt.Errorf("locked v1.4 Genesis is absent; dynamic Genesis creation is disabled")
        }
        return nil, fmt.Errorf("Genesis lookup: %w", err)
    }
    if existing.Number != 0 ||
        existing.PreviousHash != lockedV14ZeroHash ||
        existing.MerkleRoot != lockedV14GenesisHash ||
        existing.BlockHash != lockedV14GenesisHash ||
        existing.TxCount != 0 ||
        !existing.Timestamp.Equal(time.Unix(lockedV14GenesisUnixSeconds, 855252400).UTC()) {
        return nil, fmt.Errorf("stored Genesis does not match the locked v1.4 header")
    }
    return &existing, nil
}

// LatestBlock returns the highest-numbered block.
func LatestBlock(db *gorm.DB) (*Block, error) {
    var b Block
    if err := db.Order("number DESC").First(&b).Error; err != nil {
        return nil, err
    }
    return &b, nil
}
`
    must(replaceWholeFile(filepath.Join(root, "internal/chain/genesis.go"), chainFile))
    must(writeSwitchTests(root))
    must(writeChainTests(root))
}

func must(err error) {
    if err != nil { fmt.Fprintln(os.Stderr, "PATCH ERROR:", err); os.Exit(1) }
}
GO

if ! go build -o "$PATCHER_BIN" "$PATCHER_SRC"; then
  fail "could not build temporary Go patcher"
fi
if ! "$PATCHER_BIN"; then
  echo "PATCH FAILED; restoring Phase 3D targets" >&2
  for f in "${TARGETS[@]}"; do cp -p "$BACKUP_ROOT/source-before/$f" "$f"; done
  rm -f cmd/switch/genesis_no_autocreate_test.go internal/chain/genesis_no_autocreate_test.go
  exit 1
fi

for f in cmd/switch/switch.go cmd/switch/license_chain.go cmd/switch/license_chain_genesis_guard_test.go cmd/switch/genesis_no_autocreate_test.go internal/chain/genesis.go internal/chain/genesis_no_autocreate_test.go; do
  gofmt -w "$f"
done

rollback() {
  local rc=$?
  echo "PATCH/TEST FAILED (exit=$rc); restoring Phase 3D targets" >&2
  for f in "${TARGETS[@]}"; do cp -p "$BACKUP_ROOT/source-before/$f" "$f"; done
  rm -f cmd/switch/genesis_no_autocreate_test.go internal/chain/genesis_no_autocreate_test.go
  echo "RESTORE=COMPLETED (Phase 3D files only)" >&2
  exit "$rc"
}
trap rollback ERR

echo "===== GENESIS AUTO-CREATION STATIC CHECK ====="
if grep -nE 'db\.Create\(genesis\)' cmd/switch/switch.go; then fail "dynamic main Genesis insert remains"; fi
if ! grep -q 'automatic Genesis creation is disabled' cmd/switch/switch.go; then fail "main Genesis creation refusal missing"; fi
if ! grep -q 'Runtime Genesis bootstrap is permanently disabled' cmd/switch/license_chain.go; then fail "license-chain Genesis bootstrap lock missing"; fi
if grep -nE 'sha256\.New|time\.Now\(\)\.UTC\(\)' internal/chain/genesis.go; then fail "dynamic Genesis calculation remains in internal/chain"; fi
if ! grep -q 'dynamic Genesis creation is disabled' internal/chain/genesis.go; then fail "internal/chain Genesis refusal missing"; fi
echo "PASS: Switch and internal/chain runtime Genesis creation paths are disabled"

echo "===== PATCH SUMMARY ====="
git diff --check
git diff --stat -- cmd/switch/switch.go cmd/switch/license_chain.go cmd/switch/license_chain_genesis_guard_test.go internal/chain/genesis.go

echo "===== TARGETED TESTS ====="
go test -count=1 -timeout=180s ./cmd/switch ./internal/chain

echo "===== FINAL DIFF CHECK ====="
git diff --check
trap - ERR

echo "RESULT=PASS"
echo "Backup retained: $BACKUP_ROOT"
echo "Runtime restart: NONE"
echo "Database writes: NONE"
