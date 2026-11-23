package main

import (
	"fmt"
	"os"
	"strings"

	"gorm.io/gorm"
)

const (
	lockedV14GenesisHash        = "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"
	lockedV14GenesisUnixSeconds = int64(1793472181)
	lockedV14ZeroHash           = "0000000000000000000000000000000000000000000000000000000000000000"
	switchSchemaMigrationEnv    = "HORIZON_ALLOW_SWITCH_SCHEMA_MIGRATION"
)

// ensureSwitchSchema refuses implicit production schema changes. Existing
// tables are checked without altering them. Explicit migration remains opt-in.
func ensureSwitchSchema(db *gorm.DB, models ...interface{}) error {
	if db == nil {
		return fmt.Errorf("switch schema preflight: nil database")
	}
	if os.Getenv(switchSchemaMigrationEnv) == "true" {
		return db.AutoMigrate(models...)
	}
	missing := make([]string, 0)
	for _, model := range models {
		if !db.Migrator().HasTable(model) {
			missing = append(missing, fmt.Sprintf("%T", model))
		}
	}
	if len(missing) != 0 {
		return fmt.Errorf("switch schema incomplete; automatic migration is disabled; missing models: %s", strings.Join(missing, ", "))
	}
	return nil
}

// validateMainBlockChainForWrite prevents new blocks being appended to a
// database whose Genesis or existing height/link sequence differs from the
// locked v1.4 reference. It deliberately does not rewrite or repair history.
func validateMainBlockChainForWrite(db *gorm.DB) error {
	if db == nil || !db.Migrator().HasTable(&Block{}) {
		return fmt.Errorf("canonical write gate: main blocks table unavailable")
	}
	var blocks []Block
	if err := db.Order("block_num ASC").Find(&blocks).Error; err != nil {
		return fmt.Errorf("canonical write gate: read main block history: %w", err)
	}
	if len(blocks) == 0 {
		return fmt.Errorf("canonical write gate: no locked Genesis is present; fresh Genesis creation is disabled")
	}
	g := blocks[0]
	if g.BlockNum != 0 || g.Hash != lockedV14GenesisHash || g.MerkleRoot != lockedV14GenesisHash ||
		g.PrevHash != lockedV14ZeroHash || g.TxCount != 0 || g.Timestamp != lockedV14GenesisUnixSeconds {
		return fmt.Errorf("canonical write gate: main Genesis does not exactly match locked v1.4 header fields")
	}
	for i := range blocks {
		if blocks[i].BlockNum != i {
			return fmt.Errorf("canonical write gate: non-sequential main block height at position %d (stored=%d)", i, blocks[i].BlockNum)
		}
		if i > 0 && blocks[i].PrevHash != blocks[i-1].Hash {
			return fmt.Errorf("canonical write gate: broken main-chain link at height %d", blocks[i].BlockNum)
		}
	}
	return nil
}

// validateLicenseChainForWrite stops license-chain appends until its Genesis,
// block links, and persisted transaction counts reconcile with v1.4 and with
// one another. It is read-only and does not repair legacy rows.
func validateLicenseChainForWrite(db *gorm.DB) error {
	if db == nil || !db.Migrator().HasTable(&ChainBlock{}) || !db.Migrator().HasTable(&ChainTx{}) {
		return fmt.Errorf("license-chain write gate: required tables unavailable")
	}
	var blocks []ChainBlock
	if err := db.Order("block_num ASC").Find(&blocks).Error; err != nil {
		return fmt.Errorf("license-chain write gate: read block history: %w", err)
	}
	if len(blocks) == 0 {
		return fmt.Errorf("license-chain write gate: no locked Genesis is present; bootstrap is disabled")
	}
	g := blocks[0]
	if g.BlockNum != 0 || g.Hash != lockedV14GenesisHash || g.MerkleRoot != lockedV14GenesisHash ||
		g.PrevHash != lockedV14ZeroHash || g.TxCount != 0 || g.Timestamp != lockedV14GenesisUnixSeconds {
		return fmt.Errorf("license-chain write gate: Genesis header does not exactly match locked v1.4 reference")
	}
	for i := range blocks {
		if blocks[i].BlockNum != int64(i) {
			return fmt.Errorf("license-chain write gate: non-sequential block height at position %d (stored=%d)", i, blocks[i].BlockNum)
		}
		if i > 0 && blocks[i].PrevHash != blocks[i-1].Hash {
			return fmt.Errorf("license-chain write gate: broken block link at height %d", blocks[i].BlockNum)
		}
	}
	var mismatchedCounts int64
	if err := db.Table("chain_blocks AS cb").
		Where("cb.tx_count <> (SELECT COUNT(*) FROM chain_txes AS ct WHERE ct.block_num = cb.block_num)").
		Count(&mismatchedCounts).Error; err != nil {
		return fmt.Errorf("license-chain write gate: compare block transaction counts: %w", err)
	}
	if mismatchedCounts != 0 {
		return fmt.Errorf("license-chain write gate: %d blocks have tx_count inconsistent with chain_txes", mismatchedCounts)
	}
	var orphanTransactions int64
	if err := db.Table("chain_txes AS ct").
		Joins("LEFT JOIN chain_blocks AS cb ON cb.block_num = ct.block_num").
		Where("cb.id IS NULL").Count(&orphanTransactions).Error; err != nil {
		return fmt.Errorf("license-chain write gate: find unlinked transactions: %w", err)
	}
	if orphanTransactions != 0 {
		return fmt.Errorf("license-chain write gate: %d transactions have no matching chain block", orphanTransactions)
	}
	// Only after structural transaction-count checks pass, enforce the v1.5
	// organization/license invariant for every non-Genesis block.
	for i := 1; i < len(blocks); i++ {
		b := blocks[i]
		if strings.TrimSpace(b.OrganizationID) == "" || b.LicenseCount <= 0 || b.TxCount != 1 {
			return fmt.Errorf("license-chain write gate: block %d is not a canonical single-organization license block", b.BlockNum)
		}
		var count int64
		if err := db.Table("licenses").Where("organization_id = ? AND block_num = ?", b.OrganizationID, b.BlockNum).Count(&count).Error; err != nil {
			return fmt.Errorf("license-chain write gate: inspect organization licenses at block %d: %w", b.BlockNum, err)
		}
		if count != int64(b.LicenseCount) {
			return fmt.Errorf("license-chain write gate: block %d declares %d licenses but has %d", b.BlockNum, b.LicenseCount, count)
		}
	}
	return nil
}
