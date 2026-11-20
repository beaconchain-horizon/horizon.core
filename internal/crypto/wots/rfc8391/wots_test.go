package rfc8391

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"testing"
)

func deterministicReader() *bytes.Reader {
	seedMaterial := make([]byte, 2*SeedSize)
	for i := 0; i < SeedSize; i++ {
		seedMaterial[i] = byte(i + 1)
		seedMaterial[SeedSize+i] = byte(0xa0 + i)
	}
	return bytes.NewReader(seedMaterial)
}

func TestRFC8391W16RoundTrip(t *testing.T) {
	address := NewOTSAddress(0, 7, 11)
	sk, pk, err := GenerateKeyPair(deterministicReader(), address)
	if err != nil {
		t.Fatal(err)
	}
	defer sk.Destroy()

	msg := sha256.Sum256([]byte("Horizon Core v1.4 WOTS+ RFC8391 test message"))
	sig, err := sk.SignOnce(msg[:])
	if err != nil {
		t.Fatal(err)
	}
	if len(sig) != SignatureSize || len(pk.Bytes()) != PublicKeySize {
		t.Fatalf("unexpected sizes: signature=%d publicKey=%d", len(sig), len(pk.Bytes()))
	}
	if !pk.Verify(msg[:], sig) {
		t.Fatal("valid signature rejected")
	}
}

func TestRejectTamperedMessageSignatureAndAddress(t *testing.T) {
	address := NewOTSAddress(1, 22, 3)
	sk, pk, err := GenerateKeyPair(deterministicReader(), address)
	if err != nil {
		t.Fatal(err)
	}
	defer sk.Destroy()
	msg := sha256.Sum256([]byte("message-A"))
	sig, err := sk.SignOnce(msg[:])
	if err != nil {
		t.Fatal(err)
	}
	badMsg := sha256.Sum256([]byte("message-B"))
	if pk.Verify(badMsg[:], sig) {
		t.Fatal("tampered message accepted")
	}
	badSig := append([]byte(nil), sig...)
	badSig[17] ^= 0x80
	if pk.Verify(msg[:], badSig) {
		t.Fatal("tampered signature accepted")
	}
	wrongAddress := NewOTSAddress(1, 22, 4)
	wrongPK, err := NewPublicKey(pk.Bytes(), pk.PublicSeed(), wrongAddress)
	if err != nil {
		t.Fatal(err)
	}
	if wrongPK.Verify(msg[:], sig) {
		t.Fatal("signature verified under a different OTS address")
	}
}

func TestOneTimeKeyCannotSignTwiceInProcess(t *testing.T) {
	sk, _, err := GenerateKeyPair(deterministicReader(), NewOTSAddress(0, 0, 0))
	if err != nil {
		t.Fatal(err)
	}
	defer sk.Destroy()
	msg := sha256.Sum256([]byte("one use only"))
	if _, err := sk.SignOnce(msg[:]); err != nil {
		t.Fatal(err)
	}
	if _, err := sk.SignOnce(msg[:]); !errors.Is(err, ErrOneTimeKeyUsed) {
		t.Fatalf("second signing attempt error=%v, want ErrOneTimeKeyUsed", err)
	}
}

func TestPublicKeyReconstruction(t *testing.T) {
	sk, pk, err := GenerateKeyPair(deterministicReader(), NewOTSAddress(2, 0x1020304050607080, 9))
	if err != nil {
		t.Fatal(err)
	}
	defer sk.Destroy()
	reconstructed, err := NewPublicKey(pk.Bytes(), pk.PublicSeed(), pk.OTSAddress())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(reconstructed.Bytes(), pk.Bytes()) || !bytes.Equal(reconstructed.PublicSeed(), pk.PublicSeed()) || reconstructed.OTSAddress() != pk.OTSAddress() {
		t.Fatal("public verification context changed during reconstruction")
	}
}

func TestInvalidLengthsAndSeedCollisionFailClosed(t *testing.T) {
	if _, _, err := GenerateKeyPair(bytes.NewReader(bytes.Repeat([]byte{0x42}, 2*SeedSize)), NewOTSAddress(0, 0, 0)); !errors.Is(err, ErrInvalidSeed) {
		t.Fatalf("equal seeds error=%v, want ErrInvalidSeed", err)
	}
	badAddress := Address{}
	badAddress[12] = 1 // non-OTS ADRS type
	if _, _, err := GenerateKeyPair(deterministicReader(), badAddress); !errors.Is(err, ErrInvalidAddress) {
		t.Fatalf("invalid address error=%v, want ErrInvalidAddress", err)
	}
	pk, err := NewPublicKey(make([]byte, PublicKeySize-1), make([]byte, SeedSize), NewOTSAddress(0, 0, 0))
	if pk != nil || !errors.Is(err, ErrInvalidPublicKey) {
		t.Fatalf("short public key result=%v error=%v", pk, err)
	}
}
