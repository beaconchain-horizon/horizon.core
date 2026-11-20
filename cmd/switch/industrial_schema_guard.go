package main

import (
	"fmt"
	"strings"

	"gorm.io/gorm"
)

// requireExistingSwitchTables performs a read-only schema preflight. It never
// creates or alters tables; feature owners must disable their feature if this fails.
func requireExistingSwitchTables(db *gorm.DB, models ...interface{}) error {
	if db == nil {
		return fmt.Errorf("schema preflight: nil database")
	}
	missing := make([]string, 0)
	for _, model := range models {
		if !db.Migrator().HasTable(model) {
			missing = append(missing, fmt.Sprintf("%T", model))
		}
	}
	if len(missing) != 0 {
		return fmt.Errorf("required tables are missing; automatic migration is disabled: %s", strings.Join(missing, ", "))
	}
	return nil
}
