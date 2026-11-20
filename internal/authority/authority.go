// Package authority is the single Horizon signing/verification boundary.
// It reuses the existing v1.4 secp256k1 implementation and exposes RFC8391
// WOTS+ verification. WOTS+ production signing remains disabled until a
// durable, rollback-resistant XMSS/OTS state manager is integrated.
package authority

import (
	"crypto/ecdsa"
	"encoding/hex"
	"errors"
	"fmt"

	hcrypto "horizon-core/internal/crypto"
	"horizon-core/internal/crypto/wots/rfc8391"
)

const LockedAuthorityPublicKeyHex = "04cf6aaaba8e7a6fddde63a2e2588553dc95503d2de6b2a5c78f4a30a0b91b0aca4d28d06fc1ccbaf730abe1dcda7c29726dab18008353b521c9253c04b1641214"

var ErrWOTSSigningLocked = errors.New("WOTS+ signing is locked: durable rollback-resistant one-time-key state is not implemented")

// SignECDSAHash signs an already-computed SHA-256 digest using the existing
// secp256k1 implementation. The caller remains responsible for key custody.
func SignECDSAHash(privateKey *ecdsa.PrivateKey, digest []byte) ([]byte, error) {
	if len(digest) != 32 {
		return nil, errors.New("digest must be exactly 32 bytes")
	}
	return hcrypto.SignHashRS(privateKey, digest)
}

// VerifyECDSAHash verifies Horizon's canonical 64-byte low-S R||S format.
func VerifyECDSAHash(publicKey *ecdsa.PublicKey, digest, signature []byte) bool {
	return hcrypto.VerifyHashRS(publicKey, digest, signature)
}

// MatchesLockedAuthority reports whether a private/public key belongs to the
// currently pinned Authority identity used by the legacy block signer.
func MatchesLockedAuthority(publicKey *ecdsa.PublicKey) bool {
	if publicKey == nil || publicKey.X == nil || publicKey.Y == nil {
		return false
	}
	x := make([]byte, 32)
	y := make([]byte, 32)
	publicKey.X.FillBytes(x)
	publicKey.Y.FillBytes(y)
	encoded := append([]byte{0x04}, append(x, y...)...)
	return hex.EncodeToString(encoded) == LockedAuthorityPublicKeyHex
}

// VerifyWOTS verifies the RFC8391 WOTS+ primitive with its public seed and
// OTS address. It does not imply XMSS tree or durable OTS-state guarantees.
func VerifyWOTS(publicKey, publicSeed []byte, address rfc8391.Address, digest, signature []byte) error {
	pk, err := rfc8391.NewPublicKey(publicKey, publicSeed, address)
	if err != nil {
		return fmt.Errorf("WOTS+ public key: %w", err)
	}
	if !pk.Verify(digest, signature) {
		return errors.New("WOTS+ signature verification failed")
	}
	return nil
}

// WOTSSigningStatus is deliberately explicit so callers cannot mistake the
// RFC8391 OTS primitive for a production-ready stateful signing system.
func WOTSSigningStatus() error { return ErrWOTSSigningLocked }
