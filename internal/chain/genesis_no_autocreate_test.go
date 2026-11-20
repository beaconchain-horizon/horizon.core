package chain

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func openLockedGenesisTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	testDB, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open test db: %v", err)
	}
	sqlDB, err := testDB.DB()
	if err != nil {
		t.Fatalf("get sql db: %v", err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	return testDB
}

func TestEnsureGenesisDoesNotCreateWhenMissing(t *testing.T) {
	testDB := openLockedGenesisTestDB(t)
	if err := testDB.AutoMigrate(&Block{}); err != nil {
		t.Fatalf("prepare schema: %v", err)
	}
	block, err := EnsureGenesis(testDB, "ignored-public-key")
	if err == nil {
		t.Fatal("expected missing locked Genesis to fail closed")
	}
	if block != nil {
		t.Fatalf("expected nil block, got %#v", block)
	}
	var count int64
	if err := testDB.Model(&Block{}).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("EnsureGenesis created %d row(s); want zero", count)
	}
}

func TestEnsureGenesisAcceptsExactLockedHeader(t *testing.T) {
	testDB := openLockedGenesisTestDB(t)
	if err := testDB.AutoMigrate(&Block{}); err != nil {
		t.Fatalf("prepare schema: %v", err)
	}
	ts := time.Unix(lockedV14GenesisUnixSeconds, 855252400).UTC()
	expected := Block{
		Number:       0,
		PreviousHash: lockedV14ZeroHash,
		MerkleRoot:   lockedV14GenesisHash,
		MerkleType:   "genesis",
		Timestamp:    ts,
		TxCount:      0,
		BlockHash:    lockedV14GenesisHash,
		CreatedAt:    ts,
	}
	if err := testDB.Create(&expected).Error; err != nil {
		t.Fatalf("insert test fixture: %v", err)
	}
	got, err := EnsureGenesis(testDB, "ignored-public-key")
	if err != nil {
		t.Fatalf("exact locked Genesis should be accepted: %v", err)
	}
	if got.BlockHash != lockedV14GenesisHash {
		t.Fatalf("unexpected Genesis hash: %s", got.BlockHash)
	}
}

func TestEnsureGenesisRejectsTimestampMismatch(t *testing.T) {
	testDB := openLockedGenesisTestDB(t)
	if err := testDB.AutoMigrate(&Block{}); err != nil {
		t.Fatalf("prepare schema: %v", err)
	}
	ts := time.Unix(1794246431, 0).UTC()
	bad := Block{
		Number:       0,
		PreviousHash: lockedV14ZeroHash,
		MerkleRoot:   lockedV14GenesisHash,
		MerkleType:   "genesis",
		Timestamp:    ts,
		TxCount:      0,
		BlockHash:    lockedV14GenesisHash,
		CreatedAt:    ts,
	}
	if err := testDB.Create(&bad).Error; err != nil {
		t.Fatalf("insert test fixture: %v", err)
	}
	if _, err := EnsureGenesis(testDB, "ignored-public-key"); err == nil {
		t.Fatal("expected Genesis with noncanonical timestamp to be rejected")
	}
}
