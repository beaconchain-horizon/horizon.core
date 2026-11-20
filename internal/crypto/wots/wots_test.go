package wots

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"testing"
)

func TestLegacyKeyGenerationAndSigningAreDisabled(t *testing.T) {
	if priv, pub, err := GenerateKeyPair(bytes.Repeat([]byte{0x42}, 32)); !errors.Is(err, ErrSigningDisabled) || priv != nil || pub != nil {
		t.Fatalf("GenerateKeyPair() = (%v, %v, %v), want nil, nil, ErrSigningDisabled", priv, pub, err)
	}
	if sig, err := Sign(bytes.Repeat([]byte{0x24}, PrivKeySize), bytes.Repeat([]byte{0x11}, 32)); !errors.Is(err, ErrSigningDisabled) || sig != nil {
		t.Fatalf("Sign() = (%v, %v), want nil, ErrSigningDisabled", sig, err)
	}
}

func TestVerifyRetainsLegacyReadCompatibility(t *testing.T) {
	msg := sha256.Sum256([]byte("Horizon legacy WOTS-like verification fixture"))
	pub, sig := makeLegacyFixtureForTest(msg[:])

	if !Verify(pub, msg[:], sig) {
		t.Fatal("valid historical legacy signature was rejected")
	}

	badMessage := sha256.Sum256([]byte("different message"))
	if Verify(pub, badMessage[:], sig) {
		t.Fatal("signature for a different message was accepted")
	}

	badSignature := append([]byte(nil), sig...)
	badSignature[0] ^= 0x01
	if Verify(pub, msg[:], badSignature) {
		t.Fatal("tampered historical signature was accepted")
	}
}

func TestVerifyRejectsInvalidLengths(t *testing.T) {
	msg := sha256.Sum256([]byte("length validation"))
	if Verify(make([]byte, PubKeySize-1), msg[:], make([]byte, SigSize)) {
		t.Fatal("short public key was accepted")
	}
	if Verify(make([]byte, PubKeySize), msg[:], make([]byte, SigSize-1)) {
		t.Fatal("short signature was accepted")
	}
	if Verify(make([]byte, PubKeySize), msg[:31], make([]byte, SigSize)) {
		t.Fatal("short message digest was accepted")
	}
}

// makeLegacyFixtureForTest reconstructs the old deterministic format strictly
// inside tests. No production key-generation or signing entry point is used.
func makeLegacyFixtureForTest(msgHash []byte) ([]byte, []byte) {
	seed := bytes.Repeat([]byte{0x42}, 32)
	priv := make([]byte, PrivKeySize)
	pub := make([]byte, PubKeySize)

	for i := 0; i < ChainCount; i++ {
		input := make([]byte, len(seed)+1)
		copy(input, seed)
		input[len(seed)] = byte(i)
		sum := sha256.Sum256(input)
		copy(priv[i*KeySize:(i+1)*KeySize], sum[:])
	}
	for i := 0; i < ChainCount; i++ {
		copy(pub[i*KeySize:(i+1)*KeySize], chain(priv[i*KeySize:(i+1)*KeySize], W-1))
	}

	digits := messageToDigits(msgHash)
	allDigits := append(digits, checksumDigits(digits)...)
	sig := make([]byte, SigSize)
	for i, digit := range allDigits {
		copy(sig[i*KeySize:(i+1)*KeySize], chain(priv[i*KeySize:(i+1)*KeySize], int(digit)))
	}
	return pub, sig
}
