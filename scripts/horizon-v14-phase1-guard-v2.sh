#!/usr/bin/env bash
# Horizon v1.4 Phase 1 Guard v2
# - Does NOT modify any database.
# - Prevents accidental license-chain Genesis creation.
# - Disables automatic AutoMigrate unless explicitly opted in.
# - Keeps existing source files backed up and rolls back on test failure.
set -Eeuo pipefail

ROOT="${HORIZON_REPO:-$HOME/Beaconchain/horizon-core}"
BACKUP_ROOT="${HORIZON_BACKUP_ROOT:-$HOME/horizon-v14-backups}"
STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$BACKUP_ROOT/phase1-guard-v2-$STAMP"
SOURCE="cmd/switch/license_chain.go"
TEST="cmd/switch/license_chain_genesis_guard_test.go"
REPORT="$RUN_DIR/phase1-guard-v2-report.txt"

fail() { echo "ERROR: $*" >&2; exit 1; }
rollback() {
  echo "TEST FAILURE: restoring source from pre-patch backup."
  if [[ -f "$RUN_DIR/source-before/license_chain.go" ]]; then
    cp -p "$RUN_DIR/source-before/license_chain.go" "$ROOT/$SOURCE"
  fi
  rm -f "$ROOT/$TEST"
  echo "Rollback complete. Database was never accessed or modified."
}

mkdir -p "$RUN_DIR/source-before" "$RUN_DIR/patcher"
exec > >(tee -a "$REPORT") 2>&1

echo "===== HORIZON v1.4 PHASE 1 GUARD v2 ====="
echo "Started: $(date -Iseconds 2>/dev/null || date)"
echo "Repository: $ROOT"
echo "Backup/report: $RUN_DIR"
echo "DATABASE ACCESS: NONE"

cd "$ROOT" || fail "Repository not found"
git rev-parse --show-toplevel >/dev/null 2>&1 || fail "Not a Git repository"
GO_VERSION="$(go version 2>&1 || true)"
echo "Go: $GO_VERSION"
[[ "$GO_VERSION" == *"go1.24."* ]] || fail "Go 1.24.x is required; no toolchain changes will be made"
echo "Branch: $(git branch --show-current)"
echo "Commit: $(git rev-parse HEAD)"
echo "Initial status:"
git status --short

[[ -f "$SOURCE" ]] || fail "Missing $SOURCE"
if [[ -e "$TEST" ]]; then
  fail "$TEST already exists; refusing to overwrite it"
fi
cp -p "$SOURCE" "$RUN_DIR/source-before/license_chain.go"
sha256sum "$RUN_DIR/source-before/license_chain.go" | tee "$RUN_DIR/source-before.sha256"

cat > "$RUN_DIR/patcher/main.go" <<'GO'
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

func replaceOnce(src, pattern, replacement, label string) (string, error) {
	re := regexp.MustCompile(pattern)
	loc := re.FindStringIndex(src)
	if loc == nil {
		return src, fmt.Errorf("%s: source pattern not found", label)
	}
	if re.FindStringIndex(src[loc[1]:]) != nil {
		return src, fmt.Errorf("%s: source pattern is ambiguous (multiple matches)", label)
	}
	return src[:loc[0]] + re.ReplaceAllString(src[loc[0]:loc[1]], replacement) + src[loc[1]:], nil
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: patcher <repo-root> <run-dir>")
		os.Exit(2)
	}
	root, runDir := os.Args[1], os.Args[2]
	path := filepath.Join(root, "cmd", "switch", "license_chain.go")
	testPath := filepath.Join(root, "cmd", "switch", "license_chain_genesis_guard_test.go")
	original, err := os.ReadFile(path)
	if err != nil { panic(err) }
	wasCRLF := strings.Contains(string(original), "\r\n")
	s := strings.ReplaceAll(string(original), "\r\n", "\n")

	if strings.Contains(s, "licenseChainGenesisBootstrapAllowed") || strings.Contains(s, "licenseChainSchemaMigrationAllowed") {
		fmt.Fprintln(os.Stderr, "guard marker already exists; refusing to apply a duplicate patch")
		os.Exit(3)
	}
	if _, err := os.Stat(testPath); err == nil {
		fmt.Fprintln(os.Stderr, "guard test already exists; refusing to overwrite")
		os.Exit(3)
	}

	// Add the standard-library os import, retaining the existing import block.
	s, err = replaceOnce(s, `(?m)^\s*"log"\s*$`, "\t\"log\"\n\t\"os\"", "add os import")
	if err != nil { panic(err) }

	// Replace only the license-chain migration function. Existing schema is
	// accepted without mutation; missing tables cause a closed failure unless
	// an operator explicitly authorizes a fresh schema migration.
	migration := `func migrateChain(db *gorm.DB) error {
	if !licenseChainSchemaMigrationAllowed() {
		if !db.Migrator().HasTable(&ChainBlock{}) || !db.Migrator().HasTable(&ChainTx{}) {
			return fmt.Errorf("license-chain schema is incomplete; automatic migration is disabled; set %s=true only for an intentional migration", licenseChainSchemaMigrationEnv)
		}
		return nil
	}
	return db.AutoMigrate(&ChainBlock{}, &ChainTx{})
}`
	s, err = replaceOnce(s, `(?s)func migrateChain\(db \*gorm\.DB\) error \{.*?\n\}`, migration, "guard migrateChain")
	if err != nil { panic(err) }

	// Put the fail-closed gate inside the Genesis constructor itself so every
	// current and future caller is protected, not only the two known callers.
	genesisGuard := `func createGenesisBlock(db *gorm.DB, ownerKey *ecdsa.PrivateKey) (*ChainBlock, error) {
	if !licenseChainGenesisBootstrapAllowed() {
		return nil, fmt.Errorf("refusing to create a new license-chain Genesis; set %s=true only for an intentional fresh registry bootstrap", licenseChainGenesisBootstrapEnv)
	}`
	s, err = replaceOnce(s, `func createGenesisBlock\(db \*gorm\.DB, ownerKey \*ecdsa\.PrivateKey\) \(\*ChainBlock, error\) \{`, genesisGuard, "guard createGenesisBlock")
	if err != nil { panic(err) }

	helper := `const licenseChainSchemaMigrationEnv = "HORIZON_ALLOW_LICENSE_CHAIN_SCHEMA_MIGRATION"
const licenseChainGenesisBootstrapEnv = "HORIZON_ALLOW_LICENSE_CHAIN_GENESIS_BOOTSTRAP"

func licenseChainSchemaMigrationAllowed() bool {
	return os.Getenv(licenseChainSchemaMigrationEnv) == "true"
}

func licenseChainGenesisBootstrapAllowed() bool {
	return os.Getenv(licenseChainGenesisBootstrapEnv) == "true"
}

`
	s, err = replaceOnce(s, `func migrateChain\(db \*gorm\.DB\) error \{`, helper+"func migrateChain(db *gorm.DB) error {", "insert safety gates")
	if err != nil { panic(err) }

	if wasCRLF { s = strings.ReplaceAll(s, "\n", "\r\n") }
	if err := os.WriteFile(path, []byte(s), 0644); err != nil { panic(err) }

	testSource := `package main

import "testing"

func TestLicenseChainSafetyGatesFailClosed(t *testing.T) {
	cases := []struct {
		name  string
		value string
		want  bool
	}{
		{name: "unset", value: "", want: false},
		{name: "false", value: "false", want: false},
		{name: "uppercase is rejected", value: "TRUE", want: false},
		{name: "only exact true opts in", value: "true", want: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv(licenseChainSchemaMigrationEnv, tc.value)
			t.Setenv(licenseChainGenesisBootstrapEnv, tc.value)
			if got := licenseChainSchemaMigrationAllowed(); got != tc.want {
				t.Fatalf("schema migration gate = %v, want %v", got, tc.want)
			}
			if got := licenseChainGenesisBootstrapAllowed(); got != tc.want {
				t.Fatalf("Genesis bootstrap gate = %v, want %v", got, tc.want)
			}
		})
	}
}
`
	if err := os.WriteFile(testPath, []byte(testSource), 0644); err != nil { panic(err) }
	fmt.Printf("Patched %s; created %s\n", path, testPath)
	fmt.Printf("Original source backup directory: %s\n", filepath.Join(runDir, "source-before"))
}
GO

# Compile and run the patcher. Source remains backed up before this point.
if ! go run "$RUN_DIR/patcher/main.go" "$ROOT" "$RUN_DIR"; then
  rollback
  fail "Patch generation failed; source restored. See $REPORT"
fi

# Format and ensure whitespace / syntax-level hygiene.
if ! gofmt -w "$SOURCE" "$TEST"; then
  rollback
  fail "gofmt failed; source restored. See $REPORT"
fi
if ! git diff --check; then
  rollback
  fail "git diff --check failed; source restored. See $REPORT"
fi

# Required safety invariants.
grep -q 'licenseChainGenesisBootstrapAllowed' "$SOURCE" || { rollback; fail "Genesis guard not present"; }
grep -q 'licenseChainSchemaMigrationAllowed' "$SOURCE" || { rollback; fail "Schema guard not present"; }
grep -q 'db.AutoMigrate(&ChainBlock{}, &ChainTx{})' "$SOURCE" || { rollback; fail "Explicit migration path not present"; }

# Tests compile the complete switch package but execute only the new guard tests.
echo "===== SWITCH GENESIS GUARD TEST ====="
if ! go test -count=1 -timeout=180s -run '^TestLicenseChainSafetyGatesFailClosed$' ./cmd/switch; then
  rollback
  fail "Switch guard test failed; source restored. See $REPORT"
fi

echo "===== CRYPTO / WOTS / MERKLE REGRESSION TESTS ====="
if ! go test -count=1 -timeout=180s ./internal/crypto ./internal/crypto/wots ./internal/merkle; then
  rollback
  fail "Crypto/Merkle regression tests failed; source restored. See $REPORT"
fi

echo "===== SOURCE DIFF SUMMARY ====="
git diff --stat -- "$SOURCE" "$TEST"
git diff --check

echo "===== FINAL STATUS ====="
git status --short
printf '\nRESULT=PASS\n'
echo "Genesis creation is fail-closed unless explicitly opted in."
echo "Automatic license-chain schema migration is disabled by default."
echo "No PostgreSQL/SQLite database was accessed or modified."
echo "Backup: $RUN_DIR/source-before"
echo "Report: $REPORT"
echo "Do not set either override on an existing production database:"
echo "  HORIZON_ALLOW_LICENSE_CHAIN_SCHEMA_MIGRATION=true"
echo "  HORIZON_ALLOW_LICENSE_CHAIN_GENESIS_BOOTSTRAP=true"
