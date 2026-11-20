// Package wots is a legacy, experimental hash-chain verifier.
//
// This package is NOT an RFC 8391 WOTS+ implementation and is NOT XMSS.
// It has no stateful one-time-key allocation, Merkle tree, authentication
// paths, or rollback protection. Verification is retained only for reading
// historical data produced by this legacy format. New key generation and
// signing are disabled.
//
// Deprecated: use a separately reviewed, stateful signature construction for
// any future post-quantum signing. Do not describe this package as WOTS+ or
// as providing production or certified post-quantum security.
package wots

import (
	"bytes"
	"crypto/sha256"
	"errors"
)

const (
	W           = 16
	KeySize     = 32
	Len1        = 64
	Len2        = 3
	ChainCount  = Len1 + Len2
	PrivKeySize = ChainCount * KeySize
	PubKeySize  = ChainCount * KeySize
	SigSize     = ChainCount * KeySize
)

var (
	ErrInvalidKeySize  = errors.New("wots: invalid key size")
	ErrInvalidMsgSize  = errors.New("wots: message hash must be 32 bytes")
	ErrSigningDisabled = errors.New("wots: legacy signing and key generation are disabled; verification only")
)

// GenerateKeyPair is retained for source compatibility, but no longer
// generates keys. The legacy construction is not safe for production use.
//
// Deprecated: always returns ErrSigningDisabled.
func GenerateKeyPair(seed []byte) (privKey, pubKey []byte, err error) {
	return nil, nil, ErrSigningDisabled
}

// Sign is retained for source compatibility, but cannot create new
// signatures with the legacy construction.
//
// Deprecated: always returns ErrSigningDisabled.
func Sign(privKey, msgHash []byte) ([]byte, error) {
	return nil, ErrSigningDisabled
}

// Verify checks a signature in the historical experimental hash-chain
// format. It does not verify RFC 8391 WOTS+, XMSS, or an Authority identity.
// Keep this read-only path only where legacy data must remain inspectable.
func Verify(pubKey, msgHash, sig []byte) bool {
	if len(pubKey) != PubKeySize || len(sig) != SigSize || len(msgHash) != 32 {
		return false
	}
	digits := messageToDigits(msgHash)
	allDigits := append(digits, checksumDigits(digits)...)
	for i, d := range allDigits {
		elem := sig[i*KeySize : (i+1)*KeySize]
		computed := chain(elem, W-1-int(d))
		expected := pubKey[i*KeySize : (i+1)*KeySize]
		if !bytes.Equal(computed, expected) {
			return false
		}
	}
	return true
}

func chain(x []byte, steps int) []byte {
	h := make([]byte, 32)
	copy(h, x)
	for i := 0; i < steps; i++ {
		sum := sha256.Sum256(h)
		h = sum[:]
	}
	return h
}

func messageToDigits(msg []byte) []byte {
	digits := make([]byte, Len1)
	for i := 0; i < 32; i++ {
		digits[2*i] = msg[i] >> 4
		digits[2*i+1] = msg[i] & 0x0F
	}
	return digits
}

func checksumDigits(digits []byte) []byte {
	var csum uint32
	for _, d := range digits {
		csum += uint32(W - 1 - int(d))
	}
	csum <<= 4
	return []byte{
		byte((csum >> 8) & 0x0F),
		byte((csum >> 4) & 0x0F),
		byte(csum & 0x0F),
	}
}
