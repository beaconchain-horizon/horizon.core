package main

import (
	"crypto/ecdsa"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"horizon-core/internal/authority"
	hcrypto "horizon-core/internal/crypto"
	"horizon-core/internal/crypto/wots/rfc8391"
)

type blockRecord struct {
	Number       int64
	BlockHash    string `gorm:"column:block_hash"`
	AuthoritySig string `gorm:"column:authority_sig"`
}

func usage() {
	fmt.Fprintln(os.Stderr, `Horizon Authority — one Go command

Usage:
  authority status
  authority verify-ecdsa <public-key-hex> <sha256-hash-hex> <signature-rs-hex>
  authority verify-wots <wots-pk-hex> <public-seed-hex> <layer> <tree> <ots-index> <sha256-hash-hex> <signature-hex>
  authority sign-hash <sha256-hash-hex>       (stdin key; explicit software-signing opt-in required)
  authority sign-block <block-number>          (stdin key; explicit software-signing opt-in required)

Private-key input is accepted only from stdin. This compatibility software
signer is not a USB/HSM implementation. Set HORIZON_AUTHORITY_ENABLE_SOFTWARE_SIGNING=1
explicitly to enable it. WOTS+ signing is disabled until durable, rollback-
resistant one-time-key state management is integrated.`)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "status":
		fmt.Println("Authority: unified Go command")
		fmt.Println("ECDSA: secp256k1 / SHA-256 / 64-byte low-S R||S")
		fmt.Println("WOTS+: RFC8391 verification available")
		fmt.Println("WOTS+ signing: LOCKED — durable rollback-resistant OTS state is not implemented")
		fmt.Println("USB/HSM: no hardware signer adapter is configured by this build")
		fmt.Println("Software signing: disabled unless HORIZON_AUTHORITY_ENABLE_SOFTWARE_SIGNING=1")
	case "verify-ecdsa":
		err = verifyECDSA(os.Args[2:])
	case "verify-wots":
		err = verifyWOTS(os.Args[2:])
	case "sign-hash":
		err = signHash(os.Args[2:])
	case "sign-block":
		err = signBlock(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "Authority error:", err)
		os.Exit(1)
	}
}

func decode32(label, value string) ([]byte, error) {
	value = strings.TrimSpace(value)
	value = strings.TrimPrefix(strings.TrimPrefix(value, "0x"), "0X")
	b, err := hex.DecodeString(value)
	if err != nil {
		return nil, fmt.Errorf("%s hex: %w", label, err)
	}
	if len(b) != 32 {
		return nil, fmt.Errorf("%s must be 32 bytes, got %d", label, len(b))
	}
	return b, nil
}

func verifyECDSA(args []string) error {
	if len(args) != 3 {
		return errors.New("usage: authority verify-ecdsa <pubhex> <hashhex> <sighex>")
	}
	pub, err := hcrypto.Secp256k1PublicKeyFromHex(args[0])
	if err != nil {
		return err
	}
	hash, err := decode32("hash", args[1])
	if err != nil {
		return err
	}
	sigText := strings.TrimPrefix(strings.TrimPrefix(strings.TrimSpace(args[2]), "0x"), "0X")
	sig, err := hex.DecodeString(sigText)
	if err != nil {
		return fmt.Errorf("signature hex: %w", err)
	}
	if !authority.VerifyECDSAHash(pub, hash, sig) {
		return errors.New("ECDSA signature rejected")
	}
	fmt.Println("VALID: secp256k1 / 64-byte low-S R||S")
	return nil
}

func verifyWOTS(args []string) error {
	if len(args) != 7 {
		return errors.New("usage: authority verify-wots <pkhex> <pubseedhex> <layer> <tree> <ots-index> <hashhex> <sighex>")
	}
	pk, err := hex.DecodeString(args[0])
	if err != nil {
		return fmt.Errorf("WOTS public key: %w", err)
	}
	seed, err := hex.DecodeString(args[1])
	if err != nil {
		return fmt.Errorf("WOTS public seed: %w", err)
	}
	layer, err := strconv.ParseUint(args[2], 10, 32)
	if err != nil {
		return err
	}
	tree, err := strconv.ParseUint(args[3], 10, 64)
	if err != nil {
		return err
	}
	index, err := strconv.ParseUint(args[4], 10, 32)
	if err != nil {
		return err
	}
	hash, err := decode32("hash", args[5])
	if err != nil {
		return err
	}
	sig, err := hex.DecodeString(args[6])
	if err != nil {
		return fmt.Errorf("WOTS signature: %w", err)
	}
	address := rfc8391.NewOTSAddress(uint32(layer), tree, uint32(index))
	if err := authority.VerifyWOTS(pk, seed, address, hash, sig); err != nil {
		return err
	}
	fmt.Println("VALID: RFC8391 WOTS+ primitive signature")
	return nil
}

func readPrivateKey() (*ecdsa.PrivateKey, error) {
	if os.Getenv("HORIZON_AUTHORITY_ENABLE_SOFTWARE_SIGNING") != "1" {
		return nil, errors.New("software signing is disabled; explicitly set HORIZON_AUTHORITY_ENABLE_SOFTWARE_SIGNING=1 to opt in")
	}
	input, err := io.ReadAll(io.LimitReader(os.Stdin, 64*1024))
	if err != nil {
		return nil, err
	}
	value := strings.TrimSpace(string(input))
	if value == "" {
		return nil, errors.New("no private-key input received on stdin")
	}
	if strings.HasPrefix(value, "-----BEGIN") {
		return hcrypto.PEMToPrivateKey(value)
	}
	return hcrypto.Secp256k1PrivateKeyFromHex(value)
}

func signHash(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: authority sign-hash <sha256-hash-hex>")
	}
	hash, err := decode32("hash", args[0])
	if err != nil {
		return err
	}
	priv, err := readPrivateKey()
	if err != nil {
		return err
	}
	if !authority.MatchesLockedAuthority(&priv.PublicKey) {
		return errors.New("private key does not match the locked Authority public key")
	}
	sig, err := authority.SignECDSAHash(priv, hash)
	if err != nil {
		return err
	}
	fmt.Println(hex.EncodeToString(sig))
	return nil
}

func signBlock(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: authority sign-block <block-number>")
	}
	n, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil || n <= 0 {
		return errors.New("block number must be > 0")
	}
	dbPath := os.Getenv("SWITCH_DB")
	if dbPath == "" {
		dbPath = "./horizon-dev.db"
	}
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		return fmt.Errorf("open database: %w", err)
	}
	var block blockRecord
	if err := db.Table("blocks").Where("number = ?", n).First(&block).Error; err != nil {
		return fmt.Errorf("load block: %w", err)
	}
	if block.AuthoritySig != "" {
		return fmt.Errorf("block #%d already has authority_sig; refusing to overwrite", n)
	}
	hash, err := decode32("block_hash", block.BlockHash)
	if err != nil {
		return err
	}
	priv, err := readPrivateKey()
	if err != nil {
		return err
	}
	if !authority.MatchesLockedAuthority(&priv.PublicKey) {
		return errors.New("private key does not match the locked Authority public key")
	}
	sig, err := authority.SignECDSAHash(priv, hash)
	if err != nil {
		return err
	}
	result := db.Table("blocks").Where("number = ? AND (authority_sig = '' OR authority_sig IS NULL)", n).Update("authority_sig", hex.EncodeToString(sig))
	if result.Error != nil {
		return fmt.Errorf("update block signature: %w", result.Error)
	}
	if result.RowsAffected != 1 {
		return errors.New("signature update affected no row; another writer may have changed the block")
	}
	fmt.Printf("SIGNED: block #%d (%d-byte R||S signature)\n", n, len(sig))
	return nil
}
