package main

import (
	"crypto/ecdsa"
	"testing"

	internalcrypto "horizon-core/internal/crypto"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func openUnifiedWriterTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+t.Name()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open in-memory test database: %v", err)
	}
	if err := db.AutoMigrate(&ChainBlock{}, &ChainTx{}, &License{}); err != nil {
		t.Fatalf("migrate isolated test schema: %v", err)
	}
	genesis := ChainBlock{
		BlockNum: 0, PrevHash: lockedV14ZeroHash, MerkleRoot: lockedV14GenesisHash,
		TxCount: 0, Timestamp: lockedV14GenesisUnixSeconds, Hash: lockedV14GenesisHash,
	}
	if err := db.Create(&genesis).Error; err != nil {
		t.Fatalf("insert locked genesis fixture: %v", err)
	}
	return db
}

func testOrganizationSigningKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := internalcrypto.Secp256k1PrivateKeyFromHex("0000000000000000000000000000000000000000000000000000000000000001")
	if err != nil {
		t.Fatalf("load deterministic test key: %v", err)
	}
	return key
}

func testLicense(id string) OrganizationLicenseInput {
	return OrganizationLicenseInput{
		LicenseID: id, UserID: "user-"+id, ProductID: "horizon-core",
		Volume: 10, Duration: 30, Signature: "test-signature",
		IssuedAt: 100, ExpiresAt: 200, LicenseType: "client",
	}
}

func TestOrganizationBlockWriterRejectsInvalidPreconditions(t *testing.T) {
	if _, err := CreateOrganizationBlockWithLicenses(nil, nil, "org-a", nil); err == nil || err.Error() != "unified writer: nil database" {
		t.Fatalf("expected nil database rejection, got %v", err)
	}

	db := openUnifiedWriterTestDB(t)
	if _, err := CreateOrganizationBlockWithLicenses(db, nil, "org-a", nil); err == nil || err.Error() != "unified writer: signing key is locked" {
		t.Fatalf("expected locked signing key rejection, got %v", err)
	}
	if _, err := CreateOrganizationBlockWithLicenses(db, testOrganizationSigningKey(t), "", nil); err == nil || err.Error() != "unified writer: organization_id is required" {
		t.Fatalf("expected missing organization rejection, got %v", err)
	}
	if _, err := CreateOrganizationBlockWithLicenses(db, testOrganizationSigningKey(t).(*ecdsa.PrivateKey), "org-a", nil); err == nil || err.Error() != "unified writer: at least one license is required" {
		t.Fatalf("expected empty license batch rejection, got %v", err)
	}
}

func TestOrganizationBlockWriterPersistsOneAtomicOrganizationBatch(t *testing.T) {
	db := openUnifiedWriterTestDB(t)
	key := testOrganizationSigningKey(t).(*ecdsa.PrivateKey)
	block, err := CreateOrganizationBlockWithLicenses(db, key, "org-a", []OrganizationLicenseInput{testLicense("lic-1"), testLicense("lic-2")})
	if err != nil {
		t.Fatalf("create organization block: %v", err)
	}
	if block.BlockNum != 1 || block.OrganizationID != "org-a" || block.LicenseCount != 2 || block.TxCount != 1 {
		t.Fatalf("unexpected organization block: %+v", block)
	}
	var blocks, txs, licenses int64
	db.Model(&ChainBlock{}).Count(&blocks)
	db.Model(&ChainTx{}).Count(&txs)
	db.Model(&License{}).Count(&licenses)
	if blocks != 2 || txs != 1 || licenses != 2 {
		t.Fatalf("expected genesis+1 block, one event, two licenses; got blocks=%d txs=%d licenses=%d", blocks, txs, licenses)
	}
}

func TestOrganizationBlockWriterRollsBackAfterMidBatchFailure(t *testing.T) {
	db := openUnifiedWriterTestDB(t)
	if err := db.Exec(`CREATE TRIGGER fail_second_license BEFORE INSERT ON licenses
		WHEN NEW.license_id = 'lic-fail'
		BEGIN SELECT RAISE(ABORT, 'injected mid-batch failure'); END;`).Error; err != nil {
		t.Fatalf("install failure trigger: %v", err)
	}
	key := testOrganizationSigningKey(t).(*ecdsa.PrivateKey)
	_, err := CreateOrganizationBlockWithLicenses(db, key, "org-a", []OrganizationLicenseInput{testLicense("lic-first"), testLicense("lic-fail")})
	if err == nil {
		t.Fatal("expected injected mid-batch failure")
	}
	var blocks, txs, licenses int64
	db.Model(&ChainBlock{}).Count(&blocks)
	db.Model(&ChainTx{}).Count(&txs)
	db.Model(&License{}).Count(&licenses)
	if blocks != 1 || txs != 0 || licenses != 0 {
		t.Fatalf("transaction did not roll back completely: blocks=%d txs=%d licenses=%d", blocks, txs, licenses)
	}
}

func TestLicenseChainWriteGateRejectsLegacyNonOrganizationBlocks(t *testing.T) {
	db := openUnifiedWriterTestDB(t)
	legacy := ChainBlock{
		BlockNum: 1, PrevHash: lockedV14GenesisHash, MerkleRoot: "legacy-merkle",
		TxCount: 0, Timestamp: lockedV14GenesisUnixSeconds + 1, Hash: "legacy-hash",
	}
	if err := db.Create(&legacy).Error; err != nil {
		t.Fatalf("insert legacy block fixture: %v", err)
	}
	if err := validateLicenseChainForWrite(db); err == nil {
		t.Fatal("expected legacy non-organization block to fail closed")
	}
}
