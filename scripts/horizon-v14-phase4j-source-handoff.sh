#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${HOME}/Beaconchain/horizon-core"
if [[ ! -d "$ROOT/.git" ]]; then
  echo "ERROR: Horizon repository not found at $ROOT" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_ROOT="${HOME}/horizon-v14-builds/phase4j-source-handoff-${STAMP}"
STAGE="$OUT_ROOT/horizon-v14-source"
mkdir -p "$STAGE"

EXCLUDED="$OUT_ROOT/EXCLUDED-SENSITIVE-FILES.txt"
: > "$EXCLUDED"

copy_go_tree() {
  local src="$1"
  [[ -d "$ROOT/$src" ]] || return 0
  while IFS= read -r -d '' file; do
    # Do not export files containing PEM private-key blocks.
    if grep -IqE -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "$file" 2>/dev/null; then
      printf '%s\n' "$src/${file#"$ROOT/$src/"}" >> "$EXCLUDED"
      continue
    fi
    local rel="${file#"$ROOT/"}"
    mkdir -p "$STAGE/$(dirname "$rel")"
    cp -p "$file" "$STAGE/$rel"
  done < <(find "$ROOT/$src" -type f -name '*.go' -print0)
}

# Source required to implement and verify the legacy + future signature path.
copy_go_tree "cmd/switch"
copy_go_tree "internal/crypto"
copy_go_tree "internal/chain"
copy_go_tree "internal/merkle"
copy_go_tree "internal/bnpl"

# Build metadata and the two already-verified, non-secret protocol documents.
for rel in go.mod go.sum config/chain.json config/signature-policy.v1.4.json; do
  if [[ -f "$ROOT/$rel" ]]; then
    mkdir -p "$STAGE/$(dirname "$rel")"
    cp -p "$ROOT/$rel" "$STAGE/$rel"
  fi
done

# Include the protocol lock and latest runtime report, if present.
PROTO_ROOT="$HOME/horizon-v14-protocol/phase4h-separation-lock-20261120_165149"
if [[ -d "$PROTO_ROOT" ]]; then
  mkdir -p "$STAGE/protocol"
  for rel in protocol-lock.json PROTOCOL-DECISIONS.md; do
    [[ -f "$PROTO_ROOT/$rel" ]] && cp -p "$PROTO_ROOT/$rel" "$STAGE/protocol/$rel"
  done
fi
PHASE4I_REPORT="$HOME/horizon-v14-builds/phase4i-canonical-runtime-20261120_171532/phase4i-report.txt"
if [[ -f "$PHASE4I_REPORT" ]]; then
  mkdir -p "$STAGE/reports"
  cp -p "$PHASE4I_REPORT" "$STAGE/reports/phase4i-report.txt"
fi

cat > "$STAGE/SOURCE-HANDOFF-README.txt" <<README
HORIZON CORE v1.4 - SOURCE HANDOFF FOR SIGNATURE-PROTOCOL IMPLEMENTATION

Purpose:
  Inspect the exact local source tree before implementing any consensus or
  cryptographic changes. This is an export only; it does not modify the repo.

Repository:
  $ROOT
Branch:
  $(git -C "$ROOT" branch --show-current 2>/dev/null || true)
HEAD:
  $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)
Go:
  $(go version 2>/dev/null || true)

Included:
  Go source and tests from cmd/switch, internal/crypto, internal/chain,
  internal/merkle, internal/bnpl; go.mod/go.sum; canonical chain config;
  design-only signature policy; Phase 4H lock docs and Phase 4I report.

Excluded by design:
  Databases, SQL dumps, logs, executables, .env files, credentials, private-key
  files, PEM key blocks, mykey.txt, pqkey.txt, and runtime state.

The original repository is unchanged. The export contains only copies.
README

# Record the source snapshot and hashes inside the exported folder.
(
  cd "$STAGE"
  find . -type f ! -name SOURCE-INDEX.sha256 -print0 \
    | sort -z \
    | xargs -0 -r sha256sum > SOURCE-INDEX.sha256
)

if [[ -s "$EXCLUDED" ]]; then
  echo "Some Go files containing PEM private-key markers were excluded:" >&2
  cat "$EXCLUDED" >&2
else
  rm -f "$EXCLUDED"
fi

ARCHIVE="$OUT_ROOT/horizon-v14-source-handoff.tar.gz"
tar -czf "$ARCHIVE" -C "$OUT_ROOT" horizon-v14-source

HASH="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$HASH" "$(basename "$ARCHIVE")" > "$ARCHIVE.sha256"

printf '\n===== PHASE 4J SOURCE HANDOFF =====\n'
printf 'Archive: %s\n' "$ARCHIVE"
printf 'Archive size: '
du -h "$ARCHIVE" | awk '{print $1}'
printf 'SHA256: %s\n' "$HASH"
printf 'Included Go files: '
find "$STAGE" -type f -name '*.go' | wc -l
printf 'Private PEM files excluded: '
if [[ -f "$EXCLUDED" ]]; then wc -l < "$EXCLUDED"; else echo 0; fi
printf 'REPOSITORY MODIFIED: NO\nDATABASE ACCESS: NONE\nPRIVATE KEY FILES INCLUDED: NO\n'
printf 'RESULT=READY_FOR_UPLOAD\n'
