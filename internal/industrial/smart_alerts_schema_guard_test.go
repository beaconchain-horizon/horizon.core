package industrial

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestBackgroundJobsSchemaReadyFailsClosedWithoutCreatingTables(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open isolated sqlite: %v", err)
	}
	if backgroundJobsSchemaReady(db) {
		t.Fatal("empty schema must not enable industrial background jobs")
	}
	if db.Migrator().HasTable(&SensorState{}) {
		t.Fatal("schema readiness check unexpectedly created SensorState")
	}
}

func TestBackgroundJobsSchemaReadyWithRequiredTables(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open isolated sqlite: %v", err)
	}
	if err := db.AutoMigrate(&Sensor{}, &Reading{}, &Alert{}, &SensorState{}); err != nil {
		t.Fatalf("prepare isolated fixture: %v", err)
	}
	if !backgroundJobsSchemaReady(db) {
		t.Fatal("complete schema should enable industrial background jobs")
	}
}
