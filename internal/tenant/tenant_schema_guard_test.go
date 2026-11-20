package tenant

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func openTenantGuardTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite test DB: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get sql DB: %v", err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	return db
}

func TestInitFailsClosedWithoutCreatingTenantTables(t *testing.T) {
	db := openTenantGuardTestDB(t)
	if err := Init(db); err == nil {
		t.Fatal("expected missing tenant schema to fail closed")
	}
	if db.Migrator().HasTable(&Tenant{}) {
		t.Fatal("Init unexpectedly created tenants table")
	}
	if db.Migrator().HasTable(&Heartbeat{}) {
		t.Fatal("Init unexpectedly created heartbeats table")
	}
}

func TestInitAcceptsExistingTenantSchema(t *testing.T) {
	db := openTenantGuardTestDB(t)
	if err := db.Migrator().CreateTable(&Tenant{}, &Heartbeat{}); err != nil {
		t.Fatalf("create test schema: %v", err)
	}
	if err := Init(db); err != nil {
		t.Fatalf("existing tenant schema should pass: %v", err)
	}
}

func TestInitRejectsNilDatabase(t *testing.T) {
	if err := Init(nil); err == nil {
		t.Fatal("expected nil DB to be rejected")
	}
}
