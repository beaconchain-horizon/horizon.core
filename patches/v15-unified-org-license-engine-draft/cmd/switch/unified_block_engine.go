package main

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// OrganizationLicenseInput is one already-authorized, already-signed license.
// This engine never creates or exports private keys and never changes signatures.
type OrganizationLicenseInput struct {
	LicenseID     string `json:"license_id"`
	UserID        string `json:"user_id"`
	ProductID     string `json:"product_id"`
	Volume        int    `json:"volume"`
	Duration      int    `json:"duration"`
	Signature     string `json:"signature"`
	MerkleRoot    string `json:"merkle_root"`
	IssuedAt      int64  `json:"issued_at"`
	ExpiresAt     int64  `json:"expires_at"`
	HardwareID    string `json:"hardware_id"`
	LicenseType   string `json:"license_type"`
	WOTSSignature string `json:"wots_signature"`
	WOTSPubKey    string `json:"wots_pub_key"`
}

type organizationLicenseBatchPayload struct {
	SchemaVersion  string                     `json:"schema_version"`
	OrganizationID string                     `json:"organization_id"`
	LicenseCount   int                        `json:"license_count"`
	Licenses       []OrganizationLicenseInput `json:"licenses"`
}

// CreateOrganizationBlockWithLicenses is the single atomic writer for an
// organization license block. It writes one chain_blocks row, one chain_txes
// event, and exactly N licenses in the same SQL transaction. Any failure rolls
// the complete operation back. Block #0 is never created or modified here.
func CreateOrganizationBlockWithLicenses(
	db *gorm.DB,
	ownerKey *ecdsa.PrivateKey,
	organizationID string,
	licenses []OrganizationLicenseInput,
) (*ChainBlock, error) {
	if db == nil {
		return nil, errors.New("unified writer: nil database")
	}
	if ownerKey == nil {
		return nil, errors.New("unified writer: signing key is locked")
	}
	if organizationID == "" {
		return nil, errors.New("unified writer: organization_id is required")
	}
	if len(licenses) == 0 {
		return nil, errors.New("unified writer: at least one license is required")
	}
	for i, lic := range licenses {
		if lic.LicenseID == "" || lic.UserID == "" || lic.Signature == "" {
			return nil, fmt.Errorf("unified writer: license[%d] missing license_id, user_id, or signature", i)
		}
	}

	// Keep existing legacy writers from racing this writer in this process.
	chainMutex.Lock()
	defer chainMutex.Unlock()

	var created ChainBlock
	err := db.Transaction(func(tx *gorm.DB) error {
		// Do not repair, migrate, or bootstrap a chain here. A non-canonical
		// history remains fail-closed and must be handled by a separate audit.
		if err := validateLicenseChainForWrite(tx); err != nil {
			return fmt.Errorf("unified writer: canonical preflight failed: %w", err)
		}

		var last ChainBlock
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Order("block_num DESC").First(&last).Error; err != nil {
			return fmt.Errorf("unified writer: read latest block: %w", err)
		}

		// Stable input order is part of the signed payload. Reject duplicate IDs
		// inside the request before touching any table.
		seen := make(map[string]struct{}, len(licenses))
		for i, lic := range licenses {
			if _, ok := seen[lic.LicenseID]; ok {
				return fmt.Errorf("unified writer: duplicate license_id %q", lic.LicenseID)
			}
			seen[lic.LicenseID] = struct{}{}
			if lic.Volume < 0 || lic.Duration < 0 {
				return fmt.Errorf("unified writer: license[%d] has negative volume or duration", i)
			}
		}

		payload := organizationLicenseBatchPayload{
			SchemaVersion:  "horizon.organization-license-batch.v1",
			OrganizationID: organizationID,
			LicenseCount:   len(licenses),
			Licenses:       licenses,
		}
		payloadBytes, err := json.Marshal(payload)
		if err != nil {
			return fmt.Errorf("unified writer: canonicalize license batch: %w", err)
		}
		ts := time.Now().UTC().Unix()
		txID := fmt.Sprintf("org-license-%d-%s-%s", ts, hashString(string(payloadBytes))[:16], randomHex(4))
		txType := "organization.licenses.issue"
		txHash := computeTxHash(txType, string(payloadBytes), ts)
		txSig, err := signData(ownerKey, []byte(canonicalTxMessage(txType, txID, string(payloadBytes), ts)))
		if err != nil {
			return fmt.Errorf("unified writer: sign batch event: %w", err)
		}

		// One chain event contains the exact ordered license batch. TxCount is
		// therefore 1; LicenseCount separately records N organization licenses.
		merkle := computeBlockMerkleRoot([]string{txHash})
		blockNum := last.BlockNum + 1
		blockHash := computeBlockHash(blockNum, last.Hash, merkle, ts)
		blockSig, err := signData(ownerKey, []byte(canonicalBlockMessage(blockNum, last.Hash, merkle, ts)))
		if err != nil {
			return fmt.Errorf("unified writer: sign block: %w", err)
		}
		created = ChainBlock{
			BlockNum: blockNum, PrevHash: last.Hash, MerkleRoot: merkle,
			TxCount: 1, Timestamp: ts, Hash: blockHash,
			Signature: blockSig, SignerAddr: publicAddressFromKey(ownerKey),
		}

		// Map inserts allow the additive v1.5 columns to be used before the
		// legacy Go models are migrated. The SQL migration is explicit.
		if err := tx.Table("chain_blocks").Create(map[string]interface{}{
			"block_num": blockNum, "prev_hash": last.Hash, "merkle_root": merkle,
			"tx_count": 1, "timestamp": ts, "hash": blockHash,
			"signature": blockSig, "signer_addr": created.SignerAddr,
			"organization_id": organizationID, "license_count": len(licenses),
			"created_at": time.Now().UTC(),
		}).Error; err != nil {
			return fmt.Errorf("unified writer: insert block: %w", err)
		}

		if err := tx.Table("chain_txes").Create(map[string]interface{}{
			"tx_id": txID, "block_num": blockNum, "tx_type": txType,
			"payload": string(payloadBytes), "tx_hash": txHash,
			"signature": txSig, "timestamp": ts, "created_at": time.Now().UTC(),
		}).Error; err != nil {
			return fmt.Errorf("unified writer: insert block event: %w", err)
		}

		for i, lic := range licenses {
			row := map[string]interface{}{
				"license_id": lic.LicenseID, "user_id": lic.UserID,
				"product_id": lic.ProductID, "volume": lic.Volume,
				"used": 0, "duration": lic.Duration,
				"signature": lic.Signature, "merkle_root": lic.MerkleRoot,
				"issued_at": lic.IssuedAt, "expires_at": lic.ExpiresAt,
				"status": "active", "hardware_id": lic.HardwareID,
				"license_type":    lic.LicenseType,
				"organization_id": organizationID, "block_num": blockNum,
				"created_at": time.Now().UTC(),
			}
			if err := tx.Table("licenses").Create(row).Error; err != nil {
				return fmt.Errorf("unified writer: insert license[%d] %q: %w", i, lic.LicenseID, err)
			}
		}

		// Verify the declared count against rows actually inserted before commit.
		var persisted int64
		if err := tx.Table("licenses").Where("organization_id = ? AND block_num = ?", organizationID, blockNum).Count(&persisted).Error; err != nil {
			return fmt.Errorf("unified writer: verify license count: %w", err)
		}
		if persisted != int64(len(licenses)) {
			return fmt.Errorf("unified writer: license count mismatch: requested=%d persisted=%d", len(licenses), persisted)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	setLastBlockCache(&created)
	return &created, nil
}

func hashString(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}
