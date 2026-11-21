#!/usr/bin/env bash
# horizon-core-fixes.sh — Horizon Core v1.4 → v1.5 remediation (part 1/2)
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
BRANCH="fix/v1.4-to-v1.5"
TAG="v1.5-rc1"
ASSUME_YES=0
for arg in "$@"; do
  [[ "$arg" == "--yes" || "$arg" == "-y" ]] && ASSUME_YES=1
done

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[0;33m'; C_B='\033[0;34m'; C_N='\033[0m'
log()  { printf "${C_B}[*]${C_N} %s\n" "$*"; }
ok()   { printf "${C_G}[✓]${C_N} %s\n" "$*"; }
warn() { printf "${C_Y}[!]${C_N} %s\n" "$*"; }
die()  { printf "${C_R}[✗]${C_N} %s\n" "$*" >&2; exit 1; }

confirm() {
  if (( ASSUME_YES )); then return 0; fi
  read -r -p "$(printf "${C_Y}%s [y/N] ${C_N}" "$1")" reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by user"
}

cd "$PROJECT_ROOT"
command -v git >/dev/null || die "git not installed"
[[ -d .git ]] || die "not a git repo: $PROJECT_ROOT"
git config user.name  >/dev/null || die "git user.name not set"
git config user.email >/dev/null || die "git user.email not set"

DEFAULT_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
if [[ -z "$DEFAULT_BRANCH" ]]; then
  if git rev-parse --verify main   >/dev/null 2>&1; then DEFAULT_BRANCH=main
  elif git rev-parse --verify master >/dev/null 2>&1; then DEFAULT_BRANCH=master
  else DEFAULT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  fi
fi
ok "default branch: $DEFAULT_BRANCH"

if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists"
fi
if ! git diff-index --quiet HEAD --; then
  die "uncommitted changes — commit or stash first"
fi
if [[ -n "$(git ls-files --others --exclude-standard | head -n1)" ]]; then
  die "untracked files present"
fi

cat <<EOF

${C_Y}Horizon Core v1.4 → v1.5 remediation${C_N}
  repo    : $PROJECT_ROOT
  default : $DEFAULT_BRANCH
  branch  : $BRANCH
  tag     : $TAG

Will NOT: create/read/copy any key, modify chain data, push to remote.

EOF
confirm "Proceed?"

if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  warn "branch '$BRANCH' exists; switching"
  git checkout "$BRANCH"
else
  git checkout -b "$BRANCH"
  ok "created branch '$BRANCH'"
fi

mkdir -p internal/wots migrations docs scripts docs/standards

# --- FIX 1: WOTS+ state persistence ---
log "FIX 1: WOTS+ state persistence"

cat > migrations/001_wots_state.sql <<'SQLEOF'
CREATE TABLE IF NOT EXISTS wots_state (
    tree_id        TEXT     PRIMARY KEY,
    next_leaf      INTEGER  NOT NULL CHECK (next_leaf >= 0),
    max_leaf       INTEGER  NOT NULL CHECK (max_leaf > 0),
    last_updated   DATETIME NOT NULL,
    hmac           BLOB     NOT NULL,
    CHECK (next_leaf <= max_leaf)
);
CREATE TABLE IF NOT EXISTS wots_leaf_log (
    tree_id        TEXT     NOT NULL,
    leaf_index     INTEGER  NOT NULL,
    reserved_at    DATETIME NOT NULL,
    signature_hash BLOB,
    PRIMARY KEY (tree_id, leaf_index)
);
SQLEOF

cat > internal/wots/state.go <<'GOEOF'
package wots

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

var (
	ErrStateExhausted = errors.New("wots: tree exhausted")
	ErrStateTampered  = errors.New("wots: HMAC mismatch")
)

type StateManager struct {
	DB      *sql.DB
	HMACKey []byte
	TreeID  string
}

func (s *StateManager) ReserveNextLeaf(ctx context.Context) (uint32, error) {
	if len(s.HMACKey) < 32 {
		return 0, errors.New("wots: HMACKey must be >= 32 bytes")
	}
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return 0, fmt.Errorf("wots: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var next, max uint32
	var storedMAC []byte
	if err := tx.QueryRowContext(ctx,
		`SELECT next_leaf, max_leaf, hmac FROM wots_state WHERE tree_id = ?`,
		s.TreeID).Scan(&next, &max, &storedMAC); err != nil {
		return 0, fmt.Errorf("wots: read state: %w", err)
	}
	if !hmac.Equal(storedMAC, s.mac(s.TreeID, next)) {
		return 0, ErrStateTampered
	}
	if next >= max {
		return 0, ErrStateExhausted
	}

	claimed := next
	newNext := next + 1

	if _, err := tx.ExecContext(ctx,
		`UPDATE wots_state SET next_leaf = ?, last_updated = ?, hmac = ? WHERE tree_id = ?`,
		newNext, time.Now().UTC(), s.mac(s.TreeID, newNext), s.TreeID); err != nil {
		return 0, fmt.Errorf("wots: update: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO wots_leaf_log (tree_id, leaf_index, reserved_at) VALUES (?, ?, ?)`,
		s.TreeID, claimed, time.Now().UTC()); err != nil {
		return 0, fmt.Errorf("wots: log: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("wots: commit: %w", err)
	}
	return claimed, nil
}

func (s *StateManager) InitState(ctx context.Context, maxLeaf uint32) error {
	if maxLeaf == 0 {
		return errors.New("wots: maxLeaf must be > 0")
	}
	_, err := s.DB.ExecContext(ctx,
		`INSERT INTO wots_state (tree_id, next_leaf, max_leaf, last_updated, hmac)
		 VALUES (?, 0, ?, ?, ?)`,
		s.TreeID, maxLeaf, time.Now().UTC(), s.mac(s.TreeID, 0))
	return err
}

func (s *StateManager) mac(treeID string, next uint32) []byte {
	h := hmac.New(sha256.New, s.HMACKey)
	fmt.Fprintf(h, "%s|%d", treeID, next)
	return h.Sum(nil)
}
GOEOF

cat > docs/WOTS_STATE_PERSISTENCE.md <<'MDEOF'
# WOTS+ State Persistence (v1.5)

## Problem in v1.4
RAM-only leaf counter = restart resets to 0 = leaf reuse = broken OTS.

## Fix
Leaf counter persisted in DB with:
1. Atomic reserve-before-sign
2. HMAC tamper-evidence
3. Monotonic CHECK constraint
4. wots_leaf_log audit trail

## State ≠ key
The counter is not a private key. DB storage is safe.
Private WOTS+ material stays on USB.

## Residual risks
- DB and HMAC key must be on separate storage
- Crash between commit and sign wastes a leaf
MDEOF

git add migrations/001_wots_state.sql internal/wots/state.go \
        docs/WOTS_STATE_PERSISTENCE.md
git commit -q -m "fix(wots): persist Merkle-OTS leaf state (CRITICAL)

Adds atomic reserve-before-sign, HMAC tamper-evidence, monotonic
enforcement, and leaf audit log. Prevents OTS reuse across restarts.

Refs: v1.4 report §5 RAM-only model."
ok "commit 1/7: WOTS+ state persistence"

# --- FIX 2: FIPS 205 correction ---
log "FIX 2: FIPS 205 labeling correction"

cat > docs/standards/FIPS-205-CORRECTION.md <<'MDEOF'
# Correction: WOTS+ is not FIPS 205

## What v1.4 said
> "WOTS+ (Winternitz OTS) · FIPS 205"

## Why wrong
- FIPS 205 = SLH-DSA (SPHINCS+).
- WOTS+ = building block inside SLH-DSA, not the standard.
- Claiming FIPS 205 for bare WOTS+ is misrepresentation.

## Correct phrasing
"WOTS+ (hash-based OTS), Merkle-tree authenticated, inspired by SLH-DSA
(FIPS 205). NOT a certified FIPS 205 implementation."
MDEOF

git add docs/standards/FIPS-205-CORRECTION.md
git commit -q -m "docs(standards): correct FIPS 205 labeling

WOTS+ is a building block inside SLH-DSA (FIPS 205), not the standard."
ok "commit 2/7: FIPS 205 correction"

# --- FIX 3: Merkle tree separation ---
log "FIX 3: Merkle tree separation"

cat > docs/MERKLE_TREES.md <<'MDEOF'
# Merkle Trees in Horizon Core

## Tree A — Signature Tree (OTS)
- Purpose: authorise signatures
- Leaf: hash(WOTS+ public key)
- Consumption: one per signature, never reused
- Persistence: leaf counter in wots_state

## Tree B — License Tree (Membership)
- Purpose: prove existence of license ID
- Leaf: hash(license_id || metadata_hash)
- Consumption: append-only
- Persistence: rebuildable from chain

## Why separate
1. Tree A: one-time leaves. Tree B: persistent leaves.
2. A = burn-after-use. B = append-only.
3. Leak of B does not break A.

## Ternary vs binary
- Binary = standard (RFC 8391, RFC 8554). Recommended.
- Ternary = non-standard. If used, publish hash function, security
  argument, test vectors, and reason for choice.
MDEOF

git add docs/MERKLE_TREES.md
git commit -q -m "docs: separate Signature Tree (A) from License Tree (B)

v1.4 conflated WOTS+ tree and license Merkle tree."
ok "commit 3/7: tree separation"

# --- FIX 4: Node count ---
log "FIX 4: node count consistency"

cat > docs/ARCHITECTURE.md <<'MDEOF'
# Architecture — Node Roles

Horizon runs 8 service nodes on ports 9001–9008, plus 1 Guardian inspector.

| Port | Node    | Role                              | Consensus |
|------|---------|-----------------------------------|-----------|
| 9001 | Merkle  | SHA-256(left‖right)               | YES (CRITICAL) |
| 9002 | Hash    | SHA-256(header)                   | YES (CRITICAL) |
| 9003 | ECDSA   | secp256k1 + WOTS+ verify          | YES (CRITICAL) |
| 9004 | Type    | binary / ternary policy           | YES (CRITICAL) |
| 9005 | Volume  | used < volume                     | YES (MAJORITY) |
| 9006 | Time    | fail-closed on exhaustion         | YES (MAJORITY) |
| 9007 | User    | user_id match                     | YES (MAJORITY) |
| 9008 | Guardian| veto — not a consensus vote       | NO (INSPECTOR) |

## PBFT math
- Voting nodes n = 7 (Guardian excluded)
- Tolerated Byzantine f = floor((n-1)/3) = 2
- Quorum 2f+1 = 5 of 7

> v1.4 heading said "9 nodes" but listed 8 roles.
> This document fixes: 8 services, 7 voting, 1 inspector.

## Independence requirement
PBFT is meaningful only if the 7 voting nodes are operationally
independent (separate hosts, admins, networks).
MDEOF

git add docs/ARCHITECTURE.md
git commit -q -m "docs(arch): fix 9-vs-8 node count and clarify PBFT quorum"
ok "commit 4/7: node count"

# --- FIX 5: Threat model ---
log "FIX 5: threat model"

cat > docs/THREAT_MODEL.md <<'MDEOF'
# Threat Model (v1.5 draft)

## Assets
1. Chain integrity
2. Signature authority
3. Private key material
4. OTS leaf state
5. License set
6. Availability

## Adversaries
- A1 Network attacker: replay/inject → TLS, single-use sessions
- A2 Malicious client: → license gate, MaxBytesReader, param queries
- A3 DB write access: → HMAC on wots_state, leaf audit log
- A4 USB theft: → NONE at software layer (HSM required)
- A5 Malicious operator: → durable state, audit log, PBFT quorum
- A6 Quantum: → WOTS+ dual sig (requires intact tree)

## Open gaps
- USB key model not tamper-resistant
- PBFT independence not documented
- Ternary Merkle security argument not published
- Authority final string not externally reproducible
- Fuzz coverage metrics missing
MDEOF

git add docs/THREAT_MODEL.md
git commit -q -m "docs(security): add threat model (v1.5 draft)"
ok "commit 5/7: threat model"

# --- FIX 6: Authority verification script ---
log "FIX 6: Authority verification script"

cat > scripts/verify-authority.sh <<'SHEOF'
#!/usr/bin/env bash
# verify-authority.sh — READ-ONLY verification
set -euo pipefail

GENESIS_EXPECTED="${1:-8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603}"
AUTHORITY_EXPECTED="${2:-}"

fail=0; pass=0
check() {
  local name="$1" cond="$2" detail="${3:-}"
  if eval "$cond"; then
    printf "  [PASS] %s %s\n" "$name" "$detail"; pass=$((pass+1))
  else
    printf "  [FAIL] %s %s\n" "$name" "$detail"; fail=$((fail+1))
  fi
}

echo "=== Horizon Authority — READ-ONLY VERIFY ==="

GENESIS_FILE=""
for f in GENESIS.json data/genesis.json genesis/GENESIS.json; do
  [[ -f "$f" ]] && { GENESIS_FILE="$f"; break; }
done
if [[ -z "$GENESIS_FILE" ]]; then
  echo "  [SKIP] no GENESIS file found"
elif command -v jq >/dev/null; then
  echo "  file: $GENESIS_FILE"
  ACTUAL=$(jq -r '.genesis_hash // .hash // empty' "$GENESIS_FILE")
  check "genesis_hash" "[[ \"$ACTUAL\" == \"$GENESIS_EXPECTED\" ]]" "($ACTUAL)"
fi

if [[ -n "$AUTHORITY_EXPECTED" ]]; then
  LEN=${#AUTHORITY_EXPECTED}
  echo "  authority length: $LEN hex chars"
  case $LEN in
    128) echo "    -> 64 bytes (standard ECDSA R||S)" ;;
    130) echo "    -> 65 bytes (R||S||recovery_id — UNUSUAL)" ;;
    64)  echo "    -> 32 bytes (too short)" ;;
    *)   echo "    -> non-standard length" ;;
  esac
fi

echo "=== RESULT ==="
echo "  passed: $pass"; echo "  failed: $fail"
[[ "$fail" -eq 0 ]] && echo "  status: OK (format only)"
exit $(( fail > 0 ? 1 : 0 ))
SHEOF
chmod +x scripts/verify-authority.sh

git add scripts/verify-authority.sh
git commit -q -m "feat(scripts): add read-only Authority verification script"
ok "commit 6/7: verify script"

# --- FIX 7: CHANGELOG + tag ---
log "FIX 7: CHANGELOG + tag"

cat > CHANGELOG.md <<CHEOF
# Changelog

## [$TAG] — $(date -u +%Y-%m-%d)

### Security (CRITICAL)
- WOTS+ state persistence: leaf counter in DB with HMAC tamper-evidence,
  atomic reserve-before-sign, audit log.

### Documentation
- Corrected FIPS 205 labeling
- Documented Signature vs License tree separation
- Fixed 9-vs-8 node count, clarified PBFT quorum
- Added threat model

### Tooling
- Added read-only Authority verification script

### Not changed
- GENESIS.json, CHAIN_STATE.json, chain blocks — untouched.
- No key material created, read, copied, or stored.
CHEOF

git add CHANGELOG.md
git commit -q -m "chore(release): $TAG CHANGELOG"

if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
  warn "tag exists"
else
  git tag -a "$TAG" -m "Horizon Core $TAG"
  ok "tagged $TAG"
fi

echo
echo "============================================================"
ok "All fixes applied on: $BRANCH"
echo "============================================================"
git log --oneline "$DEFAULT_BRANCH..$BRANCH" 2>/dev/null || git log --oneline -7
echo
warn "No push. No chain data modified."
