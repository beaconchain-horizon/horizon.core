package authority

import (
	"crypto/sha256"
	"testing"

	hcrypto "horizon-core/internal/crypto"
	"horizon-core/internal/crypto/wots/rfc8391"
)

func TestECDSARoundTripThroughAuthority(t *testing.T) {
	priv, err := hcrypto.GenerateSecp256k1ECDSAKey()
	if err != nil {
		t.Fatal(err)
	}
	msg := sha256.Sum256([]byte("Horizon Authority integration test"))
	sig, err := SignECDSAHash(priv, msg[:])
	if err != nil {
		t.Fatal(err)
	}
	if len(sig) != 64 {
		t.Fatalf("signature length = %d, want 64", len(sig))
	}
	if !VerifyECDSAHash(&priv.PublicKey, msg[:], sig) {
		t.Fatal("Authority ECDSA verification failed")
	}
}

func TestWOTSVerificationThroughAuthority(t *testing.T) {
	address := rfc8391.NewOTSAddress(0, 1, 2)
	sk, pk, err := rfc8391.GenerateKeyPair(nil, address)
	if err != nil {
		t.Fatal(err)
	}
	defer sk.Destroy()
	msg := sha256.Sum256([]byte("Horizon Authority WOTS verification test"))
	sig, err := sk.SignOnce(msg[:])
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyWOTS(pk.Bytes(), pk.PublicSeed(), address, msg[:], sig); err != nil {
		t.Fatal(err)
	}
}

func TestWOTSSigningRemainsLocked(t *testing.T) {
	if WOTSSigningStatus() == nil {
		t.Fatal("WOTS+ signing must remain locked until durable OTS state exists")
	}
}
