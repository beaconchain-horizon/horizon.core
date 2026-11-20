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
	if err := db.AutoMigrate(&Block{}); err != nil {
		t.Fatal(err)
	}
	g := canonicalGuardGenesisBlock()
	if err := db.Create(&g).Error; err != nil {
		t.Fatal(err)
	}
	if err := validateMainBlockChainForWrite(db); err != nil {
		t.Fatalf("canonical Genesis-only chain should pass: %v", err)
	}
}

func TestMainChainWriteGateRejectsTimestampMismatch(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := db.AutoMigrate(&Block{}); err != nil {
		t.Fatal(err)
	}
	g := canonicalGuardGenesisBlock()
	g.Timestamp++
	if err := db.Create(&g).Error; err != nil {
		t.Fatal(err)
	}
	if err := validateMainBlockChainForWrite(db); err == nil || !strings.Contains(err.Error(), "Genesis") {
		t.Fatalf("expected Genesis mismatch, got: %v", err)
	}
}

func TestMainChainWriteGateRejectsBrokenLink(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := db.AutoMigrate(&Block{}); err != nil {
		t.Fatal(err)
	}
	g := canonicalGuardGenesisBlock()
	if err := db.Create(&g).Error; err != nil {
		t.Fatal(err)
	}
	b1 := Block{BlockNum: 1, Timestamp: lockedV14GenesisUnixSeconds + 1,
		PrevHash: strings.Repeat("9", 64), Hash: strings.Repeat("b", 64),
		MerkleRoot: strings.Repeat("c", 64), TxCount: 1}
	if err := db.Create(&b1).Error; err != nil {
		t.Fatal(err)
	}
	if err := validateMainBlockChainForWrite(db); err == nil || !strings.Contains(err.Error(), "broken main-chain link") {
		t.Fatalf("expected broken link, got: %v", err)
	}
}

func TestLicenseChainWriteGateRejectsGenesisTimestampMismatch(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := db.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil {
		t.Fatal(err)
	}
	g := canonicalGuardGenesisChainBlock()
	g.Timestamp++
	if err := db.Create(&g).Error; err != nil {
		t.Fatal(err)
	}
	if err := validateLicenseChainForWrite(db); err == nil || !strings.Contains(err.Error(), "Genesis header") {
		t.Fatalf("expected license Genesis mismatch, got: %v", err)
	}
}

func TestLicenseChainWriteGateRejectsTxCountMismatch(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := db.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil {
		t.Fatal(err)
	}
	g := canonicalGuardGenesisChainBlock()
	if err := db.Create(&g).Error; err != nil {
		t.Fatal(err)
	}
	b1 := ChainBlock{BlockNum: 1, Timestamp: lockedV14GenesisUnixSeconds + 1,
		PrevHash: lockedV14GenesisHash, Hash: strings.Repeat("b", 64),
		MerkleRoot: strings.Repeat("c", 64), TxCount: 1,
		Signature: strings.Repeat("a", 128), SignerAddr: "test-authority"}
	if err := db.Create(&b1).Error; err != nil {
		t.Fatal(err)
	}
	if err := validateLicenseChainForWrite(db); err == nil || !strings.Contains(err.Error(), "tx_count inconsistent") {
		t.Fatalf("expected tx count mismatch, got: %v", err)
	}
}

func TestLicenseChainWriteGateAcceptsConsistentGenesisOnly(t *testing.T) {
	db := openCanonicalGuardTestDB(t)
	if err := db.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil {
		t.Fatal(err)
	}
	g := canonicalGuardGenesisChainBlock()
	if err := db.Create(&g).Error; err != nil {
		t.Fatal(err)
	}
	if err := validateLicenseChainForWrite(db); err != nil {
		t.Fatalf("canonical Genesis-only license chain should pass: %v", err)
	}
}
