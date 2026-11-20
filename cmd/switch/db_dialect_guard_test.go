package main

import (
	"path/filepath"
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

func TestConfigureSQLiteSkipsPostgres(t *testing.T) {
	db, err := gorm.Open(postgres.Open("host=127.0.0.1 port=1 user=horizon_test dbname=horizon_test sslmode=disable"), &gorm.Config{DisableAutomaticPing: true})
	if err != nil {
		t.Fatalf("open postgres dialector without connecting: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get postgres sql.DB: %v", err)
	}
	defer sqlDB.Close()

	if err := configureSQLite(db); err != nil {
		t.Fatalf("configureSQLite should be a no-op for PostgreSQL: %v", err)
	}
	if got := sqlDB.Stats().MaxOpenConnections; got != 0 {
		t.Fatalf("PostgreSQL pool max-open was changed to %d; want unchanged default 0", got)
	}
}

func TestConfigureSQLiteStillConfiguresSQLite(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "switch-test.db")
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		t.Fatalf("open temporary SQLite DB: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get SQLite sql.DB: %v", err)
	}
	defer sqlDB.Close()

	if err := configureSQLite(db); err != nil {
		t.Fatalf("configure SQLite: %v", err)
	}
	if got := sqlDB.Stats().MaxOpenConnections; got != 1 {
		t.Fatalf("SQLite pool max-open = %d, want 1", got)
	}
}

func TestCreateGenesisBlockFailsClosedWithoutOptIn(t *testing.T) {
	t.Setenv(licenseChainGenesisBootstrapEnv, "")
	block, err := createGenesisBlock(nil, nil)
	if err == nil {
		t.Fatal("expected Genesis creation to be refused without explicit opt-in")
	}
	if block != nil {
		t.Fatalf("expected no Genesis block, got %#v", block)
	}
}

func TestMigrateChainDoesNotCreateMissingTablesByDefault(t *testing.T) {
	t.Setenv(licenseChainSchemaMigrationEnv, "")
	dbPath := filepath.Join(t.TempDir(), "empty-registry.db")
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		t.Fatalf("open temporary SQLite DB: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get SQLite sql.DB: %v", err)
	}
	defer sqlDB.Close()

	if err := migrateChain(db); err == nil {
		t.Fatal("expected missing Schema to fail closed")
	}
	if db.Migrator().HasTable(&ChainBlock{}) || db.Migrator().HasTable(&ChainTx{}) {
		t.Fatal("migrateChain unexpectedly created registry tables")
	}
}

func TestMigrateChainAcceptsExistingTablesWithoutOptIn(t *testing.T) {
	t.Setenv(licenseChainSchemaMigrationEnv, "")
	dbPath := filepath.Join(t.TempDir(), "existing-registry.db")
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		t.Fatalf("open temporary SQLite DB: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get SQLite sql.DB: %v", err)
	}
	defer sqlDB.Close()

	if err := db.AutoMigrate(&ChainBlock{}, &ChainTx{}); err != nil {
		t.Fatalf("prepare isolated test Schema: %v", err)
	}
	if err := migrateChain(db); err != nil {
		t.Fatalf("existing Schema should pass without migration opt-in: %v", err)
	}
}
