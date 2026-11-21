#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="4K"
STARTED="$(date -Iseconds)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" || ! -f "$ROOT/go.mod" ]]; then
  echo "ERROR: run this script from inside the horizon-core repository" >&2
  exit 1
fi
cd "$ROOT"

EXPECTED_GO="go1.24.4"
ACTUAL_GO="$(go version | sed -E 's/^go version ([^ ]+).*/\1/')"
if [[ "$ACTUAL_GO" != "$EXPECTED_GO" ]]; then
  echo "ERROR: expected $EXPECTED_GO; found $(go version)" >&2
  exit 1
fi

ADMIN="cmd/switch/admin.go"
WOTS="internal/crypto/wots/wots.go"
TEST="cmd/switch/pq_signing_quarantine_test.go"
STATUS="internal/crypto/wots/STATUS.md"
for f in "$ADMIN" "$WOTS"; do
  [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done
[[ ! -e "$TEST" ]] || { echo "ERROR: $TEST already exists; refusing to overwrite" >&2; exit 1; }
[[ ! -e "$STATUS" ]] || { echo "ERROR: $STATUS already exists; refusing to overwrite" >&2; exit 1; }

MARKER='// ── [PQC LAYER] WOTS+ ──'
if [[ "$(grep -F -c "$MARKER" "$ADMIN" || true)" != "1" ]]; then
  echo "ERROR: expected exactly one legacy WOTS issuance block in $ADMIN" >&2
  exit 1
fi
if ! grep -Fq 'horizon-pqc-fallback-seed-2026-11-13-authority' "$ADMIN" || ! grep -Fq 'D:/pqkey.txt' "$ADMIN"; then
  echo "ERROR: source no longer matches the audited insecure fallback block; refusing automatic patch" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$HOME/horizon-v14-backups/phase4k-disable-unsafe-wots-$STAMP"
OUT="$HOME/horizon-v14-builds/phase4k-disable-unsafe-wots-$STAMP"
mkdir -p "$BACKUP" "$OUT"
cp -p "$ADMIN" "$BACKUP/admin.go"
cp -p "$WOTS" "$BACKUP/wots.go"

ROLLBACK_NEEDED=1
rollback_on_error() {
  rc=$?
  if [[ "${ROLLBACK_NEEDED:-0}" == "1" ]]; then
    cp -p "$BACKUP/admin.go" "$ADMIN" 2>/dev/null || true
    cp -p "$BACKUP/wots.go" "$WOTS" 2>/dev/null || true
    rm -f "$TEST" "$STATUS"
    echo "ERROR: phase failed; original target files restored from $BACKUP" >&2
  fi
  exit "$rc"
}
trap rollback_on_error ERR

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cat > "$TMP/patch.go" <<'GO'
package main

import (
    "bytes"
    "fmt"
    "go/ast"
    "go/format"
    "go/parser"
    "go/token"
    "os"
    "path"
    "strconv"
    "strings"
)

func fail(format string, args ...any) {
    fmt.Fprintf(os.Stderr, "PATCH ERROR: "+format+"\n", args...)
    os.Exit(2)
}

func removeUnusedImports(src []byte, file string) []byte {
    fset := token.NewFileSet()
    f, err := parser.ParseFile(fset, file, src, parser.ParseComments)
    if err != nil { fail("parse %s: %v", file, err) }
    used := map[string]bool{}
    ast.Inspect(f, func(n ast.Node) bool {
        if s, ok := n.(*ast.SelectorExpr); ok {
            if id, ok := s.X.(*ast.Ident); ok { used[id.Name] = true }
        }
        return true
    })
    var newDecls []ast.Decl
    for _, decl := range f.Decls {
        gd, ok := decl.(*ast.GenDecl)
        if !ok || gd.Tok != token.IMPORT { newDecls = append(newDecls, decl); continue }
        specs := make([]ast.Spec, 0, len(gd.Specs))
        for _, raw := range gd.Specs {
            spec := raw.(*ast.ImportSpec)
            importPath, err := strconv.Unquote(spec.Path.Value)
            if err != nil { fail("unquote import %q: %v", spec.Path.Value, err) }
            name := path.Base(importPath)
            if spec.Name != nil { name = spec.Name.Name }
            if name != "_" && name != "." && !used[name] { continue }
            specs = append(specs, spec)
        }
        if len(specs) == 0 { continue }
        gd.Specs = specs
        newDecls = append(newDecls, gd)
    }
    f.Decls = newDecls
    f.Imports = nil
    for _, decl := range f.Decls {
        if gd, ok := decl.(*ast.GenDecl); ok && gd.Tok == token.IMPORT {
            for _, spec := range gd.Specs { f.Imports = append(f.Imports, spec.(*ast.ImportSpec)) }
        }
    }
    var out bytes.Buffer
    if err := format.Node(&out, fset, f); err != nil { fail("format %s: %v", file, err) }
    return out.Bytes()
}

func main() {
    const adminPath = "cmd/switch/admin.go"
    const wotsPath = "internal/crypto/wots/wots.go"
    admin, err := os.ReadFile(adminPath)
    if err != nil { fail("read admin: %v", err) }
    const marker = "// ── [PQC LAYER] WOTS+ ──"
    const anchor = "if err := db.Create(lic).Error; err != nil {"
    if bytes.Count(admin, []byte(marker)) != 1 { fail("expected exactly one WOTS block marker") }
    start := bytes.Index(admin, []byte(marker))
    anchorRel := bytes.Index(admin[start:], []byte(anchor))
    if anchorRel < 0 { fail("license DB-create anchor not found after WOTS block") }
    anchorAt := start + anchorRel
    lineStart := bytes.LastIndex(admin[:start], []byte("\n")) + 1
    anchorLineStart := bytes.LastIndex(admin[:anchorAt], []byte("\n")) + 1
    indent := string(admin[lineStart:start])
    if strings.Trim(indent, " \t") != "" { fail("unexpected indentation before WOTS marker") }
    replacement := indent + "// PQ signature issuance is deliberately disabled in production.\n" +
        indent + "// The bundled WOTS code is experimental, is not a verified RFC 8391 XMSS implementation,\n" +
        indent + "// and has no persistent one-time index or rollback protection. Keep the ECDSA signature above.\n" +
        indent + "lic.WOTSSignature = \"\"\n" +
        indent + "lic.WOTSPubKey = \"\"\n\n"
    patched := append([]byte{}, admin[:lineStart]...)
    patched = append(patched, []byte(replacement)...)
    patched = append(patched, admin[anchorLineStart:]...)
    patched = removeUnusedImports(patched, adminPath)
    if err := os.WriteFile(adminPath, patched, 0644); err != nil { fail("write admin: %v", err) }

    wots, err := os.ReadFile(wotsPath)
    if err != nil { fail("read wots: %v", err) }
    oldDoc := []byte("// Package wots implements Winternitz One-Time Signature (WOTS+)\n// Quantum-resistant hash-based signature. Only uses SHA-256.")
    newDoc := []byte("// Package wots contains an experimental WOTS-like hash-chain primitive.\n// It is NOT a verified RFC 8391 WOTS+/XMSS implementation and MUST NOT be\n// used for production or described as providing certified post-quantum security.\n// No XMSS tree, authentication path, persistent one-time index, or rollback\n// protection is implemented in this package.")
    if bytes.Count(wots, oldDoc) != 1 { fail("WOTS package header differs from audited version") }
    wots = bytes.Replace(wots, oldDoc, newDoc, 1)
    oldKeyDoc := []byte("// GenerateKeyPair derives a deterministic key pair from a 32-byte seed.")
    newKeyDoc := []byte("// GenerateKeyPair derives an experimental deterministic key pair. Test/demo only;\n// never reuse this key for multiple messages or use it in production.")
    if bytes.Count(wots, oldKeyDoc) != 1 { fail("WOTS key-generation comment differs from audited version") }
    wots = bytes.Replace(wots, oldKeyDoc, newKeyDoc, 1)
    if err := os.WriteFile(wotsPath, wots, 0644); err != nil { fail("write WOTS status comments: %v", err) }
}
GO

echo "===== PHASE 4K — QUARANTINE UNSAFE PQ SIGNING ====="
echo "Started: $STARTED"
echo "Repository: $ROOT"
echo "Backup: $BACKUP"
echo "Output: $OUT"
echo "Go: $(go version)"
echo "USB/private key files: NOT READ, COPIED, OR DISPLAYED"
echo "Database access: NONE"
echo "Runtime stop/restart: NONE"
echo "Deploy/commit/push: NONE"

if ! go run "$TMP/patch.go"; then
  cp -p "$BACKUP/admin.go" "$ADMIN"
  cp -p "$BACKUP/wots.go" "$WOTS"
  echo "RESULT=FAIL (targets restored from backup)"
  exit 1
fi

cat > "$TEST" <<'GO'
package main

import (
    "os"
    "strings"
    "testing"
)

func TestProductionLicenseIssuanceDoesNotUseExperimentalWOTS(t *testing.T) {
    source, err := os.ReadFile("admin.go")
    if err != nil { t.Fatalf("read admin.go: %v", err) }
    text := string(source)
    forbidden := []string{
        "wots.GenerateKeyPair(",
        "wots.Sign(",
        "horizon-pqc-fallback-seed-2026-11-13-authority",
        "D:/pqkey.txt",
    }
    for _, item := range forbidden {
        if strings.Contains(text, item) { t.Errorf("unsafe PQ signing reference remains in production license issuer: %q", item) }
    }
    if !strings.Contains(text, "lic.WOTSSignature = \"\"") || !strings.Contains(text, "lic.WOTSPubKey = \"\"") {
        t.Fatal("new license issuance must leave experimental WOTS fields empty")
    }
}
GO

gofmt -w "$ADMIN" "$WOTS" "$TEST"

cat > "$STATUS" <<'MD'
# WOTS/XMSS implementation status — Horizon Core v1.4

Status: **NOT PRODUCTION READY; NOT ACTIVE**.

The current `internal/crypto/wots` package is an experimental hash-chain construction. The available source does not establish conformance with RFC 8391 WOTS+ or a complete XMSS/XMSSMT construction. In particular, it does not implement an XMSS Merkle tree, authentication paths, persistent one-time signing index, or rollback-resistant state management.

Production license issuance therefore leaves `WOTSSignature` and `WOTSPubKey` empty and preserves the existing ECDSA signature path. The hard-coded fallback seed and the hard-coded `D:/pqkey.txt` read have been removed from this production issuance path. No USB key or seed file is read by this phase.

Do not enable this package for production signing. A future post-quantum migration requires a vetted RFC 8391 implementation (or another explicitly selected NIST-standardized scheme), a parameter-set decision, independent test vectors, state persistence and rollback protection, key lifecycle procedures, and an authority-transition checkpoint. Historical ECDSA-signed blocks and licenses must not be rewritten or re-signed.
MD

# Static guard: no production call sites may invoke the experimental WOTS signer.
if grep -Rni --include='*.go' --exclude='*_test.go' -E 'wots\.(GenerateKeyPair|Sign)\(' cmd internal; then
  echo "ERROR: production WOTS call site remains; restoring patched files" >&2
  cp -p "$BACKUP/admin.go" "$ADMIN"
  cp -p "$BACKUP/wots.go" "$WOTS"
  rm -f "$TEST" "$STATUS"
  exit 1
fi
if grep -Rni --include='*.go' --exclude='*_test.go' -E 'horizon-pqc-fallback-seed-2026-11-13-authority|D:/pqkey\.txt' cmd internal; then
  echo "ERROR: legacy fallback seed/path remains in production Go source; restoring patched files" >&2
  cp -p "$BACKUP/admin.go" "$ADMIN"
  cp -p "$BACKUP/wots.go" "$WOTS"
  rm -f "$TEST" "$STATUS"
  exit 1
fi

printf '===== TARGETED TESTS =====\n'
if ! go test -count=1 ./cmd/switch ./internal/chain ./internal/crypto ./internal/crypto/wots ./internal/merkle ./internal/industrial ./internal/tenant; then
  cp -p "$BACKUP/admin.go" "$ADMIN"
  cp -p "$BACKUP/wots.go" "$WOTS"
  rm -f "$TEST" "$STATUS"
  echo "RESULT=FAIL (target source restored; inspect test output)"
  exit 1
fi

printf '===== ISOLATED BUILD =====\n'
if ! go build -trimpath -o "$OUT/horizon-switch.exe" ./cmd/switch; then
  cp -p "$BACKUP/admin.go" "$ADMIN"
  cp -p "$BACKUP/wots.go" "$WOTS"
  rm -f "$TEST" "$STATUS"
  echo "RESULT=FAIL (target source restored; build failed)"
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then sha256sum "$OUT/horizon-switch.exe" | tee "$OUT/binary.sha256"; fi
go version -m "$OUT/horizon-switch.exe" > "$OUT/binary-modules.txt"

git diff --check
ROLLBACK_NEEDED=0

cat > "$OUT/phase4k-report.txt" <<REPORT
HORIZON CORE v1.4 — PHASE 4K
Started: $STARTED
Go: $(go version)
Purpose: disable unsafe experimental WOTS issuance; preserve ECDSA path.
Changes: $ADMIN, $WOTS, $TEST, $STATUS
Backup: $BACKUP
Database access: NONE
USB/private key files: NOT READ, COPIED, OR DISPLAYED
Runtime stop/restart: NONE
Deployment: NONE
Commit/push: NONE
Post-quantum signature activation: NOT ACTIVE
REPORT

cp -p "$OUT/phase4k-report.txt" "$BACKUP/phase4k-report.txt"

echo "===== PHASE 4K SUMMARY ====="
echo "RESULT=PASS"
echo "Unsafe WOTS production issuance: DISABLED"
echo "Hard-coded fallback seed/path: REMOVED FROM PRODUCTION ISSUER"
echo "ECDSA license signing: PRESERVED"
echo "Experimental WOTS package: RETAINED FOR NON-PRODUCTION TESTING ONLY"
echo "Tests: 7 targeted packages passed"
echo "Build: $OUT/horizon-switch.exe"
echo "Report: $OUT/phase4k-report.txt"
echo "Backup: $BACKUP"
echo "Database access: NONE"
echo "USB/private keys: NOT READ"
echo "Runtime restart/deployment/commit/push: NONE"
echo "IMPORTANT: This does NOT implement XMSS or activate post-quantum signatures."
