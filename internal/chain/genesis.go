package chain

import (
	"errors"
	"fmt"
	"time"

	"gorm.io/gorm"
)

// GenesisChainID is the immutable identifier for this protocol chain.
const GenesisChainID = "horizon-core-v1.4"

const (
	lockedV14GenesisHash        = "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"
	lockedV14GenesisUnixSeconds = int64(1793472181)
	lockedV14ZeroHash           = "0000000000000000000000000000000000000000000000000000000000000000"
)

// EnsureGenesis only loads an existing, exactly matching locked v1.4 Genesis.
// It never creates or rewrites Genesis at runtime.
func EnsureGenesis(db *gorm.DB, _ string) (*Block, error) {
	if db == nil {
		return nil, fmt.Errorf("Genesis verification: nil database")
	}
	var existing Block
	err := db.Where("number = ?", 0).First(&existing).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, fmt.Errorf("locked v1.4 Genesis is absent; dynamic Genesis creation is disabled")
		}
		return nil, fmt.Errorf("Genesis lookup: %w", err)
	}
	if existing.Number != 0 ||
		existing.PreviousHash != lockedV14ZeroHash ||
		existing.MerkleRoot != lockedV14GenesisHash ||
		existing.BlockHash != lockedV14GenesisHash ||
		existing.TxCount != 0 ||
		!existing.Timestamp.Equal(time.Unix(lockedV14GenesisUnixSeconds, 855252400).UTC()) {
		return nil, fmt.Errorf("stored Genesis does not match the locked v1.4 header")
	}
	return &existing, nil
}

// LatestBlock returns the highest-numbered block.
func LatestBlock(db *gorm.DB) (*Block, error) {
	var b Block
	if err := db.Order("number DESC").First(&b).Error; err != nil {
		return nil, err
	}
	return &b, nil
}
