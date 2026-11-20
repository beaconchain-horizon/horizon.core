package main

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func openGenesisNoCreateTestDB(t *testing.T) *gorm.DB {
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

func TestGetLastBlockDoesNotCreateGenesisWhenEmpty(t *testing.T) {
	testDB := openGenesisNoCreateTestDB(t)
	if err := testDB.AutoMigrate(&Block{}); err != nil {
		t.Fatalf("prepare isolated schema: %v", err)
	}
	oldDB := db
	db = testDB
	t.Cleanup(func() { db = oldDB })

	block, err := getLastBlock()
	if err == nil {
		t.Fatal("expected empty ledger to return an error")
	}
	if block != nil {
		t.Fatalf("expected nil block, got %#v", block)
	}
	var count int64
	if err := testDB.Model(&Block{}).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("getLastBlock created %d block(s); want zero", count)
	}
}

func TestCreateGenesisBlockAlwaysRefusesRuntimeBootstrap(t *testing.T) {
	t.Setenv(licenseChainGenesisBootstrapEnv, "true")
	block, err := createGenesisBlock(nil, nil)
	if err == nil {
		t.Fatal("runtime Genesis creation must remain disabled even when legacy opt-in is set")
	}
	if block != nil {
		t.Fatalf("expected nil block, got %#v", block)
	}
}

func TestInitLicenseChainDoesNotBootstrapEmptyRegistry(t *testing.T) {
	testDB := openGenesisNoCreateTestDB(t)
	if err := testDB.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil {
		t.Fatalf("prepare isolated schema: %v", err)
	}
	t.Setenv(licenseChainSchemaMigrationEnv, "")
	t.Setenv(licenseChainGenesisBootstrapEnv, "true")
	if err := initLicenseChain(testDB); err == nil {
		t.Fatal("expected empty license chain to fail closed")
	}
	var count int64
	if err := testDB.Model(&ChainBlock{}).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("initLicenseChain created %d Genesis row(s); want zero", count)
	}
}

func TestEnsureChainGenesisDoesNotBootstrapEmptyRegistry(t *testing.T) {
	testDB := openGenesisNoCreateTestDB(t)
	if err := testDB.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil {
		t.Fatalf("prepare isolated schema: %v", err)
	}
	t.Setenv(licenseChainGenesisBootstrapEnv, "true")
	if err := ensureChainGenesis(testDB, nil); err == nil {
		t.Fatal("expected empty license chain to fail closed")
	}
	var count int64
	if err := testDB.Model(&ChainBlock{}).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("ensureChainGenesis created %d Genesis row(s); want zero", count)
	}
}
