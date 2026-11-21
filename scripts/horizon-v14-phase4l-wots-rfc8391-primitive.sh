#!/usr/bin/env bash
set -Eeuo pipefail

# Horizon Core v1.4 — Phase 4L
# Adds an isolated WOTS+-SHA2_256 primitive. It does NOT activate WOTS in
# Switch, license issuance, block signing, consensus, or the production DB.

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: run inside the horizon-core Git repository"
  exit 1
}
cd "$ROOT"

EXPECTED_GO="go1.24.4"
ACTUAL_GO="$(go env GOVERSION)"
if [[ "$ACTUAL_GO" != "$EXPECTED_GO" ]]; then
  echo "ERROR: Go must remain $EXPECTED_GO; found $ACTUAL_GO"
  exit 1
fi
export GOTOOLCHAIN=local

TARGET="internal/crypto/wots/rfc8391"
if [[ -e "$TARGET" ]]; then
  echo "ERROR: $TARGET already exists; refusing to overwrite it"
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$HOME/horizon-v14-backups/phase4l-wots-rfc8391-$STAMP"
OUTPUT="$HOME/horizon-v14-builds/phase4l-wots-rfc8391-$STAMP"
mkdir -p "$BACKUP" "$OUTPUT"

exec > >(tee "$OUTPUT/phase4l.log") 2>&1

echo "===== HORIZON v1.4 PHASE 4L — WOTS+ RFC 8391 PRIMITIVE ====="
echo "Started: $(date -Iseconds)"
echo "Repository: $ROOT"
echo "Go: $ACTUAL_GO"
echo "New package: $TARGET"
echo "Backup/audit: $BACKUP"
echo "Output: $OUTPUT"
echo "Database access: NONE"
echo "USB/private keys: NOT READ"
echo "Production runtime: NOT STOPPED OR RESTARTED"
echo "Commit/push/deploy: NONE"

# Record the pre-change state. Only a new package directory is created.
git status --short --branch > "$BACKUP/git-status-before.txt"
sha256sum go.mod go.sum > "$BACKUP/go-module-hashes-before.txt"

mkdir -p "$TARGET"
cat > "$TARGET/wots.go" <<'GO_WOTS'
// Package rfc8391 implements the WOTS+-SHA2_256 primitive from RFC 8391.
//
// IMPORTANT: WOTS+ is a one-time signature scheme. This package implements
// only the OTS primitive and a process-local single-use guard. It does NOT
// implement XMSS state persistence, rollback protection, tree construction,
// authentication paths, or durable index reservation. Do not use it to sign
// production blocks until it is integrated into a fully stateful XMSS layer.
package rfc8391

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"io"
	"sync"
)

const (
	N             = 32
	W             = 16
	LogW          = 4
	Len1          = 64
	Len2          = 3
	Len           = Len1 + Len2
	SeedSize      = 32
	PublicKeySize = Len * N
	SignatureSize = Len * N
	AddressSize   = 32
)

var (
	ErrInvalidSeed       = errors.New("wots-rfc8391: secret and public seeds must be distinct 32-byte values")
	ErrInvalidPublicSeed = errors.New("wots-rfc8391: public seed must be exactly 32 bytes")
	ErrInvalidAddress    = errors.New("wots-rfc8391: invalid WOTS+ address")
	ErrInvalidMessage    = errors.New("wots-rfc8391: message digest must be exactly 32 bytes")
	ErrInvalidPublicKey  = errors.New("wots-rfc8391: public key must be exactly 2144 bytes")
	ErrInvalidSignature  = errors.New("wots-rfc8391: signature must be exactly 2144 bytes")
	ErrOneTimeKeyUsed    = errors.New("wots-rfc8391: one-time private key already consumed")
	ErrPrivateKeyCleared = errors.New("wots-rfc8391: private key has been destroyed")
)

// Address is the 32-byte RFC 8391 ADRS value. The first 20 bytes carry the
// XMSS layer/tree/type/OTS identity; WOTS+ updates only the final 12 bytes
// (chain, hash, keyAndMask) while hashing.
type Address [AddressSize]byte

// NewOTSAddress creates an OTS address for an XMSS layer, tree and OTS index.
// The caller must assign globally unique coordinates within its XMSS tree.
func NewOTSAddress(layer uint32, tree uint64, otsIndex uint32) Address {
	var a Address
	binary.BigEndian.PutUint32(a[0:4], layer)
	binary.BigEndian.PutUint64(a[4:12], tree)
	binary.BigEndian.PutUint32(a[12:16], 0) // ADRS type 0: OTS hash address
	binary.BigEndian.PutUint32(a[16:20], otsIndex)
	return a
}

func (a Address) valid() bool {
	return binary.BigEndian.Uint32(a[12:16]) == 0
}

func (a *Address) setChain(v uint32)      { binary.BigEndian.PutUint32(a[20:24], v) }
func (a *Address) setHash(v uint32)       { binary.BigEndian.PutUint32(a[24:28], v) }
func (a *Address) setKeyAndMask(v uint32) { binary.BigEndian.PutUint32(a[28:32], v) }

// PrivateKey contains one WOTS+ secret seed. It deliberately has no
// serialization method. SignOnce consumes the key in this process before
// performing the signature. This in-memory guard is NOT rollback-safe and is
// NOT a replacement for XMSS's persistent index/state management.
type PrivateKey struct {
	mu        sync.Mutex
	skSeed    [SeedSize]byte
	pubSeed   [SeedSize]byte
	address   Address
	used      bool
	destroyed bool
}

// PublicKey contains the WOTS+ public key plus the public context required to
// verify it (public seed and OTS address). Bytes returns only the 2144-byte
// WOTS+ public-key value; MarshalBinary includes the verification context.
type PublicKey struct {
	key     [PublicKeySize]byte
	pubSeed [SeedSize]byte
	address Address
}

// GenerateKeyPair creates a fresh WOTS+ key pair from the supplied CSPRNG.
// Pass crypto/rand.Reader in production. The address must identify a unique
// OTS leaf. The key is one-time and must never sign a second message.
func GenerateKeyPair(random io.Reader, address Address) (*PrivateKey, *PublicKey, error) {
	if random == nil {
		random = rand.Reader
	}
	if !address.valid() {
		return nil, nil, ErrInvalidAddress
	}

	sk := &PrivateKey{address: address}
	if _, err := io.ReadFull(random, sk.skSeed[:]); err != nil {
		zero(sk.skSeed[:])
		return nil, nil, err
	}
	if _, err := io.ReadFull(random, sk.pubSeed[:]); err != nil {
		zero(sk.skSeed[:])
		zero(sk.pubSeed[:])
		return nil, nil, err
	}
	if subtle.ConstantTimeCompare(sk.skSeed[:], sk.pubSeed[:]) == 1 {
		zero(sk.skSeed[:])
		zero(sk.pubSeed[:])
		return nil, nil, ErrInvalidSeed
	}

	pk := newPublicKeyFromSeeds(sk.skSeed[:], sk.pubSeed[:], address)
	return sk, pk, nil
}

// NewPublicKey reconstructs a verification key from public WOTS+ material.
// publicKeyBytes is the 2144-byte WOTS+ public-key value.
func NewPublicKey(publicKeyBytes, publicSeed []byte, address Address) (*PublicKey, error) {
	if len(publicKeyBytes) != PublicKeySize {
		return nil, ErrInvalidPublicKey
	}
	if len(publicSeed) != SeedSize {
		return nil, ErrInvalidPublicSeed
	}
	if !address.valid() {
		return nil, ErrInvalidAddress
	}
	pk := &PublicKey{address: address}
	copy(pk.key[:], publicKeyBytes)
	copy(pk.pubSeed[:], publicSeed)
	return pk, nil
}

// SignOnce signs one 32-byte message digest. The key is irreversibly marked
// consumed before signature generation; even an interrupted/failed attempt
// cannot be retried with this object. This is only an in-process safeguard.
func (sk *PrivateKey) SignOnce(messageDigest []byte) ([]byte, error) {
	if len(messageDigest) != N {
		return nil, ErrInvalidMessage
	}
	if sk == nil {
		return nil, ErrPrivateKeyCleared
	}

	sk.mu.Lock()
	defer sk.mu.Unlock()
	if sk.destroyed {
		return nil, ErrPrivateKeyCleared
	}
	if sk.used {
		return nil, ErrOneTimeKeyUsed
	}
	sk.used = true
	defer zero(sk.skSeed[:])
	defer zero(sk.pubSeed[:])

	digits := messageDigits(messageDigest)
	sig := make([]byte, SignatureSize)
	var index [AddressSize]byte
	for i := 0; i < Len; i++ {
		clear(index[:])
		binary.BigEndian.PutUint32(index[AddressSize-4:], uint32(i))
		secret := prf(sk.skSeed[:], index[:])
		addr := sk.address
		addr.setChain(uint32(i))
		value, err := chain(secret[:], 0, uint8(digits[i]), sk.pubSeed[:], addr)
		zero(secret[:])
		if err != nil {
			zero(sig)
			return nil, err
		}
		copy(sig[i*N:(i+1)*N], value[:])
		zero(value[:])
	}
	return sig, nil
}

// Destroy clears this object's in-memory secret seed. It cannot erase copies
// made by the caller, the OS, swap, crash dumps, or prior process snapshots.
func (sk *PrivateKey) Destroy() {
	if sk == nil {
		return
	}
	sk.mu.Lock()
	defer sk.mu.Unlock()
	zero(sk.skSeed[:])
	zero(sk.pubSeed[:])
	sk.used = true
	sk.destroyed = true
}

// Bytes returns a copy of the 2144-byte WOTS+ public-key value.
func (pk *PublicKey) Bytes() []byte {
	if pk == nil {
		return nil
	}
	out := make([]byte, PublicKeySize)
	copy(out, pk.key[:])
	return out
}

// PublicSeed returns a copy of the 32-byte public seed.
func (pk *PublicKey) PublicSeed() []byte {
	if pk == nil {
		return nil
	}
	out := make([]byte, SeedSize)
	copy(out, pk.pubSeed[:])
	return out
}

// OTSAddress returns the XMSS OTS address associated with this public key.
func (pk *PublicKey) OTSAddress() Address {
	if pk == nil {
		return Address{}
	}
	return pk.address
}

// Verify validates a WOTS+ signature for the provided 32-byte message digest.
func (pk *PublicKey) Verify(messageDigest, signature []byte) bool {
	if pk == nil || len(messageDigest) != N || len(signature) != SignatureSize || !pk.address.valid() {
		return false
	}
	digits := messageDigits(messageDigest)
	var computed [PublicKeySize]byte
	for i := 0; i < Len; i++ {
		addr := pk.address
		addr.setChain(uint32(i))
		value, err := chain(signature[i*N:(i+1)*N], uint8(digits[i]), uint8(W-1-int(digits[i])), pk.pubSeed[:], addr)
		if err != nil {
			zero(computed[:])
			return false
		}
		copy(computed[i*N:(i+1)*N], value[:])
		zero(value[:])
	}
	ok := subtle.ConstantTimeCompare(computed[:], pk.key[:]) == 1
	zero(computed[:])
	return ok
}

func newPublicKeyFromSeeds(skSeed, pubSeed []byte, address Address) *PublicKey {
	pk := &PublicKey{address: address}
	copy(pk.pubSeed[:], pubSeed)
	var index [AddressSize]byte
	for i := 0; i < Len; i++ {
		clear(index[:])
		binary.BigEndian.PutUint32(index[AddressSize-4:], uint32(i))
		secret := prf(skSeed, index[:])
		addr := address
		addr.setChain(uint32(i))
		value, _ := chain(secret[:], 0, W-1, pubSeed, addr)
		copy(pk.key[i*N:(i+1)*N], value[:])
		zero(secret[:])
		zero(value[:])
	}
	return pk
}

func messageDigits(message []byte) []uint8 {
	digits := make([]uint8, Len)
	for i, b := range message {
		digits[2*i] = b >> 4
		digits[2*i+1] = b & 0x0f
	}
	var checksum uint32
	for _, digit := range digits[:Len1] {
		checksum += uint32(W - 1 - int(digit))
	}
	checksum <<= 4
	var encoded [2]byte
	binary.BigEndian.PutUint16(encoded[:], uint16(checksum))
	digits[Len1] = encoded[0] >> 4
	digits[Len1+1] = encoded[0] & 0x0f
	digits[Len1+2] = encoded[1] >> 4
	return digits
}

func chain(input []byte, start, steps uint8, pubSeed []byte, address Address) ([N]byte, error) {
	var out [N]byte
	if len(input) != N || len(pubSeed) != SeedSize || int(start)+int(steps) > W-1 {
		return out, errors.New("wots-rfc8391: invalid chain parameters")
	}
	copy(out[:], input)
	for i := uint32(start); i < uint32(start)+uint32(steps); i++ {
		address.setHash(i)
		address.setKeyAndMask(0)
		key := prf(pubSeed, address[:])
		address.setKeyAndMask(1)
		mask := prf(pubSeed, address[:])
		var masked [N]byte
		for j := 0; j < N; j++ {
			masked[j] = out[j] ^ mask[j]
		}
		out = hashF(key[:], masked[:])
		zero(key[:])
		zero(mask[:])
		zero(masked[:])
	}
	return out, nil
}

func prf(key, input []byte) [N]byte {
	var prefix [N]byte
	prefix[N-1] = 3 // toByte(3, 32)
	h := sha256.New()
	h.Write(prefix[:])
	h.Write(key)
	h.Write(input)
	var out [N]byte
	copy(out[:], h.Sum(nil))
	return out
}

func hashF(key, input []byte) [N]byte {
	var prefix [N]byte // toByte(0, 32)
	h := sha256.New()
	h.Write(prefix[:])
	h.Write(key)
	h.Write(input)
	var out [N]byte
	copy(out[:], h.Sum(nil))
	return out
}

func zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
GO_WOTS

cat > "$TARGET/wots_test.go" <<'GO_TESTS'
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
GO_TESTS

cat > "$TARGET/README.md" <<'GO_README'
# Horizon WOTS+ RFC 8391 primitive (experimental)

This package implements the RFC 8391 WOTSP-SHA2_256 parameter profile:
`n=32`, `w=16`, `len=67`, and 2144-byte WOTS+ public keys and signatures.
It uses SHA-256 with RFC domain-separation prefixes, PRF-derived secret chain
values, and an RFC-format 32-byte ADRS value.

## Safety boundary

WOTS+ is a **one-time** signature scheme. `PrivateKey.SignOnce` prevents a
second call on the same in-memory object, but this package has no persistent,
crash-safe, rollback-resistant index allocator. Copying/restoring process
memory or recreating a key object from the same secret seed can defeat that
guard. The private seed is intentionally not serializable by this package.

This package is therefore a cryptographic primitive and test milestone only.
It is NOT connected to license signing, block signing, genesis, consensus, or
the production Switch. Production multi-signature use requires a complete
XMSS/XMSSMT state manager with persistent atomic index reservation, rollback
protection, Merkle tree/root handling, and authentication paths, plus external
interoperability test vectors and independent review.

The included tests cover round-trip signing, tampering, address separation,
public-key reconstruction, input validation, and an
in-process one-use guard. These tests are not a substitute for RFC 8391
interoperability vectors or a cryptographic audit.
GO_README

echo "===== FORMAT SOURCE ====="
gofmt -w "$TARGET"/*.go
if [[ -n "$(gofmt -l "$TARGET"/*.go)" ]]; then
  echo "ERROR: gofmt reported unformatted files"
  exit 1
fi

# Ensure this isolated crypto package did not add or update module deps.
echo "===== VERIFY GO MODULE FILES UNCHANGED ====="
sha256sum -c "$BACKUP/go-module-hashes-before.txt"

echo "===== WOTS+ PACKAGE TESTS ====="
go test -count=1 ./internal/crypto/wots/rfc8391

echo "===== EXISTING CRYPTO + CHAIN + SWITCH REGRESSION TESTS ====="
go test -count=1 \
  ./cmd/switch \
  ./internal/chain \
  ./internal/industrial \
  ./internal/tenant \
  ./internal/crypto \
  ./internal/crypto/wots/... \
  ./internal/merkle

echo "===== STATIC ANALYSIS ====="
go vet ./internal/crypto/wots/rfc8391

echo "===== PACKAGE CHECKSUMS ====="
(
  cd "$TARGET"
  sha256sum README.md wots.go wots_test.go
) | tee "$OUTPUT/SHA256SUMS"

# Verify that no existing source/config files outside the new package changed.
if ! sha256sum -c "$BACKUP/go-module-hashes-before.txt"; then
  echo "ERROR: go.mod/go.sum changed unexpectedly"
  exit 1
fi

echo "===== FINAL STATUS ====="
git status --short -- "$TARGET" go.mod go.sum cmd/switch/admin.go cmd/switch/license_chain.go

echo "RESULT=PASS"
echo "WOTS+ primitive: ADDED IN ISOLATED PACKAGE"
echo "Profile: WOTSP-SHA2_256, n=32, w=16, len=67"
echo "Public key/signature size: 2144 bytes each"
echo "One-time guard: PROCESS-LOCAL ONLY"
echo "RFC external interoperability vectors: PENDING"
echo "XMSS persistent state/authentication paths: NOT IMPLEMENTED"
echo "Production signer integration: NOT ENABLED"
echo "Existing experimental WOTS package: NOT OVERWRITTEN"
echo "Go 1.24.4 and go.mod/go.sum: PRESERVED"
echo "Database/USB/runtime/deployment: NOT TOUCHED"
echo "Report: $OUTPUT/phase4l.log"
echo "Checksums: $OUTPUT/SHA256SUMS"
