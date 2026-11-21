#!/usr/bin/env bash
set -Eeuo pipefail

echo "===== HORIZON v1.4 VERIFIED CHANGES — COMMIT + PUSH ====="
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: run this script inside the horizon-core Git repository"
  exit 1
}
cd "$ROOT"

BRANCH_EXPECTED="master"
REMOTE="origin"
REMOTE_BRANCH="master"
EXPECTED_GO="go1.24.4"

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$HOME/horizon-v14-backups/git-prepush-$STAMP"
mkdir -p "$BACKUP"

echo "Repository: $ROOT"
echo "Backup: $BACKUP"
echo "Target: $REMOTE/$REMOTE_BRANCH"
echo "Go required: $EXPECTED_GO"

# Preserve the current index and complete tracked diff before staging anything.
if [ -f .git/index ]; then
  cp .git/index "$BACKUP/index.before"
fi
git diff HEAD --binary > "$BACKUP/worktree-vs-head.patch"
git diff --cached --binary > "$BACKUP/already-staged.patch"
git status --porcelain=v1 -uall > "$BACKUP/status.before.txt"

BRANCH="$(git branch --show-current)"
if [ "$BRANCH" != "$BRANCH_EXPECTED" ]; then
  echo "ERROR: expected branch $BRANCH_EXPECTED, found $BRANCH"
  exit 1
fi

if ! git diff --cached --quiet; then
  echo "ERROR: there are pre-staged changes. Nothing was staged or committed."
  echo "Review: $BACKUP/status.before.txt"
  exit 1
fi

GO_VERSION="$(go version)"
echo "$GO_VERSION"
case "$GO_VERSION" in
  *"$EXPECTED_GO"*) ;;
  *)
    echo "ERROR: Go must remain $EXPECTED_GO"
    exit 1
    ;;
esac

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "ERROR: remote '$REMOTE' is unavailable"
  exit 1
fi

echo ""
echo "===== VERIFY LOCKED CONFIGS ====="
grep -Fq '"chain_id": "horizon-core-v1.4"' config/chain.json
grep -Fq '"genesis_hash": "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"' config/chain.json
grep -Fq '"activation_state": "DESIGN_ONLY_NOT_ACTIVE"' config/signature-policy.v1.4.json
grep -Fq '"require_both_signatures": false' config/signature-policy.v1.4.json
sha256sum config/chain.json config/signature-policy.v1.4.json

echo ""
echo "===== VERIFY UNSAFE WOTS ISSUANCE IS ABSENT ====="
if grep -nE 'horizon-pqc-fallback-seed|D:/pqkey\.txt|wots\.GenerateKeyPair|wots\.Sign' cmd/switch/admin.go; then
  echo "ERROR: unsafe or experimental WOTS issuance reference remains in admin.go"
  exit 1
fi
echo "PASS: production license issuer does not call the experimental WOTS signer"

# Explicit allow-list. Operational scripts, dumps, DBs, local tools, and forensic
# directories are deliberately excluded from the commit.
ALLOW=(
  cmd/switch/admin.go
  cmd/switch/customer.go
  cmd/switch/db.go
  cmd/switch/industrial_anchor.go
  cmd/switch/industrial_handler.go
  cmd/switch/license_chain.go
  cmd/switch/switch.go
  cmd/switch/tenant_handler.go
  cmd/switch/canonical_write_guard.go
  cmd/switch/canonical_write_guard_test.go
  cmd/switch/db_dialect_guard_test.go
  cmd/switch/genesis_no_autocreate_test.go
  cmd/switch/industrial_schema_guard.go
  cmd/switch/industrial_schema_guard_test.go
  cmd/switch/license_chain_genesis_guard_test.go
  cmd/switch/runtime_write_gate.go
  cmd/switch/runtime_write_gate_test.go
  internal/chain/genesis.go
  internal/chain/genesis_no_autocreate_test.go
  internal/crypto/wots/wots.go
  internal/industrial/smart_alerts.go
  internal/industrial/smart_alerts_schema_guard_test.go
  internal/tenant/tenant.go
  internal/tenant/tenant_schema_guard_test.go
  go.mod
  go.sum
  config/chain.json
  config/signature-policy.v1.4.json
)

echo ""
echo "===== STAGE APPROVED FILES ONLY ====="
for f in "${ALLOW[@]}"; do
  if [ -e "$f" ]; then
    git add -- "$f"
  else
    echo "NOTICE: not present, skipped: $f"
  fi
done

if git diff --cached --quiet; then
  echo "ERROR: allow-list produced no staged changes"
  exit 1
fi

echo ""
echo "===== SECRET / PRIVATE MATERIAL GUARD ====="
STAGED_NAMES="$(git diff --cached --name-only)"
if printf '%s\n' "$STAGED_NAMES" | grep -Ei '(^|/)(\.env[^/]*|.*(mykey|pqkey|private.?key|secret).*)$|(\.pem|\.p12|\.pfx|\.key|\.db|\.dump|\.sqlite)$'; then
  echo "ERROR: sensitive-looking file path in staged set"
  exit 1
fi

ADDED_LINES="$(git diff --cached --unified=0 | grep '^+' | grep -v '^+++' || true)"
if printf '%s\n' "$ADDED_LINES" | grep -Ei \
  'BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY|horizon-pqc-fallback-seed|D:/pqkey\.txt|postgres(ql)?://[^[:space:]]+:[^@[:space:]]+@|ADMIN_TOKEN=|DATABASE_URL='; then
  echo "ERROR: possible secret or unsafe fallback in added lines"
  exit 1
fi

echo ""
echo "===== STAGED CHANGE REVIEW ====="
git diff --cached --check
git diff --cached --stat
git diff --cached --name-only

echo ""
echo "===== TARGETED TESTS ====="
go test -count=1 \
  ./cmd/switch \
  ./internal/chain \
  ./internal/industrial \
  ./internal/tenant \
  ./internal/crypto \
  ./internal/crypto/wots \
  ./internal/merkle

echo ""
echo "===== REMOTE SYNCHRONIZATION CHECK ====="
git fetch "$REMOTE" "$REMOTE_BRANCH"
if ! git merge-base --is-ancestor "$REMOTE/$REMOTE_BRANCH" HEAD; then
  echo "ERROR: local HEAD is behind/diverged from $REMOTE/$REMOTE_BRANCH; no commit or push performed"
  exit 1
fi
if ! git merge-base --is-ancestor HEAD "$REMOTE/$REMOTE_BRANCH"; then
  echo "ERROR: remote branch advanced or histories diverged; no commit or push performed"
  exit 1
fi

echo ""
echo "===== COMMIT ====="
git commit -m "Horizon Core v1.4: harden recovery and quarantine unsafe WOTS issuance"

echo ""
echo "===== PUSH ====="
git push "$REMOTE" "HEAD:refs/heads/$REMOTE_BRANCH"

echo ""
echo "===== VERIFY REMOTE HEAD ====="
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git ls-remote "$REMOTE" "refs/heads/$REMOTE_BRANCH" | awk '{print $1}')"
echo "LOCAL_HEAD=$LOCAL_HEAD"
echo "REMOTE_HEAD=$REMOTE_HEAD"
if [ -z "$REMOTE_HEAD" ] || [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
  echo "ERROR: remote verification did not match local HEAD"
  exit 1
fi

echo ""
echo "===== FINAL STATUS ====="
git status --short --branch
echo "RESULT=PASS"
echo "Committed and pushed only the explicit allow-list."
echo "Excluded: scripts/, backup artifacts, databases, private keys, forensic/math helper directories, and local build outputs."
echo "Recovery write gate remains closed; WOTS+/XMSS remains design-only."
