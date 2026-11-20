package main

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"horizon-core/internal/industrial"
)

func TestIndustrialSchemaGuardFailsClosedWithoutCreatingTables(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open isolated sqlite: %v", err)
	}
	if err := requireExistingSwitchTables(db, &industrial.Site{}, &industrial.Sensor{}); err == nil {
		t.Fatal("expected missing industrial tables to fail closed")
	}
	if db.Migrator().HasTable(&industrial.Site{}) || db.Migrator().HasTable(&industrial.Sensor{}) {
		t.Fatal("schema guard unexpectedly created tables")
	}
}

func TestIndustrialSchemaGuardAcceptsExistingTables(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open isolated sqlite: %v", err)
	}
	if err := db.AutoMigrate(&industrial.Site{}, &industrial.Sensor{}); err != nil {
		t.Fatalf("prepare isolated fixture: %v", err)
	}
	if err := requireExistingSwitchTables(db, &industrial.Site{}, &industrial.Sensor{}); err != nil {
		t.Fatalf("existing tables should pass: %v", err)
	}
}
