package main

import (
	"testing"
	"crypto/ecdsa"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestOrganizationBlockWriterRejectsInvalidPreconditions(t *testing.T) {
	if _, err := CreateOrganizationBlockWithLicenses(nil, nil, "org-a", nil); err == nil || err.Error() != "unified writer: nil database" {
		t.Fatalf("expected nil database rejection, got %v", err)
	}

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open in-memory test database: %v", err)
	}

	if _, err := CreateOrganizationBlockWithLicenses(db, nil, "org-a", nil); err == nil || err.Error() != "unified writer: signing key is locked" {
		t.Fatalf("expected locked signing key rejection, got %v", err)
	}

	if _, err := CreateOrganizationBlockWithLicenses(db, &ecdsa.PrivateKey{}, "", nil); err == nil || err.Error() != "unified writer: organization_id is required" {
		t.Fatalf("expected missing organization rejection, got %v", err)
	}

	if _, err := CreateOrganizationBlockWithLicenses(db, &ecdsa.PrivateKey{}, "org-a", nil); err == nil || err.Error() != "unified writer: at least one license is required" {
		t.Fatalf("expected empty license batch rejection, got %v", err)
	}
}
