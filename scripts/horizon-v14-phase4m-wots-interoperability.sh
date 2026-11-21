#!/usr/bin/env bash
set -Eeuo pipefail

# Phase 4M: independent WOTS+ interoperability check.
# Uses a pinned, MIT-licensed independent implementation in a temporary clone.
# The repository's go.mod/go.sum and production code remain unchanged.

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

PKG="internal/crypto/wots/rfc8391"
if [[ ! -f "$PKG/wots.go" || ! -f "$PKG/wots_test.go" ]]; then
  echo "ERROR: Phase 4L package not found; expected $PKG"
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$HOME/horizon-v14-builds/phase4m-wots-interoperability-$STAMP"
TMP="$HOME/horizon-v14-tmp/phase4m-$STAMP"
REF="$TMP/wotsp-reference"
mkdir -p "$OUT" "$TMP"

TEST_FILE="$PKG/interop_external_test.go"
MOD_FILE="go.phase4m.mod"
SUM_FILE="go.phase4m.sum"

cleanup() {
  rm -f "$TEST_FILE" "$MOD_FILE" "$SUM_FILE"
  rm -rf "$TMP"
}
trap cleanup EXIT

if [[ -e "$TEST_FILE" || -e "$MOD_FILE" || -e "$SUM_FILE" ]]; then
  echo "ERROR: temporary Phase 4M file already exists; refusing to overwrite"
  exit 1
fi

exec > >(tee "$OUT/phase4m.log") 2>&1

echo "===== HORIZON v1.4 PHASE 4M — INDEPENDENT WOTS+ INTEROPERABILITY ====="
echo "Started: $(date -Iseconds)"
echo "Repository: $ROOT"
echo "Go: $ACTUAL_GO"
echo "Package: $PKG"
echo "Output: $OUT"
echo "Pinned reference: lentus/wotsp @ f126d8a69104fcc00cbf0fab0ec1380b17d346ba"
echo "Database access: NONE"
echo "USB/private key files: NOT READ"
echo "Production runtime: NOT STOPPED OR RESTARTED"
echo "Production source modifications: NONE (temporary test is removed)"
echo "go.mod/go.sum: NOT MODIFIED"

echo ""
echo "===== FETCH PINNED INDEPENDENT REFERENCE ====="
git init -q "$REF"
git -C "$REF" remote add origin https://github.com/lentus/wotsp.git
git -C "$REF" fetch --depth 1 origin f126d8a69104fcc00cbf0fab0ec1380b17d346ba
git -C "$REF" checkout -q --detach FETCH_HEAD

REF_HEAD="$(git -C "$REF" rev-parse HEAD)"
if [[ "$REF_HEAD" != "f126d8a69104fcc00cbf0fab0ec1380b17d346ba" ]]; then
  echo "ERROR: reference checkout does not match the pinned commit"
  exit 1
fi
if ! grep -q "MIT License" "$REF/LICENSE"; then
  echo "ERROR: expected MIT license not found in reference source"
  exit 1
fi
echo "REFERENCE_COMMIT=$REF_HEAD"
echo "REFERENCE_LICENSE=MIT"

echo ""
echo "===== CREATE TEMPORARY MODFILE (PROJECT MODULE FILES UNTOUCHED) ====="
cp go.mod "$MOD_FILE"
cp go.sum "$SUM_FILE"
go mod edit -modfile="$MOD_FILE" \
  -require=github.com/lentus/wotsp@v0.0.0 \
  -replace="github.com/lentus/wotsp=$REF"

echo ""
echo "===== CREATE CROSS-IMPLEMENTATION TEST ====="
cat > "$TEST_FILE" <<'GO_TEST'
package rfc8391

import (
	"bytes"
	"crypto/sha256"
	"testing"

	refwots "github.com/lentus/wotsp"
)

func TestIndependentReferenceWOTSPInteroperability(t *testing.T) {
	// Deterministic test-only seeds. These are public test values and MUST
	// NEVER be used for a production key.
	var skSeed [SeedSize]byte
	var pubSeed [SeedSize]byte
	for i := 0; i < SeedSize; i++ {
		skSeed[i] = byte(i + 1)
		pubSeed[i] = byte(0xa0 + i)
	}

	address := NewOTSAddress(0, 0, 0)
	message := sha256.Sum256([]byte("Horizon Core v1.4 independent WOTS+ interoperability test"))

	localPK := newPublicKeyFromSeeds(skSeed[:], pubSeed[:], address)
	localSK := &PrivateKey{address: address}
	copy(localSK.skSeed[:], skSeed[:])
	copy(localSK.pubSeed[:], pubSeed[:])
	localSig, err := localSK.SignOnce(message[:])
	if err != nil {
		t.Fatalf("Horizon SignOnce: %v", err)
	}

	var opts refwots.Opts
	opts.Mode = refwots.W16
	opts.Address = [32]byte(address)

	referencePK := refwots.GenPublicKey(skSeed[:], pubSeed[:], opts)
	referenceSig := refwots.Sign(message[:], skSeed[:], pubSeed[:], opts)

	if !bytes.Equal(localPK.Bytes(), referencePK) {
		t.Fatal("public key mismatch against pinned independent WOTS+ implementation")
	}
	if !bytes.Equal(localSig, referenceSig) {
		t.Fatal("signature mismatch against pinned independent WOTS+ implementation")
	}
	if !refwots.Verify(referencePK, localSig, message[:], pubSeed[:], opts) {
		t.Fatal("independent implementation rejected Horizon signature")
	}
	if !localPK.Verify(message[:], referenceSig) {
		t.Fatal("Horizon verifier rejected independent implementation signature")
	}
}
GO_TEST

echo ""
echo "===== CROSS-IMPLEMENTATION INTEROPERABILITY TEST ====="
go test -count=1 -modfile="$MOD_FILE" -v "./$PKG"

echo ""
echo "===== HORIZON REGRESSION TESTS ====="
go test -count=1 \
  ./cmd/switch \
  ./internal/chain \
  ./internal/industrial \
  ./internal/tenant \
  ./internal/crypto \
  ./internal/crypto/wots/... \
  ./internal/merkle

echo ""
echo "===== VERIFY PRIMARY MODULE FILES UNCHANGED ====="
git diff --exit-code -- go.mod go.sum
git status --short -- go.mod go.sum

echo ""
echo "===== CHECK TEMPORARY TEST CLEANUP ====="
if [[ -e "$TEST_FILE" || -e "$MOD_FILE" || -e "$SUM_FILE" ]]; then
  echo "ERROR: temporary interoperability files remain"
  exit 1
fi
echo "TEMPORARY_FILES=REMOVED"

echo ""
echo "===== PHASE 4M SUMMARY ====="
echo "RESULT=PASS"
echo "Meaning: Horizon WOTS+ public key and signature matched an independent implementation at the pinned commit."
echo "Important: this checks primitive interoperability only; it is not a complete XMSS implementation or security certification."
echo "One-time key persistence/rollback protection: NOT IMPLEMENTED"
echo "XMSS Merkle tree/authentication paths: NOT IMPLEMENTED"
echo "Production signer integration: NOT ENABLED"
echo "ECDSA/Genesis/database/USB/runtime: NOT TOUCHED"
echo "Output: $OUT"
