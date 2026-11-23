package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"testing"

	"horizon-core/internal/authority"
	internalcrypto "horizon-core/internal/crypto"
)

const verifierFixtureKey = "0000000000000000000000000000000000000000000000000000000000000001"

func verifierSign(t *testing.T, message []byte) string {
	t.Helper()
	key, err := internalcrypto.Secp256k1PrivateKeyFromHex(verifierFixtureKey)
	if err != nil { t.Fatal(err) }
	h := sha256.Sum256(message)
	sig, err := authority.SignECDSAHash(key, h[:])
	if err != nil { t.Fatal(err) }
	return hex.EncodeToString(sig)
}

func TestVerifyOrganizationBatchCommitments(t *testing.T) {
	key, err := internalcrypto.Secp256k1PrivateKeyFromHex(verifierFixtureKey)
	if err != nil { t.Fatal(err) }
	licenseCanonical, err := json.Marshal(struct {
		LicenseID string `json:"license_id"`
		UserID string `json:"user_id"`
		ProductID string `json:"product_id"`
		Volume int64 `json:"volume"`
		Duration int64 `json:"duration"`
		MerkleRoot string `json:"merkle_root"`
		IssuedAt int64 `json:"issued_at"`
		ExpiresAt int64 `json:"expires_at"`
		HardwareID string `json:"hardware_id"`
	}{"lic-1", "user-1", "horizon-core", 10, 30, "lic-merkle", 100, 200, ""})
	if err != nil { t.Fatal(err) }
	licenseSig := verifierSign(t, licenseCanonical)

	payloadBytes, err := json.Marshal(map[string]interface{}{
		"schema_version": "horizon.organization-license-batch.v1",
		"organization_id": "org-a",
		"license_count": 1,
		"licenses": []map[string]interface{}{{
			"license_id":"lic-1", "user_id":"user-1", "product_id":"horizon-core",
			"volume":10, "duration":30, "signature":licenseSig, "merkle_root":"lic-merkle",
			"issued_at":100, "expires_at":200, "hardware_id":"", "license_type":"client",
			"wots_signature":"", "wots_pub_key":"",
		}},
	})
	if err != nil { t.Fatal(err) }
	txType, txID, ts := "organization.licenses.issue", "tx-1", int64(300)
	txPayload := string(payloadBytes)
	txHash := shaHex([]byte("HZTXH1|"+txType+"|"+txPayload+"|300"))
	txMessage := []byte("HZTX1|"+txType+"|"+txID+"|"+txPayload+"|300")
	txSig := verifierSign(t, txMessage)
	merkle := shaHex([]byte(txHash))
	blockMessage := []byte(legacyBlockMsg(1, genesisHash, merkle, ts))
	blockSig := verifierSign(t, blockMessage)
	blockHash := legacyBlockHash(1, genesisHash, merkle, ts)

	blocks := []Block{{Num:1, Ts:ts, TxCount:1, LicenseCount:1, Prev:genesisHash, Merkle:merkle, Hash:blockHash, Sig:blockSig, OrganizationID:"org-a"}}
	licenses := []License{{ID:"lic-1", User:"user-1", Prod:"horizon-core", Sig:licenseSig, Merkle:"lic-merkle", Vol:10, Dur:30, IssAt:100, ExpAt:200, OrganizationID:"org-a", BlockNum:1}}
	txs := []ChainTx{{TxID:txID, TxType:txType, Payload:txPayload, TxHash:txHash, Signature:txSig, BlockNum:1, Timestamp:ts}}
	if err := verifyOrganizationBatches(blocks, licenses, txs, &key.PublicKey); err != nil {
		t.Fatalf("valid organization batch rejected: %v", err)
	}
	licenses[0].OrganizationID = "org-b"
	if err := verifyOrganizationBatches(blocks, licenses, txs, &key.PublicKey); err == nil {
		t.Fatal("cross-organization license membership was accepted")
	}
}
