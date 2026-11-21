#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" || ! -f "$ROOT/go.mod" ]]; then
  echo "ERROR: run this script from inside horizon-core repository" >&2
  exit 1
fi
cd "$ROOT"

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_ROOT="${HOME}/horizon-v14-backups/phase3-write-gate-${STAMP}"
mkdir -p "$BACKUP_ROOT/source-before"
REPORT="$BACKUP_ROOT/phase3-write-gate-report.txt"
exec > >(tee "$REPORT") 2>&1

CREATED_GUARD=0
CREATED_TEST=0

restore_on_failure() {
  rc=$?
  if [[ $rc -ne 0 && -d "$BACKUP_ROOT/source-before" ]]; then
    echo "ERROR: phase 3 failed (exit=$rc); restoring touched source files from backup."
    for f in cmd/switch/switch.go cmd/switch/license_chain.go; do
      if [[ -f "$BACKUP_ROOT/source-before/$f" ]]; then
        cp -p "$BACKUP_ROOT/source-before/$f" "$f"
      fi
    done
    if [[ "$CREATED_GUARD" == "1" ]]; then rm -f cmd/switch/canonical_write_guard.go; fi
    if [[ "$CREATED_TEST" == "1" ]]; then rm -f cmd/switch/canonical_write_guard_test.go; fi
    echo "RESTORE=COMPLETED"
  fi
  exit "$rc"
}
trap restore_on_failure EXIT

printf '%s\n' '===== HORIZON v1.4 PHASE 3 — CANONICAL WRITE GATE ====='
echo "Started: $(date --iso-8601=seconds 2>/dev/null || date)"
echo "Repository: $ROOT"
echo "Backup/report: $BACKUP_ROOT"
echo "Go: $(go version)"
echo "Branch: $(git branch --show-current)"
echo "Commit: $(git rev-parse HEAD)"
echo "DATABASE ACCESS: NONE"
echo "RUNTIME RESTART: NONE"

if [[ "$(go env GOVERSION)" != go1.24* ]]; then
  echo "ERROR: expected Go 1.24.x; found $(go env GOVERSION)" >&2
  exit 1
fi

for f in cmd/switch/switch.go cmd/switch/license_chain.go; do
  [[ -f "$f" ]] || { echo "ERROR: missing $f"; exit 1; }
  cp -p "$f" "$BACKUP_ROOT/source-before/$f"
done

for f in cmd/switch/canonical_write_guard.go cmd/switch/canonical_write_guard_test.go; do
  if [[ -e "$f" ]]; then
    echo "ERROR: refusing to overwrite existing file: $f" >&2
    exit 1
  fi
done

# Fail closed if source has drifted from the reviewed call sites.
grep -Fq 'func mineBlock() (*Block, error) {' cmd/switch/switch.go || { echo 'ERROR: mineBlock anchor not found'; exit 1; }
grep -Fq 'func mineBlockHandler(c *gin.Context) {' cmd/switch/switch.go || { echo 'ERROR: mineBlockHandler anchor not found'; exit 1; }
grep -Fq 'func addChainBlock(db *gorm.DB, ownerKey *ecdsa.PrivateKey, txs []ChainTx) (*ChainBlock, error) {' cmd/switch/license_chain.go || { echo 'ERROR: addChainBlock anchor not found'; exit 1; }
grep -Fq 'db.AutoMigrate(&Block{}, &Transaction{}, &License{}, &KeyVault{}, &BankAccount{}, &Account{}, &Invoice{}, &Customer{})' cmd/switch/switch.go || { echo 'ERROR: startup AutoMigrate anchor not found'; exit 1; }

CREATED_GUARD=1
cat > cmd/switch/canonical_write_guard.go <<'GO'
package main

import (
	"fmt"
	"os"
	"strings"

	"gorm.io/gorm"
)

const (
	lockedV14GenesisHash         = "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"
	lockedV14GenesisUnixSeconds  = int64(1793472181)
	lockedV14ZeroHash            = "0000000000000000000000000000000000000000000000000000000000000000"
	switchSchemaMigrationEnv     = "HORIZON_ALLOW_SWITCH_SCHEMA_MIGRATION"
)

// ensureSwitchSchema refuses implicit production schema changes. Existing
// tables are checked without altering them. Explicit migration remains opt-in.
func ensureSwitchSchema(db *gorm.DB, models ...interface{}) error {
	if db == nil {
		return fmt.Errorf("switch schema preflight: nil database")
	}
	if os.Getenv(switchSchemaMigrationEnv) == "true" {
		return db.AutoMigrate(models...)
	}
	missing := make([]string, 0)
	for _, model := range models {
		if !db.Migrator().HasTable(model) {
			missing = append(missing, fmt.Sprintf("%T", model))
		}
	}
	if len(missing) != 0 {
		return fmt.Errorf("switch schema incomplete; automatic migration is disabled; missing models: %s", strings.Join(missing, ", "))
	}
	return nil
}

// validateMainBlockChainForWrite prevents new blocks being appended to a
// database whose Genesis or existing height/link sequence differs from the
// locked v1.4 reference. It deliberately does not rewrite or repair history.
func validateMainBlockChainForWrite(db *gorm.DB) error {
	if db == nil || !db.Migrator().HasTable(&Block{}) {
		return fmt.Errorf("canonical write gate: main blocks table unavailable")
	}
	var blocks []Block
	if err := db.Order("block_num ASC").Find(&blocks).Error; err != nil {
		return fmt.Errorf("canonical write gate: read main block history: %w", err)
	}
	if len(blocks) == 0 {
		return fmt.Errorf("canonical write gate: no locked Genesis is present; fresh Genesis creation is disabled")
	}
	g := blocks[0]
	if g.BlockNum != 0 || g.Hash != lockedV14GenesisHash || g.MerkleRoot != lockedV14GenesisHash ||
		g.PrevHash != lockedV14ZeroHash || g.TxCount != 0 || g.Timestamp != lockedV14GenesisUnixSeconds {
		return fmt.Errorf("canonical write gate: main Genesis does not exactly match locked v1.4 header fields")
	}
	for i := range blocks {
		if blocks[i].BlockNum != i {
			return fmt.Errorf("canonical write gate: non-sequential main block height at position %d (stored=%d)", i, blocks[i].BlockNum)
		}
		if i > 0 && blocks[i].PrevHash != blocks[i-1].Hash {
			return fmt.Errorf("canonical write gate: broken main-chain link at height %d", blocks[i].BlockNum)
		}
	}
	return nil
}

// validateLicenseChainForWrite stops license-chain appends until its Genesis,
// block links, and persisted transaction counts reconcile with v1.4 and with
// one another. It is read-only and does not repair legacy rows.
func validateLicenseChainForWrite(db *gorm.DB) error {
	if db == nil || !db.Migrator().HasTable(&ChainBlock{}) || !db.Migrator().HasTable(&ChainTx{}) {
		return fmt.Errorf("license-chain write gate: required tables unavailable")
	}
	var blocks []ChainBlock
	if err := db.Order("block_num ASC").Find(&blocks).Error; err != nil {
		return fmt.Errorf("license-chain write gate: read block history: %w", err)
	}
	if len(blocks) == 0 {
		return fmt.Errorf("license-chain write gate: no locked Genesis is present; bootstrap is disabled")
	}
	g := blocks[0]
	if g.BlockNum != 0 || g.Hash != lockedV14GenesisHash || g.MerkleRoot != lockedV14GenesisHash ||
		g.PrevHash != lockedV14ZeroHash || g.TxCount != 0 || g.Timestamp != lockedV14GenesisUnixSeconds {
		return fmt.Errorf("license-chain write gate: Genesis header does not exactly match locked v1.4 reference")
	}
	for i := range blocks {
		if blocks[i].BlockNum != int64(i) {
			return fmt.Errorf("license-chain write gate: non-sequential block height at position %d (stored=%d)", i, blocks[i].BlockNum)
		}
		if i > 0 && blocks[i].PrevHash != blocks[i-1].Hash {
			return fmt.Errorf("license-chain write gate: broken block link at height %d", blocks[i].BlockNum)
		}
	}
	var mismatchedCounts int64
	if err := db.Table("chain_blocks AS cb").
		Where("cb.tx_count <> (SELECT COUNT(*) FROM chain_txes AS ct WHERE ct.block_num = cb.block_num)").
		Count(&mismatchedCounts).Error; err != nil {
		return fmt.Errorf("license-chain write gate: compare block transaction counts: %w", err)
	}
	if mismatchedCounts != 0 {
		return fmt.Errorf("license-chain write gate: %d blocks have tx_count inconsistent with chain_txes", mismatchedCounts)
	}
	var orphanTransactions int64
	if err := db.Table("chain_txes AS ct").
		Joins("LEFT JOIN chain_blocks AS cb ON cb.block_num = ct.block_num").
		Where("cb.id IS NULL").Count(&orphanTransactions).Error; err != nil {
		return fmt.Errorf("license-chain write gate: find unlinked transactions: %w", err)
	}
	if orphanTransactions != 0 {
		return fmt.Errorf("license-chain write gate: %d transactions have no matching chain block", orphanTransactions)
	}
	return nil
}
GO

CREATED_TEST=1
cat > cmd/switch/canonical_write_guard_test.go <<'GO'
package main

import (
	"strings"
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func openCanonicalGuardTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open in-memory sqlite: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get sql db: %v", err)
	}
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })
	return db
}

func canonicalGuardGenesisBlock() Block {
	return Block{
		BlockNum: 0, Timestamp: lockedV14GenesisUnixSeconds,
		PrevHash: lockedV14ZeroHash, Hash: lockedV14GenesisHash,
		MerkleRoot: lockedV14GenesisHash, TxCount: 0,
		Signature: strings.Repeat("a", 128), SignerAddr: "test-authority",
	}
}

func canonicalGuardGenesisChainBlock() ChainBlock {
	return ChainBlock{
		BlockNum: 0, Timestamp: lockedV14GenesisUnixSeconds,
		PrevHash: lockedV14ZeroHash, Hash: lockedV14GenesisHash,
		MerkleRoot: lockedV14GenesisHash, TxCount: 0,
		Signature: strings.Repeat("a", 128), SignerAddr: "test-authority",
	}
}

func TestEnsureSwitchSchemaFailsClosedWhenTableMissing(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := ensureSwitchSchema(db, &Block{}); err == nil {
		t.Fatal("expected missing schema to fail closed")
	}
	if err := db.AutoMigrate(&Block{}); err != nil {
		t.Fatalf("prepare fixture: %v", err)
	}
	if err := ensureSwitchSchema(db, &Block{}); err != nil {
		t.Fatalf("existing table should pass without migration: %v", err)
	}
}

func TestMainChainWriteGateAcceptsOnlyLockedGenesis(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := db.AutoMigrate(&Block{}); err != nil { t.Fatal(err) }
	g := canonicalGuardGenesisBlock()
	if err := db.Create(&g).Error; err != nil { t.Fatal(err) }
	if err := validateMainBlockChainForWrite(db); err != nil {
		t.Fatalf("canonical Genesis-only chain should pass: %v", err)
	}
}

func TestMainChainWriteGateRejectsTimestampMismatch(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := db.AutoMigrate(&Block{}); err != nil { t.Fatal(err) }
	g := canonicalGuardGenesisBlock()
	g.Timestamp++
	if err := db.Create(&g).Error; err != nil { t.Fatal(err) }
	if err := validateMainBlockChainForWrite(db); err == nil || !strings.Contains(err.Error(), "Genesis") {
		t.Fatalf("expected Genesis mismatch, got: %v", err)
	}
}

func TestMainChainWriteGateRejectsBrokenLink(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := db.AutoMigrate(&Block{}); err != nil { t.Fatal(err) }
	g := canonicalGuardGenesisBlock()
	if err := db.Create(&g).Error; err != nil { t.Fatal(err) }
	b1 := Block{BlockNum: 1, Timestamp: lockedV14GenesisUnixSeconds + 1,
		PrevHash: strings.Repeat("9", 64), Hash: strings.Repeat("b", 64),
		MerkleRoot: strings.Repeat("c", 64), TxCount: 1}
	if err := db.Create(&b1).Error; err != nil { t.Fatal(err) }
	if err := validateMainBlockChainForWrite(db); err == nil || !strings.Contains(err.Error(), "broken main-chain link") {
		t.Fatalf("expected broken link, got: %v", err)
	}
}

func TestLicenseChainWriteGateRejectsGenesisTimestampMismatch(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := db.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil { t.Fatal(err) }
	g := canonicalGuardGenesisChainBlock()
	g.Timestamp++
	if err := db.Create(&g).Error; err != nil { t.Fatal(err) }
	if err := validateLicenseChainForWrite(db); err == nil || !strings.Contains(err.Error(), "Genesis header") {
		t.Fatalf("expected license Genesis mismatch, got: %v", err)
	}
}

func TestLicenseChainWriteGateRejectsTxCountMismatch(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := db.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil { t.Fatal(err) }
	g := canonicalGuardGenesisChainBlock()
	if err := db.Create(&g).Error; err != nil { t.Fatal(err) }
	b1 := ChainBlock{BlockNum: 1, Timestamp: lockedV14GenesisUnixSeconds + 1,
		PrevHash: lockedV14GenesisHash, Hash: strings.Repeat("b", 64),
		MerkleRoot: strings.Repeat("c", 64), TxCount: 1,
		Signature: strings.Repeat("a", 128), SignerAddr: "test-authority"}
	if err := db.Create(&b1).Error; err != nil { t.Fatal(err) }
	if err := validateLicenseChainForWrite(db); err == nil || !strings.Contains(err.Error(), "tx_count inconsistent") {
		t.Fatalf("expected tx count mismatch, got: %v", err)
	}
}

func TestLicenseChainWriteGateAcceptsConsistentGenesisOnly(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := db.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil { t.Fatal(err) }
	g := canonicalGuardGenesisChainBlock()
	if err := db.Create(&g).Error; err != nil { t.Fatal(err) }
	if err := validateLicenseChainForWrite(db); err != nil {
		t.Fatalf("canonical Genesis-only license chain should pass: %v", err)
	}
}
GO

# Apply precise, one-time source edits via a Go stdlib patcher. It preserves
# the file's existing newline convention and refuses ambiguous replacements.
PATCHER="$BACKUP_ROOT/patch_source.go"
cat > "$PATCHER" <<'GO'
package main
import (
	"fmt"
	"os"
	"strings"
)
type edit struct { path, old, replacement string }
func main() {
	root := os.Args[1]
	edits := []edit{
		{"cmd/switch/switch.go", "func mineBlock() (*Block, error) {\n", "func mineBlock() (*Block, error) {\n\tif err := validateMainBlockChainForWrite(db); err != nil { return nil, err }\n"},
		{"cmd/switch/switch.go", "func mineBlockHandler(c *gin.Context) {\n", "func mineBlockHandler(c *gin.Context) {\n\tif err := validateMainBlockChainForWrite(db); err != nil { c.JSON(http.StatusServiceUnavailable, gin.H{\"error\": \"block production paused by canonical v1.4 safety gate\", \"reason\": err.Error()}); return }\n"},
		{"cmd/switch/switch.go", "\tif err := db.AutoMigrate(&Block{}, &Transaction{}, &License{}, &KeyVault{}, &BankAccount{}, &Account{}, &Invoice{}, &Customer{}); err != nil {\n\t\tlog.Fatal(\"Migration failed:\", err)\n\t}\n", "\tif err := ensureSwitchSchema(db, &Block{}, &Transaction{}, &License{}, &KeyVault{}, &BankAccount{}, &Account{}, &Invoice{}, &Customer{}); err != nil {\n\t\tlog.Fatal(\"Schema preflight failed:\", err)\n\t}\n"},
		{"cmd/switch/license_chain.go", "func addChainBlock(db *gorm.DB, ownerKey *ecdsa.PrivateKey, txs []ChainTx) (*ChainBlock, error) {\n\tchainMutex.Lock()\n", "func addChainBlock(db *gorm.DB, ownerKey *ecdsa.PrivateKey, txs []ChainTx) (*ChainBlock, error) {\n\tchainMutex.Lock()\n\tif err := validateLicenseChainForWrite(db); err != nil { chainMutex.Unlock(); return nil, err }\n"},
	}
	for _, e := range edits {
		p := root + "/" + e.path
		b, err := os.ReadFile(p); if err != nil { panic(err) }
		crlf := strings.Contains(string(b), "\r\n")
		s := strings.ReplaceAll(string(b), "\r\n", "\n")
		if strings.Count(s, e.old) != 1 { panic(fmt.Sprintf("%s: expected exactly one anchor, found %d", e.path, strings.Count(s, e.old))) }
		s = strings.Replace(s, e.old, e.replacement, 1)
		if crlf { s = strings.ReplaceAll(s, "\n", "\r\n") }
		if err := os.WriteFile(p, []byte(s), 0644); err != nil { panic(err) }
		fmt.Println("PATCHED", e.path)
	}
}
GO

echo "===== APPLY SOURCE PATCHES ====="
go run "$PATCHER" "$ROOT"

echo "===== FORMAT NEW AND MODIFIED GO FILES ====="
gofmt -w cmd/switch/canonical_write_guard.go cmd/switch/canonical_write_guard_test.go cmd/switch/switch.go cmd/switch/license_chain.go

echo "===== DIFF CHECK ====="
git diff --check

echo "===== TARGETED TESTS ====="
go test -count=1 -timeout=180s ./cmd/switch

echo "===== STATIC GUARD MARKERS ====="
grep -nE 'validateMainBlockChainForWrite|validateLicenseChainForWrite|ensureSwitchSchema' cmd/switch/{switch.go,license_chain.go,canonical_write_guard.go}

echo "===== PATCH SUMMARY ====="
git diff --stat -- cmd/switch/switch.go cmd/switch/license_chain.go cmd/switch/canonical_write_guard.go cmd/switch/canonical_write_guard_test.go

printf '\nRESULT=PASS\n'
echo "Backup retained: $BACKUP_ROOT"
echo "Report: $REPORT"
echo "Operational note: block mining and license-chain appends now fail closed until the stored ledgers reconcile with locked v1.4 Genesis and transaction counts."

trap - EXIT
